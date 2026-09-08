# A pipelined implementation of the QNICE CPU

[![test](https://github.com/MJoergen/qnice_cpu/actions/workflows/test.yml/badge.svg)](https://github.com/MJoergen/qnice_cpu/actions/workflows/test.yml)
[![formal](https://github.com/MJoergen/qnice_cpu/actions/workflows/formal.yml/badge.svg)](https://github.com/MJoergen/qnice_cpu/actions/workflows/formal.yml)

The reason for this implementation is to increase the performance of the QNICE
CPU, and to use techniques from formal verification to prove its correctness.

**Contents**

* [Relation to QNICE-FPGA](#relation-to-qnice-fpga) — the three architectural
  differences, and the fork that runs the QNICE monitor on this CPU
* [Micro-operations](#micro-operations) — the idea the whole design rests on
* [Which upstream version](#which-upstream-version) — why `develop`, pinned to a
  commit
* [Documentation](#documentation) — pointers into [`doc/`](doc) and the
  per-module write-ups
* [Verification](#verification) — the five independent checks
  * [A self-checking simulation suite](#a-self-checking-simulation-suite)
  * [Differential testing against the reference emulator](#differential-testing-against-the-reference-emulator)
  * [Differential testing against the upstream CPU](#differential-testing-against-the-upstream-cpu)
  * [Formal verification](#formal-verification)
  * [Style linting](#style-linting)
  * [Where to read more](#where-to-read-more)
* [Continuous integration](#continuous-integration) — what runs on every push,
  and what does not
* [Makefile](#makefile) — every target

## Relation to QNICE-FPGA

This version of the QNICE CPU (from the [QNICE-FPGA
project](https://github.com/sy2002/QNICE-FPGA)) is not a drop-in replacement,
for the following three reasons:
* This design uses the [Wishbone memory
  bus](https://zipcpu.com/doc/wbspec_b4.pdf).
* This design uses separate instruction and data interfaces.
* This design expects (at least) one clock cycle delay when reading from
  instruction and/or data memory.

Modifying the QNICE-FPGA project to accommodate that is no longer hypothetical:
**it has been done**. The branch
[`mfj_update_qnice_cpu`](https://github.com/MJoergen/QNICE-FPGA/tree/mfj_update_qnice_cpu)
of a fork of QNICE-FPGA runs the QNICE monitor and its I/O devices on this CPU on
the Nexys4DDR, and commit
[`cfb0893`](https://github.com/MJoergen/QNICE-FPGA/commit/cfb0893eb0a12180de822f39c30e32bf21a75c11)
is where the old CPU is swapped out for this one. The changes are confined to the
memory system: ROM and RAM each get a second port, so both are reachable from both
buses; the Wishbone address is sampled and held, because the I/O devices expect it
to stay valid outside the `STB` pulse; and `ACK` is driven from the existing
`wait_for_data` signal. Interrupts are the one part not covered, since this CPU
does not implement them yet.

That branch's [`doc/cpu_replacement.md`](https://github.com/MJoergen/QNICE-FPGA/blob/mfj_update_qnice_cpu/doc/cpu_replacement.md)
writes the retrofit up, and carries the like-for-like comparison it makes
possible — same board, same monitor, same toolchain (Vivado 2023.1). The CPU
drops from 3497 to 938 slice LUTs (at 396 → 586 registers, and 2 BRAMs for the
register banks); the system closes timing at 72.73 MHz where the old one was
already marginal at 50 MHz; and `mandel_perf_test.asm` falls from 3.29 to 1.98
cycles per instruction, for a **2.4x speedup in wall time**.

## Micro-operations

The overall idea of this implementation is to convert each
[instruction](https://github.com/sy2002/QNICE-FPGA/blob/b1fb36c56508d1237f662f6234b3bfa4142b3432/doc/intro/qnice_intro.pdf)
into a sequence of micro-operations, such as:
* Read from memory to source operand buffer
* Read from memory to destination operand buffer
* Write to memory
* Write to register

The reason is that e.g. the instruction `ADD @R0, @R1` performs two memory
reads (from `@R0` and `@R1`) and one memory write (to `@R1`). Since only one
memory operation is possible in each clock cycle, such an instruction will
need to be serialized and will take a total of three clock cycles.

## Which upstream version

The [QNICE-FPGA project](https://github.com/sy2002/QNICE-FPGA) has two
long-lived branches that have genuinely diverged, so "the QNICE ISA" is not on
its own a precise statement. **This repo follows `develop`, pinned to commit
[`b1fb36c`](https://github.com/sy2002/QNICE-FPGA/tree/b1fb36c56508d1237f662f6234b3bfa4142b3432)**
(2024-04-10, and the head of that branch ever since) — *not* the repository
default, which is `master`.

The two are not merely an older and a newer version of the same thing. `develop`
is 567 commits ahead of `master`, while `master` carries 22 commits that are not
on `develop` and has the later head date of the two, so choosing whichever looks
newest gives the wrong answer. They differ where it matters here:
`assembler/qasm.c` differs by some 300 lines, and even the instruction-set
document is not the same file on the two branches — the link above is pinned to
the `develop` copy.

`develop` is where the ISA this CPU implements is defined: its `vhdl/alu.vhd`
is the reference that the flag behaviour in `src/cpu_main/sub/alu_flags.vhd`
was checked against, and its `emulator/` is what the programs in
[`test/`](test) were cross-checked on. The assembler that builds those
programs has to come from there too, which is why
[`test.yml`](.github/workflows/test.yml) checks the upstream repository out at
that exact commit rather than at a branch name — a branch would be free to move
under CI the moment upstream pushed to it, which is the ambiguity this section
exists to remove. Every `test/*.rom` happens to assemble byte-identical from
either branch's `qasm` today, so this is not a live bug — it stops a local
checkout and CI from silently drifting apart. The trade is that an upstream
assembler fix now has to be picked up by bumping that pin by hand.

## Documentation
Please go to the [doc](doc) directory for more in-depth description of the
architecture and the design.

## Verification

A pipelined CPU is easy to get almost right, so this design is checked in five
independent ways, each catching what the others cannot, and all of them running
in CI on every push.

### A self-checking simulation suite

Fourteen QNICE assembly programs in [`test/`](test) run against the CPU on every
push. The broad one, `prog.asm`, is a self-checking instruction suite in five
groups: flags against branching, instructions against every flag combination,
every addressing mode of `MOVE` and `SUB`, conditional branching against every
addressing mode, and every remaining instruction with both operands in memory —
that last group checked differentially, each instruction against its own
register form, which is what pins down the per-opcode decode tables.

The other thirteen are narrow, each cornering one mechanism: read-after-write
and register-bank hazards (`prog_hazard.asm`), `R15` used as an ordinary ALU
operand (`prog_r15.asm`), self-modifying code (`prog_self_modifying.asm`), the
early branch redirect (`prog_subroutine.asm`), flag timing (`prog_flags.asm`),
bus response ordering (`prog_wb_mux.asm`), and so on.
`prog_mandel_perf.asm` is a real program doing real work — a Mandelbrot sweep
that checksums its own arithmetic — so the suite's instruction and memory-access
mix is not purely hand-written corner cases.

Three things make the suite hard to fool:

* **No test infers its verdict from where the program stopped.** Each writes a
  status word that `test/test_monitor.vhd` snoops off the data bus, so reaching
  a `HALT` is never mistaken for passing — and every failure path is a failure
  automatically, at no cost to the failure paths.
* **Every run is diffed against two committed reference files**: the complete
  log of register and memory writes, so a value that is right but lands in the
  wrong order is caught; and a statistics file counting cycles and bus traffic,
  so a change that keeps the CPU correct while making it slower cannot pass
  unnoticed.
* **`make test_slow` runs the whole suite again against a deliberately slow
  memory model**, with stall and ACK delays on both ports. That exercises the
  outstanding-request accounting and response-ordering paths that a
  zero-latency memory leaves dormant — several of them are unreachable
  otherwise.

### Differential testing against the reference emulator

Everything above compares this CPU against **itself**: the golden files were
recorded from a passing run of this implementation, so an answer that has been
wrong since they were written passes them green forever. `make crosscheck`
closes that gap. It runs every program a second time on the **reference
emulator** from the QNICE-FPGA project, `emulator/qnice.c`, built from the
commit pinned above, and diffs the final contents of RAM against what this CPU
left behind.

**Twelve of the fourteen programs leave memory bit-identical** — every one of
the 32768 words of `0x0000`-`0x7FFF`, from the instruction suite to a
170000-cycle Mandelbrot sweep. Four words in `prog.asm` are excused for a reason
the program documented before this check existed: its `PTR_SR` group uses `R14`
— the Status Register itself — as an auto-modifying memory pointer, so the
address a store lands on depends on flag details the two implementations are not
obliged to share. That group checks completion, not values, and the harness
found exactly those four words and nothing else.

The other two programs are the EAE tests, and there the **reference emulator is
the one that is out of step with its own project's hardware**. Signed division's
remainder is the clearest case: `eae.vhd` uses `numeric_std`'s `mod`, whose sign
follows the divisor, exactly as upstream's own `vhdl/EAE.vhd` does — while
upstream's *emulator* uses C's `%`, whose sign follows the dividend. The two
differ on every case where the operands have different signs and the remainder
is non-zero. Both divergences are recorded with their reason and **asserted**,
so that if one ever disappears the harness says so instead of quietly passing.

Two caveats worth stating plainly. This compares **final architectural state,
not an execution trace**, so a value that is briefly wrong and then overwritten
is invisible to it — fault injection confirms the boundary in both directions.
And it compares memory, not registers, because the write log records a register
number without its bank. Cycle counts and write *order* stay the golden files'
job. The checks are complementary; none of them subsumes another.

### Differential testing against the upstream CPU

The emulator is only one of the two implementations the QNICE-FPGA project
ships, and it is the *less* authoritative one: the other is `vhdl/qnice_cpu.vhd`
— upstream's own CPU, a multi-cycle FSM where this one is a four-stage pipeline
— and that is what QNICE-FPGA actually synthesises. `make crosscheck_rtl` runs
every program on it under GHDL and makes the same comparison, through the same
harness. **Thirteen of the fourteen leave memory bit-identical**, again across
all 32768 words, with two of `prog.asm`'s `PTR_SR` words excused by the range
above — a different two from the ones the emulator differs on, which is itself a
small demonstration that an `R14`-as-pointer address is not a shared quantity.

Upstream's CPU needs a system around it, and that part is ours:
[`test/tb_upstream.vhd`](test/tb_upstream.vhd) gives it the smallest one these
programs need — one writable 32 kW RAM over `0x0000`-`0x7FFF` and the EAE —
rather than upstream's `env1.vhd`, whose memory map puts ROM where every program
in [`test/`](test) is linked. The RAM is modelled on upstream's own
`block_ram.vhd`, not on this repo's `dp_ram.vhd`, because it is upstream's CPU
that has to be satisfied by it. Its CPU, ALU and EAE are analysed exactly as
they ship, into a GHDL library of their own; one file, the register file,
carries [`test/upstream.patch`](test/upstream.patch), two hunks of which make it
simulate under GHDL at all and one of which zeroes its register arrays, so that
the reference powers up in the same architectural state this CPU and the
emulator do. Every reason is in that patch's header, and it is applied to an
extracted copy — nobody's checkout is written to.

**Running both references is not redundancy — it is the point.** The programs
that fail are different ones in each direction, and every one of them is a place
where the two upstream implementations disagree with *each other*, so a single
reference makes each look like a settled question:

* The **two EAE tests pass here** and fail on the emulator. That turns the
  paragraph above — that upstream's own `EAE.vhd` computes the `DIVS` remainder
  as we do — from an argument about reading upstream's source into an end-to-end
  result.
* **`prog_r15.asm` fails here** and passes on the emulator, on a question the
  ISA documentation does not settle: what `R15` reads as when it is an
  instruction's *destination* and its source was the immediate `@R15++`.
  Upstream's `cs_decode` latches both operands at once, before that
  post-increment, so `ADD 0x0002, R15` reads its destination one word low and
  the jump lands one word short. The emulator reads the destination after the
  source, and this CPU follows the emulator, which is what the program was
  written against. That one sub-test is the whole of it: replacing it with an
  equivalent unconditional branch makes the program pass on upstream's CPU too.

Each is recorded against the reference it applies to and **asserted**, the same
way the emulator's two are: a divergence that disappears fails the harness
rather than quietly passing.

One free byproduct: the upstream CPU's cycle count, reported per program and
checked against nothing. `prog.asm` costs it 22333 cycles against this CPU's
15581, and the Mandelbrot sweep 281583 against 170041 — 1.43x and 1.66x, on the
same programs and the same memory latency.

### Formal verification

Thirteen modules are formally verified with SymbiYosys and the GHDL plugin:
twelve CPU modules under [`src/`](src), plus the testbench bus multiplexer that
the CPU's in-order response assumption rests on. That is 39 jobs — 14 bounded
model checking, 10 k-induction, 15 cover — over 217 assertions and 109 cover
points in [`formal/`](formal).

Every elastic-pipeline building block the design is assembled from is proven
individually, as are FETCH, ICACHE, REGISTERS, MEMORY, SEQUENCER and the
combined DECODE/PREPARE/WRITE core. The properties are not decoration: several
of the design's subtler invariants — pipeline flushes on a register-bank change,
the deferred flush on a subroutine push, Wishbone request accounting across a
redirect — are stated there, and are the tripwires that catch a narrowing or a
silent revert which the simulation suite would let through green.

### Style linting

`make lint` checks all 29 VHDL files against
[`CODING_STYLE.md`](CODING_STYLE.md) using
[VSG](https://vhdl-style-guide.readthedocs.io/) from a pinned release. The tree
is clean.

### Where to read more

[`test/README.md`](test/README.md) gives the pass criterion, both golden
comparisons, and what each program covers, in full. [`formal/`](formal) holds
one `.psl`/`.sby`/`.gtkw` triplet per verified module.

## Continuous integration

Everything above runs on every push to `main`, every pull request, and on
demand, split across three workflows so that a style violation and a failed
proof do not hide each other. The two badges at the top of this file are
`test.yml` and `formal.yml`.

| Workflow | Runs | Covers |
|---|---|---|
| [`test.yml`](.github/workflows/test.yml) | `make test`, `make test_slow`, `make crosscheck`, `make crosscheck_rtl` | all fourteen programs, four times: against a zero-latency memory with both golden files diffed, against a slow one, against the reference emulator, and against upstream's own CPU |
| [`formal.yml`](.github/workflows/formal.yml) | `make -C formal -k`, then `formal/check_gtkw.py` | all 39 formal jobs over the thirteen verified modules, plus the GTKWave save files |
| [`lint.yml`](.github/workflows/lint.yml) | `make lint` | all 29 VHDL files against [`CODING_STYLE.md`](CODING_STYLE.md) |

A few details are load-bearing rather than incidental:

* **The test job builds its own assembler.** `test/*.asm` is assembled by the
  upstream QNICE assembler, which is not vendored here, so the workflow checks
  out the QNICE-FPGA repository at the commit pinned in
  [Which upstream version](#which-upstream-version) and compiles just `qasm` and
  `qasm2rom` from it — not the whole QNICE toolchain — then points the Makefile
  at it with `ASSEMBLER=<path>`. `make crosscheck` and `make crosscheck_rtl`
  then take the reference emulator and the reference CPU out of that same
  checkout at that same commit, so the assembler and
  the reference cannot drift apart — and since `actions/checkout` leaves a
  shallow clone holding only that one commit, a drift would fail loudly rather
  than quietly cross-check against something else.
* **It checks the tool before trusting the verdict.** The entire pass/fail
  signal rests on GHDL mapping `std.env.finish(0)` and `stop(1)` onto process
  exit codes. The workflow asserts that up front on a three-line entity, so an
  unexpected GHDL build fails loudly there rather than silently reporting all
  fourteen programs as green.
* **`-k` on the formal run** is what makes the job report the state of all
  thirteen DUTs instead of stopping at the first failure; `make` still exits
  non-zero if any of them failed. `check_gtkw.py` is then a step of its own with
  `if: always()`, because the make target hangs off the pass-stamps and would be
  skipped on exactly the red build where someone wants to open a trace.
* **Three things are pinned**, and each for the same reason: the upstream
  commit, the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
  release that supplies SymbiYosys, Yosys with the GHDL plugin, GHDL and the SMT
  solvers, and the VSG release. Any of them tracking "latest" could turn a job
  red without a line of VHDL changing. Bump them deliberately.
* **A failing run leaves the evidence behind.** `test.yml` uploads every
  `test/*.writes` log, and `formal.yml` uploads the `sby` logs and the
  counterexample VCDs, so a golden mismatch or a failed property can be read off
  the artifacts rather than reproduced first.

**What CI does not cover is the Vivado flow.** `make system.bit` and
`make utilization` need a 38 GB licensed install that GitHub-hosted runners
cannot host, so synthesis results, the utilization tables in
[`doc/README.md`](doc/README.md) and every timing number quoted in this
repository are refreshed by hand on a machine that has Vivado. The Yosys
`make synth` target — a second opinion on synthesisability, not a build — is not
in CI either.

## Makefile
The current makefile supports the following targets:
* `make test`           : Run all test programs headless; this is the CI entry point
* `make test_slow`      : Run them all against a deliberately slow memory model
* `make crosscheck`     : Diff every program against the reference emulator
* `make crosscheck_rtl` : Diff every program against upstream's own CPU
* `make check`          : Run a single test program headless
* `make run`            : Run a single test program without the golden comparisons
* `make sim`            : Run simulation, then open the waveform in gtkwave
* `make golden`         : Regenerate the `test/*.{writes,stats}.golden` files
* `make system.bit`     : Run synthesis using Vivado
* `make utilization`    : Refresh `doc/README.md`'s numbers (needs Vivado)
* `make synth`          : Run synthesis using yosys
* `make diagrams`       : Re-render every `.tex` diagram to `.png` (needs pdflatex)
* `make formal`         : Run formal verification
* `make lint`           : Check every VHDL file against `CODING_STYLE.md` (needs vsg)
* `make clean`          : Remove all generated files

By default these assemble and run [`test/prog.asm`](test/prog.asm); pass
`TEST=<name>` to pick one of the other programs in [`test/`](test). Every one of
them exits 0 if and only if the test passed, so they can be run unattended.
