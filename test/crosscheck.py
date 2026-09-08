#!/usr/bin/env python3
"""Differential test: run each program on this CPU and on an upstream reference.

Everything else in test/ compares this implementation against itself -- the
.writes and .stats golden files were recorded from a passing run of this CPU, so
they catch a regression but say nothing about whether the CPU agrees with
upstream QNICE.  This script is the missing half: it runs the same program on a
reference from the QNICE-FPGA project and diffs the final state.

TWO REFERENCES

The upstream project ships two implementations of the QNICE ISA, and this
script drives both:

    --reference emulator   emulator/qnice.c, the C emulator ("make crosscheck")
    --reference rtl        vhdl/qnice_cpu.vhd, upstream's own multi-cycle CPU,
                           run under GHDL in test/tb_upstream.vhd
                           ("make crosscheck_rtl")

Neither subsumes the other, because the two disagree with EACH OTHER -- on the
sign of the DIVS remainder, on when the EAE recomputes, and on what R15 reads
as when it is the destination of an instruction whose source was @R15++.  Where
they differ it is the RTL that this CPU has to match, since the RTL is what
QNICE-FPGA synthesises; but only running both makes such a case visible at all.
KNOWN_DIVERGENCE below records each one against the reference it applies to.

WHAT IS COMPARED, AND WHY IT IS MEMORY

The final contents of RAM, word for word, over 0x0000-0x7FFF.  The comparison
deliberately stops there: above 0x8000 the emulator decodes memory-mapped I/O
and both test/system.vhd and test/tb_upstream.vhd put the EAE, so the two sides
are not describing the same thing.

Registers too, R0-R13.  That used to be impossible: src/debug.vhd logged a
register write as "to register F" -- the four-bit register number, with no
record of which of the 256 banks R14's upper byte selected at the time -- so
after the first INCRB the log no longer identified the location written and a
final register file could not be reconstructed from it.  The log now carries
the bank, taken from a port of its own on the register file rather than from
the status register, so that it is the bank the write actually landed in.

How much of the register file each reference can speak about differs, and the
output says which:

  --reference rtl        every bank either side ever wrote.  Upstream's CPU
                         logs its writes the same way (test/tb_upstream.vhd),
                         so the same replay reconstructs both sides in full.
  --reference emulator   the window it halted in.  The emulator's RDUMP prints
                         R0-R15 through read_register(), which resolves R0-R7
                         through the current bank, and there is no way to ask
                         it for the other 255.  The bank it names is checked
                         against the one this CPU's log ends in before anything
                         is compared, so a disagreement is reported as that
                         rather than as eight spurious register diffs.

R14 and R15 are excluded, and REG_HI below says why: the first is flags, which
the implementations are not obliged to agree on and which neither side logs,
and the second is a program counter this CPU deliberately keeps somewhere else.

Nothing in this repo's RTL had to change for this.  The QNICE-side final image
is the assembler's own .out file (the initial memory image, in the same
"0xADDR 0xVALUE" format the emulator's LOAD command reads) with every memory
write from the run's .writes log replayed over it in order.  The alternative --
dumping the array from tb_cpu.vhd at HALT -- would have been a testbench change
and would still have needed this script to compare the result.  The upstream
CPU has no .writes log, so test/tb_upstream.vhd does dump its array; both sides
arrive here in the same format either way.

THE REFERENCE MUST ALSO REPORT A PASS

Diffing memory alone is not enough, and assuming it was is a mistake this
script shipped with.  A program that fails on the reference halts early without
ever writing its status word, and 0x7FFF then still holds the 0x0000 that
untouched memory reads as -- the same value a passing run writes.  prog_eae.asm
was in exactly that state: it halted on the emulator at its "RESULT_HI differs"
HALT, and the comparison reported "identical" because every other word matched.

So the status word is seeded with STATUS_SENTINEL after the program is loaded
and before it runs.  A pass overwrites it with 0x0000; anything else means the
program either reported a failure code or never got there, and the sentinel
survives to say which.  Both references are seeded the same way: the emulator
with a second LOAD, the RTL by handing the address and the value to the
testbench as generics, so that the value lives in one place -- here.

WHAT THIS DOES NOT CATCH

Final architectural state, not an execution trace.  A value that is briefly
wrong and then overwritten before the program ends is invisible here -- fault
injection confirms it: corrupting the first of prog_simple's six memory writes
changes nothing, because a later write to the same address wins, while
corrupting the last one is caught immediately.  Divergence in cycle counts,
bus traffic and write ORDER is likewise out of scope; that is what the .writes
and .stats golden files are for.  The two checks are complementary, and neither
subsumes the other.

KNOWN DIVERGENCES

KNOWN_DIVERGENCE below lists whole programs that a given reference is expected
to FAIL, and ALLOWED_DIFFS lists address ranges where the two implementations
are not required to agree.  Both are claims that need justifying in the comment
next to them, not places to put a failure that has not been understood yet, and
a divergence that goes away is reported as an error of its own.

USAGE

    make crosscheck                     # every comparable program, vs the emulator
    make crosscheck_rtl                 # every comparable program, vs upstream's CPU
    make crosscheck TESTS=prog          # just one, the ordinary make way

Both references are built from the upstream commit pinned in the Makefile's
QNICE_REF, into a work directory under test/.  See test/README.md for the whole
picture, and test/tb_upstream.vhd for the system the RTL reference runs in.
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Only RAM is common ground.  0x8000 and up is the EAE in test/system.vhd and
# memory-mapped I/O in the emulator.
RAM_LO, RAM_HI = 0x0000, 0x7FFF

# The reserved status word every program writes just before its final HALT
# (0 = pass), and the value it is seeded with so that "never written" is
# distinguishable from "written as pass".  See test/README.md.
STATUS_ADDR = 0x7FFF
STATUS_SENTINEL = 0xDEAD

# Programs where this CPU and a given reference are KNOWN to disagree, with the
# reason.  These are not skipped: the divergence is asserted, so that if it ever
# goes away -- upstream changes its mind, or someone "fixes" our RTL to match --
# the entry becomes stale and this says so instead of quietly passing.
#
# Note how little the two lists have in common.  Every entry here is a place
# where the two upstream implementations disagree with each OTHER, and this CPU
# had to follow one of them; running only one reference would have left each
# such case looking like a settled question.
KNOWN_DIVERGENCE = {
    "emulator": {
        "prog_eae":
            "upstream's emulator computes the DIVS remainder with C's '%' "
            "(sign of the dividend) while both this repo's eae.vhd and "
            "upstream's OWN vhdl/EAE.vhd use numeric_std 'mod' (sign of the "
            "divisor); they differ on 8 of its 21 DIVS rows -- those where the "
            "operand signs differ and the remainder is non-zero. The hardware "
            "is the reference, so the emulator is the odd one out -- see the "
            "header of test/prog_eae.asm. '--reference rtl' agrees with us.",
        "prog_eae_stall":
            "the two EAEs differ in WHEN they compute. emulator/qnice.c "
            "recomputes only when the CSR is written (the arithmetic sits "
            "inside 'case IO_EAE_CSR'), while eae.vhd's arithmetic is "
            "combinational and re-evaluates whenever an operand changes -- "
            "which is the settling time its read stall exists to cover. This "
            "program's S3 deliberately writes both operands and reads the "
            "result back WITHOUT writing the CSR, so on the emulator the "
            "result register still holds S2's value and it halts at E_S3. That "
            "is the RTL behaviour the test is pinning, and '--reference rtl' "
            "confirms it: upstream's own EAE.vhd is combinational too.",
    },
    "rtl": {
        "prog_r15":
            "upstream's CPU reads R15 as the DESTINATION operand one word "
            "earlier than the emulator and than this CPU do. Its cs_decode "
            "latches both operands from the register file in one go "
            "(fsmDst_Value <= reg_read_data2), before the source's @R15++ "
            "post-increment that fetches an immediate has been applied, so in "
            "T3's 'ADD 0x0002, R15' at 0x0010 the destination reads 0x0011 -- "
            "the address of the immediate -- rather than 0x0012, the address "
            "of the next instruction, and the jump lands one word short, on "
            "the padding HALT at 0x0013. T3 is the only sub-test affected: "
            "replacing it with an equivalent 'ABRA, 1' makes the whole program "
            "pass on upstream's CPU, so the source path and @R15 agree. The "
            "ISA documentation "
            "does not settle the ordering, and qnice.c does settle it the "
            "other way, by reading the destination after the source. This CPU "
            "follows the emulator, which is what test/prog_r15.asm was written "
            "against; the two upstream references simply differ here.",
    },
}

# Programs that cannot be compared this way, and why.  Everything not named
# here is expected to agree word for word; a program is added to this list only
# with a reason that survives reading.
SKIP = {
    "prog_poll": "device-polling loop with no device: never halts, by design",
    "prog_poll_reg": "the control for prog_poll: likewise never halts",
}

# Address ranges the two implementations are not required to agree on.
#
# Each entry is (first, last, reason).  Keep these as tight as the reason
# actually justifies -- a wide range hides the next real disagreement.
ALLOWED_DIFFS = {
    # prog.asm's PTR_SR group uses R14 -- the Status Register itself -- as an
    # auto-modifying memory pointer.  Bits 5..0 of R14 are rewritten by the
    # flags of every instruction, so the pointer moves under its own program and
    # the address a store lands on depends on flag details that the two
    # implementations are not obliged to share.  The program's own comment says
    # so: that group checks COMPLETION, NOT THE VALUE.  The window is the
    # D_PTR_LOW/D_PTR_MID scratch area those tests point into.
    "prog": [(0x18C0, 0x18D8, "PTR_SR scratch: R14-as-pointer, values not comparable")],
}


def read_image(path):
    """Read a '0xADDR 0xVALUE' file (assembler .out, or emulator SAVE) into a dict."""
    mem = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                mem[int(parts[0], 16)] = int(parts[1], 16)
    return mem


WRITE_RE = re.compile(r"Write value 0x([0-9A-Fa-f]+) to memory 0x([0-9A-Fa-f]+)")

REG_WRITE_RE = re.compile(
    r"Write value 0x([0-9A-Fa-f]+) to register ([0-9A-Fa-f])(?: bank 0x([0-9A-Fa-f]+))?")

# The registers compared, and why it stops at R13.
#
# R14 is the status register.  Most of it is flags, which the implementations
# are not obliged to agree on instruction for instruction -- prog.asm's PTR_SR
# group is the standing example -- and neither side logs the dedicated
# flag-update port anyway, since that fires on nearly every instruction and
# would swamp the log.
#
# R15 is the program counter.  This CPU keeps the working PC in FETCH and
# writes the register file's copy only when an instruction targets R15, so at
# HALT that copy is stale by design; upstream's R15 is the real thing.  They
# describe different objects and comparing them would report a difference on
# every program.
REG_HI = 0xD


def apply_writes(mem, path):
    """Replay the memory writes from a .writes log over an image, in order."""
    count = 0
    with open(path) as f:
        for line in f:
            m = WRITE_RE.match(line)
            if m:
                mem[int(m.group(2), 16)] = int(m.group(1), 16)
                count += 1
    return count


def registers_from_log(path):
    """Replay the register writes in a .writes log into a final register file.

    Keyed by (bank, reg) for the banked R0-R7 and by (None, reg) for R8-R15,
    which the QNICE register file does not bank.  A register nothing ever wrote
    is absent and reads back as 0, which is what all three implementations
    power up holding -- see test/upstream.patch for the one that had to be made
    to.

    The bank is what makes this possible at all: "to register 3" names eight
    different registers over the life of a program, so without it the last
    value written to any of R0-R7 cannot be identified.  src/debug.vhd takes it
    from a port of its own on the register file rather than from the status
    register, so it is the bank the write actually landed in.
    """
    regs = {}
    with open(path) as f:
        for line in f:
            m = REG_WRITE_RE.match(line)
            if m:
                reg = int(m.group(2), 16)
                bank = int(m.group(3), 16) if m.group(3) is not None else None
                regs[(bank, reg)] = int(m.group(1), 16)
    return regs


def final_bank(path):
    """The register bank selected when the program halted, from its log.

    R14's upper byte selects the bank, and INCRB/DECRB reach it through the
    ordinary register write port, so the logged writes to R14 are enough --
    the dedicated flag-update port, which is not logged, only ever touches the
    low bits.  That last part is an assumption about what WRITE puts on that
    port rather than something stated here, so it is not relied on silently:
    the emulator reports the bank it finished in, and compare_registers below
    checks the two against each other.
    """
    bank = 0
    with open(path) as f:
        for line in f:
            m = REG_WRITE_RE.match(line)
            if m and int(m.group(2), 16) == 0xE:
                bank = int(m.group(1), 16) >> 8
    return bank


RDUMP_BANK_RE = re.compile(r"Register dump: BANK = ([0-9A-Fa-f]+)")
RDUMP_ROW_RE = re.compile(r"R(\d+)-R\d+:\s+((?:[0-9A-Fa-f]{4}\s*)+)")


def parse_rdump(text):
    """Read the emulator's RDUMP output into (registers, bank).

    The emulator can only show the register WINDOW it finished in -- its
    dump_registers() prints R0-R15 through read_register(), which resolves
    R0-R7 through the current bank -- so unlike the two RTL implementations
    there is no way to ask it for the other 255 banks.  What comes back is
    therefore keyed like registers_from_log()'s result but covers one bank, and
    the bank is returned alongside so that the comparison can check it against
    ours rather than assume it.
    """
    m = RDUMP_BANK_RE.search(text)
    if not m:
        return None, None
    bank = int(m.group(1), 16)
    regs = {}
    for row in RDUMP_ROW_RE.finditer(text):
        first = int(row.group(1))
        for i, word in enumerate(row.group(2).split()):
            reg = first + i
            regs[(bank if reg < 8 else None, reg)] = int(word, 16)
    return regs, bank


def run_emulator(emulator, out_file, dump_file, seed_file, timeout):
    """LOAD the program, seed the status word, RUN to HALT, SAVE the RAM.

    The seed is a second LOAD rather than part of the program image, so that
    nothing about the program under test has to change: LOAD merges the
    addresses it names over whatever is already there.
    """
    with open(seed_file, "w") as f:
        f.write("0x%04X 0x%04X\n" % (STATUS_ADDR, STATUS_SENTINEL))
    script = "LOAD %s\nLOAD %s\nRUN\nSAVE %s 0x%04X 0x%04X\nRDUMP\nQUIT\n" % (
        out_file, seed_file, dump_file, RAM_LO, RAM_HI)
    try:
        proc = subprocess.run([emulator], input=script, capture_output=True,
                              text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, None, "emulator did not halt within %ds" % timeout, None
    m = re.search(r"HALT instruction executed at address ([0-9A-Fa-f]+)", proc.stdout)
    if not m:
        # The emulator prints a diagnostic and halts on a rogue RTI/INT/EXC too;
        # surface whatever it said rather than a bare "no halt".
        tail = " | ".join(proc.stdout.strip().splitlines()[-3:])
        return None, None, "no HALT reported by the emulator (%s)" % (tail or "no output"), None
    if not os.path.exists(dump_file):
        return None, None, "emulator produced no memory dump", None
    return m.group(1), None, None, parse_rdump(proc.stdout)


def run_rtl(workdir, rom_file, dump_file, writes_file, timeout):
    """Run the program on upstream's own CPU under GHDL, and dump its RAM.

    Everything the run needs is a generic: the program, where to put the dump,
    and the status-word seed, which lives in this file so that the two
    references cannot drift apart on it.  test/tb_upstream.vhd does the rest,
    including writing the dump in the same format the emulator's SAVE produces.

    -fsynopsys is not optional and is upstream's choice, not ours: its
    qnice_cpu.vhd and register_file.vhd use ieee.std_logic_arith and
    ieee.std_logic_unsigned.  --ieee-asserts=disable-at-0 silences one
    CONV_INTEGER warning about the 'U' the status register holds before the
    first clock edge; nothing in the run reads that value.
    """
    cmd = ["ghdl", "-r", "--std=08", "-fsynopsys", "--workdir=" + workdir,
           "tb_upstream",
           "-gG_ROM=" + rom_file,
           "-gG_DUMP_FILE=" + dump_file,
           "-gG_WRITES_FILE=" + writes_file,
           "-gG_STATUS_ADDR=%d" % STATUS_ADDR,
           "-gG_STATUS_SEED=%d" % STATUS_SENTINEL,
           "--ieee-asserts=disable-at-0"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              cwd=os.path.dirname(HERE))
    except subprocess.TimeoutExpired:
        return None, None, "the upstream CPU did not halt within %ds" % timeout
    # tb_upstream reports "HALT at 0xADDR after N cycles, M instructions"; the
    # watchdog reports a TIMEOUT instead and the run exits non-zero.
    m = re.search(r"HALT at 0x([0-9A-Fa-f]+) after (\d+) cycles", proc.stderr + proc.stdout)
    if not m:
        tail = " | ".join((proc.stderr + proc.stdout).strip().splitlines()[-3:])
        return None, None, "no HALT reported by the upstream CPU (%s)" % (tail or "no output")
    if not os.path.exists(dump_file):
        return None, None, "the upstream CPU produced no memory dump"
    # The cycle count is reported, never checked: it is what this CPU's own
    # test/*.stats.golden measures against itself, here for the same program on
    # a machine that spends four to eleven cycles on each instruction.
    return m.group(1), "%s cycles" % m.group(2), None


def allowed(test, addr):
    for lo, hi, _reason in ALLOWED_DIFFS.get(test, []):
        if lo <= addr <= hi:
            return True
    return False


def compare_registers(our_log, ref_regs, ref_bank, reference):
    """Diff the final register files.  Returns (ok, message).

    ref_regs is keyed the same way registers_from_log() keys its result, except
    that the emulator can only report the window it finished in -- see
    run_emulator -- so its R0-R7 come back under the bank it names, and
    ref_bank is that bank.  For the RTL both sides carry every bank they ever
    wrote and ref_bank is None.
    """
    ours = registers_from_log(our_log)

    if ref_bank is not None:
        # A window, not a file: keep only what the reference can speak about,
        # and check first that the two agree on WHICH window that is. If they
        # do not, every R0-R7 comparison below would be against the wrong
        # register, so say that instead of reporting eight spurious diffs.
        our_bank = final_bank(our_log)
        if our_bank != ref_bank:
            return False, ("final register bank differs: cpu=0x%02X %s=0x%02X"
                           % (our_bank, reference, ref_bank))
        ours = {k: v for k, v in ours.items()
                if k[0] is None or k[0] == our_bank}

    diffs = []
    for key in sorted(set(ours) | set(ref_regs), key=lambda k: (k[1], k[0] or 0)):
        bank, reg = key
        if reg > REG_HI:
            continue
        if ours.get(key, 0) != ref_regs.get(key, 0):
            diffs.append((bank, reg, ours.get(key, 0), ref_regs.get(key, 0)))

    scope = ("R0-R13 in bank 0x%02X" % ref_bank) if ref_bank is not None \
        else "R0-R13, every bank written"
    if diffs:
        lines = ["%d register(s) of %s DIFFER" % (len(diffs), scope)]
        for bank, reg, q, e in diffs[:20]:
            where = "R%-2d" % reg + ("" if bank is None else " bank 0x%02X" % bank)
            lines.append("      %-16s cpu=0x%04X  %s=0x%04X" % (where, q, reference, e))
        if len(diffs) > 20:
            lines.append("      ... and %d more" % (len(diffs) - 20))
        return False, "\n".join(lines)

    return True, "%s identical" % scope


def compare(test, out_file, writes_file, dump_file, reference):
    """Diff the two final memory images.  Returns (ok, message)."""
    qnice = read_image(out_file)
    nwrites = apply_writes(qnice, writes_file)
    emu = read_image(dump_file)

    diffs, excused = [], 0
    for addr in range(RAM_LO, RAM_HI + 1):
        if emu.get(addr, 0) != qnice.get(addr, 0):
            if allowed(test, addr):
                excused += 1
            else:
                diffs.append((addr, qnice.get(addr, 0), emu.get(addr, 0)))

    words = RAM_HI - RAM_LO + 1
    detail = "%d words, %d memory writes replayed" % (words, nwrites)
    if excused:
        detail += ", %d excused" % excused

    if diffs:
        lines = ["%d of %s DIFFER" % (len(diffs), detail)]
        for addr, q, e in diffs[:20]:
            lines.append("      0x%04X  cpu=0x%04X  %s=0x%04X" % (addr, q, reference, e))
        if len(diffs) > 20:
            lines.append("      ... and %d more" % (len(diffs) - 20))
        return False, "\n".join(lines)

    return True, "identical (%s)" % detail


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="*", help="programs to check (default: all given)")
    ap.add_argument("--reference", choices=sorted(KNOWN_DIVERGENCE), default="emulator",
                    help="which upstream implementation to compare against "
                         "(default: emulator)")
    ap.add_argument("--emulator", help="path to the built qnice emulator "
                                       "(--reference emulator)")
    ap.add_argument("--workdir", help="GHDL library holding the analysed upstream "
                                      "CPU and tb_upstream (--reference rtl)")
    ap.add_argument("--timeout", type=int, default=600,
                    help="seconds to let the reference run (default 600)")
    args = ap.parse_args()

    reference = args.reference
    if reference == "emulator" and not args.emulator:
        ap.error("--reference emulator needs --emulator")
    if reference == "rtl" and not args.workdir:
        ap.error("--reference rtl needs --workdir")

    # One suffix per reference, so that the two runs' dumps can coexist in the
    # one work directory and either can be looked at after the other has run.
    suffix = {"emulator": ".emudump", "rtl": ".rtldump"}[reference]
    divergence = KNOWN_DIVERGENCE[reference]

    failures, skipped, passed, diverged = [], [], [], []

    for test in args.tests:
        if test in SKIP:
            skipped.append((test, SKIP[test]))
            continue

        out_file = os.path.join(HERE, test + ".out")
        writes_file = os.path.join(HERE, test + ".writes")
        dump_file = os.path.join(HERE, "crosscheck", test + suffix)

        needed = [out_file, writes_file]
        if reference == "rtl":
            # The RTL reference is handed the .rom the ordinary simulation uses,
            # rather than the .out the emulator's LOAD command reads.
            rom_file = os.path.join(HERE, test + ".rom")
            needed.append(rom_file)

        missing = [p for p in needed if not os.path.exists(p)]
        if missing:
            failures.append((test, "missing %s -- run 'make run TEST=%s' first"
                             % (", ".join(os.path.basename(p) for p in missing), test)))
            continue

        os.makedirs(os.path.dirname(dump_file), exist_ok=True)
        if reference == "emulator":
            seed_file = os.path.join(HERE, "crosscheck", test + ".seed")
            halt_addr, note, err, rdump = run_emulator(args.emulator, out_file,
                                                       dump_file, seed_file,
                                                       args.timeout)
            ref_regs, ref_bank = rdump if rdump else (None, None)
        else:
            # The RTL reference logs its writes the way this CPU does, so the
            # same replay reconstructs its whole register file -- every bank,
            # not just the one it halted in.
            ref_log = os.path.join(HERE, "crosscheck", test + ".rtlwrites")
            halt_addr, note, err = run_rtl(args.workdir, rom_file, dump_file,
                                           ref_log, args.timeout)
            ref_regs, ref_bank = (registers_from_log(ref_log), None) if not err else (None, None)
        if err:
            failures.append((test, err))
            continue

        # Did the program report a pass on the reference? The memory diff cannot
        # answer this on its own -- see the docstring.
        status = read_image(dump_file).get(STATUS_ADDR, 0)
        if status == STATUS_SENTINEL:
            verdict = "never wrote its status word (halted at 0x%s)" % halt_addr
        elif status != 0:
            verdict = "reported failure status 0x%04X (halted at 0x%s)" % (
                status, halt_addr)
        else:
            verdict = None

        if test in divergence:
            # Asserted, not skipped: the divergence has to still be there.
            if verdict:
                print("%-22s diverges as expected: %s" % (test, verdict))
                diverged.append(test)
            else:
                failures.append((test, "expected divergence is GONE (the program "
                                       "now passes on the %s) -- re-check and "
                                       "update KNOWN_DIVERGENCE" % reference))
            continue

        if verdict:
            failures.append((test, "did not pass on the %s: %s" % (reference, verdict)))
            print("%-22s FAILED on the %s: %s" % (test, reference, verdict))
            continue

        ok, message = compare(test, out_file, writes_file, dump_file, reference)
        if note:
            # On the first line: a failing message continues with one line per
            # differing word, and the note belongs to the run as a whole.
            head, _, rest = message.partition("\n")
            message = head + ", " + note + ("\n" + rest if rest else "")

        # Memory is only half the architectural state; the other half is the
        # register file, which neither reference could speak about until both
        # sides started recording the bank a write lands in.
        reg_ok, reg_message = True, "registers not compared"
        if ref_regs is None:
            reg_message = "registers not compared (%s reported none)" % reference
        else:
            reg_ok, reg_message = compare_registers(writes_file, ref_regs,
                                                    ref_bank, reference)

        print("%-22s %s" % (test, message))
        print("%-22s %s" % ("", reg_message))
        if ok and reg_ok:
            passed.append(test)
        elif not ok:
            failures.append((test, "final memory differs (%s halted at 0x%s)"
                             % (reference, halt_addr)))
        else:
            failures.append((test, "final registers differ (%s halted at 0x%s)"
                             % (reference, halt_addr)))

    for test, reason in skipped:
        print("%-22s skipped: %s" % (test, reason))

    print()
    print("reference: %s" % reference)
    print("%d compared, %d identical, %d differing, %d known-divergent, %d skipped"
          % (len(passed) + len(failures) + len(diverged), len(passed),
             len(failures), len(diverged), len(skipped)))
    for test in diverged:
        print("  %s: %s" % (test, divergence[test]))

    if failures:
        print()
        for test, reason in failures:
            print("FAILED %s: %s" % (test, reason))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
