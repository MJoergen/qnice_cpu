#!/usr/bin/env python3
"""Check that every signal named in a .gtkw save file actually exists.

A GTKWave save file lists signals by full hierarchical path. GTKWave shows
nothing at all for a path it cannot resolve, and reports no error, so a save
file that has drifted away from the RTL opens a counterexample with rows
silently missing -- which looks like a tooling problem rather than a stale file.

Nothing else in this tree reads a .gtkw: it is not compiled, not linted, and not
an input to any sby job. So without this check the drift is invisible. It was
not hypothetical: six of the nine save files that existed before this script had
rotted against RTL renames, 161 dead names between them, sequencer.gtkw at 32 of
its 34 references.

The signal names are taken from the traces a formal run leaves behind rather
than from the source, because the VCD is what GTKWave will actually be given.
That distinction matters: GHDL flattens a VHDL record element to "stage<field>",
not "stage.field", and reading the VHDL would not have caught save files that
used the latter.

Run it after the proofs, from this directory -- "make -C formal" does. Every job
here has a cover task, and a cover task always writes traces, so a successful
run leaves something to check against for all of them.

The task directories to look in come from each job's own [tasks] section, not
from globbing <dut>_*. That is not tidiness. A task renamed or dropped from a
.sby leaves its old directory behind -- "make clean" removes them, an ordinary
run does not -- and globbing picks up those stale traces, so names that no
current task produces appear to resolve. This script was written that way at
first and passed locally while CI, on a fresh checkout, correctly failed on
three names in wb_mux.gtkw.
"""

import glob
import os
import re
import sys

_TASK_LINE = re.compile(r"^(\S+)")

# A .gtkw line is a signal reference unless it opens with one of these:
#   [   directive, e.g. [dumpfile] or [color]
#   @   display-format word, e.g. @28 (single bit) or @22 (hex vector)
#   -   group label
#   *   the marker/zoom line
_NOT_A_SIGNAL = "[@-*"

_SCOPE = re.compile(r"\$scope\s+\w+\s+(\S+)")
_VAR = re.compile(r"\$var\s+\w+\s+(\d+)\s+\S+\s+(\S+)")


def vcd_signals(path):
    """Every hierarchical signal path declared in a VCD header."""
    names = set()
    scope = []
    with open(path, errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("$scope"):
                match = _SCOPE.match(line)
                if match:
                    scope.append(match.group(1))
            elif line.startswith("$upscope"):
                if scope:
                    scope.pop()
            elif line.startswith("$var"):
                match = _VAR.match(line)
                if match:
                    names.add(".".join(scope + [match.group(2)]))
            elif line.startswith("$enddefinitions"):
                break
    return names


def sby_workdirs(dut):
    """The directories a job writes, from the [tasks] section of its .sby.

    One per task, named "<dut>_<task>"; a job with no [tasks] section writes a
    single directory called "<dut>".
    """
    sbyfile = dut + ".sby"
    if not os.path.exists(sbyfile):
        return []

    tasks = []
    in_tasks = False
    with open(sbyfile, errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("["):
                in_tasks = line == "[tasks]"
                continue
            if in_tasks and line and not line.startswith("#"):
                tasks.append(_TASK_LINE.match(line).group(1))
    return ["%s_%s" % (dut, t) for t in tasks] if tasks else [dut]


def gtkw_references(path):
    """Every signal reference in a save file, in file order."""
    refs = []
    with open(path, errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if line and line[0] not in _NOT_A_SIGNAL:
                refs.append(line)
    return refs


def normalise(ref):
    """A reference as it appears in the VCD: no bit range, no expansion index.

    GTKWave writes a vector as "path[15:0]" and one expanded bit of it as
    "(3)path[15:0]"; the VCD declares the vector under the bare path.
    """
    return re.sub(r"^\(\d+\)", "", ref).split("[")[0]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    os.chdir(here)

    savefiles = sorted(glob.glob("*.gtkw"))
    if not savefiles:
        print("check_gtkw: no .gtkw files found in %s" % here, file=sys.stderr)
        return 1

    checked = 0
    skipped = []
    stale = set()
    failures = []
    total_refs = 0

    for savefile in savefiles:
        dut = savefile[: -len(".gtkw")]
        workdirs = sby_workdirs(dut)
        traces = []
        for workdir in workdirs:
            traces += sorted(glob.glob(os.path.join(workdir, "engine_*", "*.vcd")))
        if not traces:
            skipped.append(dut)
            continue

        # Directories from tasks this job no longer declares. Harmless, but
        # they hold traces of an older design, so say so rather than let
        # someone wonder why a local run and CI disagree.
        for leftover in sorted(glob.glob(dut + "_*")):
            if os.path.isdir(leftover) and leftover not in workdirs:
                stale.add(leftover)

        declared = set()
        for trace in traces:
            declared |= vcd_signals(trace)

        refs = gtkw_references(savefile)
        total_refs += len(refs)
        dead = sorted({normalise(r) for r in refs if normalise(r) not in declared})
        checked += 1
        if dead:
            failures.append((savefile, len(refs), dead))
            print("%-22s %3d references, %d DEAD" % (savefile, len(refs), len(dead)))
            for name in dead:
                print("    %s" % name)
        else:
            print("%-22s %3d references, all resolve" % (savefile, len(refs)))

    if stale:
        print()
        print("check_gtkw: ignoring stale task directories, not declared by any")
        print("check_gtkw: .sby any more -- \"make -C formal clean\" removes them:")
        for name in sorted(stale):
            print("    %s" % name)

    if skipped:
        print()
        print("check_gtkw: no trace on disk for: %s" % ", ".join(skipped))
        print("check_gtkw: run the formal jobs first -- every job here has a cover")
        print("check_gtkw: task, and a cover task always writes one.")

    print()
    print("check_gtkw: %d of %d save files checked, %d references, %d with dead names"
          % (checked, len(savefiles), total_refs, len(failures)))

    if failures:
        print()
        print("A save file naming a signal that does not exist is worse than no save")
        print("file: GTKWave drops the row without saying so. Regenerate it from a")
        print("trace -- the names above are the ones that no longer resolve.")
        return 1

    if checked == 0:
        print("check_gtkw: nothing could be checked, so this proved nothing.",
              file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
