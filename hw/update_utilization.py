#!/usr/bin/env python3
"""Refresh the measured numbers in the "Utilization" section of doc/README.md.

Driven by "make utilization"; see the comment above that target in the
top-level Makefile for why two Vivado passes are needed.

This script only ever rewrites *numbers*. The prose around them -- why WRITE
dominates, what the barrel shifters cost, why the two tables disagree -- is a
design argument written by hand, and regenerating it would be worse than
leaving it alone.

Every substitution is anchored on an exact pattern, and a missing anchor is a
hard error rather than a silent skip. If someone rewords a sentence this script
fills in, it must fail loudly: silently leaving a stale number behind is the one
failure mode that would make the report untrustworthy.
"""

import argparse
import re
import subprocess
import sys


class AnchorError(Exception):
    """An expected piece of doc/README.md was not found."""


# --------------------------------------------------------------------------
# Vivado report parsing
# --------------------------------------------------------------------------

def parse_hierarchy(path):
    """Parse "report_utilization -hierarchical" into {instance path: row}.

    The report indents the Instance column by two spaces per level of
    hierarchy, so the full path has to be reconstructed from that indentation:
    bare instance names are not unique (i_osb_first appears four times).

    A row whose instance is parenthesised, e.g. "(i_cpu)", is the logic sitting
    directly in that instance rather than in any of its children. Those are
    keyed with a trailing "/(self)".
    """
    rows = {}
    stack = []
    for line in open(path):
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 7 or cells[0] in ("Instance", "") or set(cells[0]) <= set("-+"):
            continue

        raw = line.split("|")[1]
        indent = len(raw) - len(raw.lstrip(" "))
        depth = indent // 2
        name = cells[0]

        self_row = name.startswith("(") and name.endswith(")")
        if self_row:
            name = name[1:-1]

        if self_row:
            # A self row repeats its parent's name one level deeper, so it
            # names the parent rather than a new level of hierarchy.
            path_key = "/".join(stack[:depth]) + "/(self)"
        else:
            del stack[depth:]
            stack.append(name)
            path_key = "/".join(stack)

        try:
            rows[path_key] = {"luts": int(cells[2]), "ffs": int(cells[6])}
        except ValueError:
            continue
    return rows


def parse_device_totals(path):
    """Pull the device-level resource rows out of a flat report_utilization."""
    wanted = ("Slice LUTs", "Slice Registers", "Slice", "Block RAM Tile")
    totals = {}
    for line in open(path):
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            continue
        name = cells[0].rstrip("*").strip()
        if name not in wanted or name in totals:
            continue
        try:
            totals[name] = {
                "used": int(cells[1]),
                "avail": int(cells[4]),
                "pct": float(cells[5]) if len(cells) > 5 else 0.0,
            }
        except (ValueError, IndexError):
            continue
    missing = [w for w in wanted if w not in totals]
    if missing:
        raise AnchorError("resources missing from %s: %s" % (path, ", ".join(missing)))
    return totals


def parse_timing(path):
    """Return (WNS in ns, number of failing setup endpoints).

    The row wanted is the first numeric line of the "Design Timing Summary"
    table, whose leading columns are WNS, TNS, TNS Failing Endpoints, and
    TNS Total Endpoints. More columns follow (hold, pulse width), so the match
    deliberately does not anchor the end of the line.
    """
    text = open(path).read()
    start = text.find("Design Timing Summary")
    if start < 0:
        raise AnchorError("no 'Design Timing Summary' section in %s" % path)
    m = re.search(r"^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\b",
                  text[start:], re.M)
    if not m:
        raise AnchorError("no WNS row found in %s" % path)
    return float(m.group(1)), int(m.group(3))


def parse_critical_path(path):
    """Return (source, destination, logic levels, % of delay spent routing).

    Taken from the first "Slack (...)" block of the timing summary, which is the
    worst setup path. Endpoint names have their pin suffix and the i_cpu/
    i_cpu_main/ prefix trimmed, since the surrounding prose already says which
    stage they are in.
    """
    text = open(path).read()
    start = text.find("Slack (")
    if start < 0:
        raise AnchorError("no timing path detail in %s" % path)
    block = text[start:start + 4000]

    def grab(pattern, what):
        m = re.search(pattern, block, re.M)
        if not m:
            raise AnchorError("no %s in the worst path of %s" % (what, path))
        return m.group(1)

    def trim(name):
        name = re.sub(r"/[A-Z]+$", "", name)
        for prefix in ("i_cpu/i_cpu_main/", "i_cpu/"):
            if name.startswith(prefix):
                return name[len(prefix):]
        return name

    src = trim(grab(r"^\s*Source:\s+(\S+)\s*$", "source"))
    dst = trim(grab(r"^\s*Destination:\s+(\S+)\s*$", "destination"))
    levels = int(grab(r"^\s*Logic Levels:\s+(\d+)", "logic level count"))
    route = float(grab(r"route \S+ \(([\d.]+)%\)", "routing percentage"))
    return src, dst, levels, route


def parse_tool_version(path):
    m = re.search(r"Tool Version : Vivado v\.(\S+)", open(path).read())
    if not m:
        raise AnchorError("no tool version found in %s" % path)
    return m.group(1)


# --------------------------------------------------------------------------
# Document rewriting
# --------------------------------------------------------------------------

def replace_once(text, pattern, repl, what):
    new, n = re.subn(pattern, repl, text, count=1, flags=re.M | re.S)
    if n != 1:
        raise AnchorError(
            'could not find the %s in doc/README.md.\n'
            'This script rewrites numbers in place and refuses to guess: either '
            'restore the wording it anchors on, or update the pattern here.\n'
            '  pattern: %s' % (what, pattern))
    return new


def wrap_sentence(text, width=79):
    """Wrap to the line length the rest of doc/README.md uses."""
    lines, cur = [], ""
    for word in text.split(" "):
        if cur and len(cur) + 1 + len(word) > width:
            lines.append(cur)
            cur = word
        else:
            cur = word if not cur else cur + " " + word
    if cur:
        lines.append(cur)
    return lines


def render_row(cells, widths, aligns):
    out = []
    for cell, width, align in zip(cells, widths, aligns):
        out.append(cell.rjust(width) if align == "r" else cell.ljust(width))
    return "| " + " | ".join(out) + " |"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--placed", required=True)
    ap.add_argument("--hier", required=True)
    ap.add_argument("--timing", required=True)
    ap.add_argument("--doc", required=True)
    args = ap.parse_args()

    hier = parse_hierarchy(args.hier)
    totals = parse_device_totals(args.placed)
    wns, failing = parse_timing(args.timing)
    crit = parse_critical_path(args.timing)
    version = parse_tool_version(args.placed)
    commit = subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"]).decode().strip()
    # A measurement taken from modified sources does not describe HEAD, and
    # recording a bare hash for it would be a lie -- exactly the kind of quietly
    # wrong provenance this script exists to avoid. Mark it instead.
    #
    # Only what actually feeds the build counts: the VHDL, the constraints, and
    # the Makefile that generates the tcl. Editing this script or the prose in
    # doc/README.md cannot change a number, so it must not flag the result.
    build_inputs = ["src", "test", "hw/system.xdc", "Makefile"]
    if subprocess.call(["git", "diff", "--quiet", "HEAD", "--"] + build_inputs) != 0:
        commit += "-dirty"

    def h(path):
        if path not in hier:
            raise AnchorError(
                "instance %s not in %s -- has the hierarchy changed, or is "
                "-hierarchical_depth too shallow?" % (path, args.hier))
        return hier[path]

    cpu = "system/i_cpu"
    main_ = cpu + "/i_cpu_main"
    modules = [
        ("FETCH",          h(cpu + "/i_fetch")),
        ("ICACHE",         h(cpu + "/i_icache")),
        ("DECODE",         h(main_ + "/i_decode")),
        ("SEQUENCER",      h(main_ + "/i_sequencer")),
        ("PREPARE",        h(main_ + "/i_prepare")),
        ("WRITE",          h(main_ + "/i_write")),
        ("REGISTERS",      h(cpu + "/i_registers")),
        ("MEMORY",         h(cpu + "/i_memory")),
    ]
    glue = {
        "luts": h(cpu + "/(self)")["luts"] + h(main_ + "/(self)")["luts"],
        "ffs":  h(cpu + "/(self)")["ffs"] + h(main_ + "/(self)")["ffs"],
    }
    cpu_total = h(cpu)

    rows = modules + [("Glue", glue), ("**CPU total**", cpu_total)]
    accounted = sum(r["luts"] for _, r in rows[:-1])
    if accounted != cpu_total["luts"]:
        raise AnchorError(
            "per-module LUTs (%d) do not add up to the CPU total (%d); a module "
            "is missing from the table above" % (accounted, cpu_total["luts"]))

    doc = open(args.doc).read()

    # --- provenance -------------------------------------------------------
    doc = replace_once(
        doc,
        r"^Measured with Vivado \S+ on commit `[0-9a-f]+(?:-dirty)?`\.$",
        "Measured with Vivado %s on commit `%s`." % (version, commit),
        "provenance line")

    # --- device totals ----------------------------------------------------
    labels = ["Slice LUTs", "Slice Registers", "Slices", "Block RAM Tile"]
    keys = ["Slice LUTs", "Slice Registers", "Slice", "Block RAM Tile"]
    body = []
    for label, key in zip(labels, keys):
        t = totals[key]
        body.append([label, str(t["used"]), str(t["avail"]), "%.2f" % t["pct"]])
    head = ["Resource", "Used", "Available", "%"]
    widths = [max(len(r[i]) for r in [head] + body) for i in range(4)]
    widths = [max(w, n) for w, n in zip(widths, [15, 4, 9, 4])]
    aligns = ["l", "r", "r", "l"]
    table = [render_row(head, widths, ["l"] * 4),
             "| " + " | ".join("-" * w for w in widths) + " |"]
    table += [render_row(r, widths, aligns) for r in body]
    doc = replace_once(
        doc,
        r"^\| Resource\s+\| Used.*?(?=\n\n)",
        "\n".join(table).replace("\\", "\\\\"),
        "device totals table")

    # --- timing -----------------------------------------------------------
    endpoints = ("no failing endpoints" if failing == 0
                 else "%d failing endpoints" % failing)
    doc = replace_once(
        doc,
        r"^(Timing at the [\d.]+ ns constraint: \*\*WNS )[+-][\d.]+( ns\*\*, )"
        r"(?:no failing endpoints|\d+ failing endpoints)",
        lambda m: "%s%+.3f%s%s" % (m.group(1), wns, m.group(2), endpoints),
        "timing sentence")

    # --- per-module table -------------------------------------------------
    head = ["Module", "LUTs", "FFs"]
    body = [[name, str(r["luts"]), str(r["ffs"])] for name, r in rows]
    widths = [max(len(r[i]) for r in [head] + body) for i in range(3)]
    widths = [max(w, n) for w, n in zip(widths, [15, 4, 3])]
    table = [render_row(head, widths, ["l"] * 3),
             "| " + " | ".join("-" * w for w in widths) + " |"]
    table += [render_row(r, widths, ["l", "r", "r"]) for r in body]
    doc = replace_once(
        doc,
        r"^\| Module\s+\| LUTs.*?(?=\n\n)",
        "\n".join(table).replace("\\", "\\\\"),
        "per-module table")

    # --- prose that quotes those numbers ----------------------------------
    write = h(main_ + "/i_write")
    alu = h(main_ + "/i_write/i_alu")
    alu_data = h(main_ + "/i_write/i_alu/i_alu_data")
    alu_flags = h(main_ + "/i_write/i_alu/i_alu_flags")
    pct = round(100.0 * write["luts"] / cpu_total["luts"])
    doc = replace_once(
        doc,
        r"\*\*WRITE dominates, at \d+% of the CPU's LUTs\*\*, and \d+ of its \d+ are the ALU\n"
        r"(\s*)\(`alu_data` \d+, `alu_flags` \d+\)",
        lambda m: (
            "**WRITE dominates, at %d%% of the CPU's LUTs**, and %d of its %d are the ALU\n"
            "%s(`alu_data` %d, `alu_flags` %d)"
            % (pct, alu["luts"], write["luts"], m.group(1),
               alu_data["luts"], alu_flags["luts"])),
        "WRITE-dominates sentence")

    # This block is delimited by markers rather than anchored on its own
    # wording, because its length varies with the instance names and so the line
    # wrapping cannot be predicted the way the fixed sentences above can.
    src, dst, levels, route = crit
    doc = replace_once(
        doc,
        r"<!-- generated: critical path -->\n.*?\n<!-- end -->",
        "<!-- generated: critical path -->\n"
        + "\n".join(wrap_sentence(
            "The worst setup path runs from `%s` to `%s`: %d logic levels, "
            "with %d%% of the delay in routing rather than logic."
            % (src, dst, levels, round(route))))
        + "\n<!-- end -->",
        "critical path block")

    doc = replace_once(
        doc,
        r"The two tables do not add up to each other \(\d+ vs \d+ LUTs\)",
        "The two tables do not add up to each other (%d vs %d LUTs)"
        % (cpu_total["luts"], totals["Slice LUTs"]["used"]),
        "two-tables sentence")

    with open(args.doc, "w") as f:
        f.write(doc)

    print("%s updated from Vivado %s at commit %s" % (args.doc, version, commit))
    print("  device: %d LUTs, %d FFs, %d BRAM; WNS %+.3f ns, %s"
          % (totals["Slice LUTs"]["used"], totals["Slice Registers"]["used"],
             totals["Block RAM Tile"]["used"], wns, endpoints))
    print("  cpu:    %d LUTs, %d FFs" % (cpu_total["luts"], cpu_total["ffs"]))


if __name__ == "__main__":
    try:
        main()
    except AnchorError as e:
        sys.exit("update_utilization.py: %s" % e)
