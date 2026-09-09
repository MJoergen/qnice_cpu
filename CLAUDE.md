# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository. It is deliberately short: the module-level detail lives in a `CLAUDE.md` beside the
code it constrains, listed under [Notes loaded on demand](#notes-loaded-on-demand) below, which
Claude Code reads when it touches a file in that directory. What stays here is what has to be true
*before* any file is opened.

## What this is

A pipelined VHDL re-implementation of the QNICE CPU (from the
[QNICE-FPGA project](https://github.com/sy2002/QNICE-FPGA)), rewritten to use the Wishbone bus,
separate instruction/data interfaces, and formal verification techniques to prove correctness.
It is not a drop-in replacement for the original QNICE-FPGA CPU.

All VHDL in this repo is **VHDL-2008** (`ghdl --std=08`, `read_vhdl -vhdl2008` in the Vivado flow).
Use 2008 constructs freely (e.g. `ieee.numeric_std_unsigned`, unconstrained record elements).
No `ghdl` invocation passes `-frelaxed`: the design is conformant VHDL-2008, not
conformant-plus-waivers, and it should stay that way. House style is written up in
[CODING_STYLE.md](CODING_STYLE.md); the one rule with teeth beyond formatting is **no shared
variables** — see `src/sub/dp_ram.vhd` for why that constrains RAM inference. Most of the rest is
machine-checked: see [Linting](#linting) below.

Full architecture description: [doc/README.md](doc/README.md). Per-module design notes live next
to the code: [src/fetch/README.md](src/fetch/README.md), [src/icache/README.md](src/icache/README.md),
[src/registers/README.md](src/registers/README.md), [src/memory/README.md](src/memory/README.md),
[src/cpu_main/README.md](src/cpu_main/README.md).

## Commands

All from the repo root unless noted.

```
make test                             # run every test program headless; the CI entry point
make test_slow                        # same, against a deliberately slow memory model
make check TEST=prog_r15              # run one test program headless (sim + golden writes diff)
make run   TEST=prog_r15              # same, without the golden writes diff
make golden                           # regenerate every test/*.{writes,stats}.golden file
make crosscheck                       # diff every program against upstream's C emulator
make crosscheck_rtl                   # diff every program against upstream's own VHDL CPU
make sim                              # assemble test/prog.asm, run GHDL simulation, open gtkwave
make sim TEST=prog_interleave         # run a different test program (test/<name>.asm)
make sim REGISTER_BANK_WIDTH=8        # override register bank address width (default 8)
make system.bit                       # Vivado synthesis + bitstream (needs Vivado at $XILINX_DIR)
make utilization                      # refresh the measured numbers in doc/README.md (needs Vivado)
make diagrams                         # re-render every .tex diagram to .png (needs pdflatex)
make synth                            # Yosys synthesis (ghdl -a, then yosys -m ghdl synth_xilinx)
make formal                           # run all formal verification (delegates to formal/Makefile)
make lint                             # check every VHDL file against CODING_STYLE.md (needs vsg)
make clean                            # remove all generated files, including formal/ outputs
```

**Vivado is installed on this machine, and `vivado` is deliberately not on `$PATH`.** It lives at
`/opt/Xilinx/Vivado/2022.2` — the top-level `Makefile`'s `XILINX_DIR`, and the version
doc/README.md's utilization numbers were measured with. The two targets above source
`$(XILINX_DIR)/settings64.sh` themselves before invoking `vivado`, so they work from a shell that
has never seen it. `which vivado` returning nothing therefore says nothing about whether
`make system.bit` will run: do **not** report Vivado as missing or unavailable on the strength of
it, and do not add a `source settings64.sh` to any shell profile to "fix" it. (A `2024.1` is
installed alongside it; `XILINX_DIR` is a plain `=`, so switching versions means editing the
Makefile, and would move every number in doc/README.md.)

Test programs live in `test/*.asm` and are assembled with the external QNICE assembler at
`$HOME/git/sy2002/QNICE-FPGA/assembler/asm`, which must be checked out separately — **on the
`develop` branch**. That is the branch this repo follows, for the ISA as well as the tools, and it
is not that repository's default; the CI workflow pins that branch's commit for the same reason. The
path above is the top-level `Makefile`'s `ASSEMBLER ?=`, so it can be overridden —
`make test ASSEMBLER=<path>` is what
[.github/workflows/test.yml](.github/workflows/test.yml) does. That workflow runs
`make test` on every push to `main` and every pull request (formal verification and linting run in
their own workflows, see [Linting](#linting) below and
[formal/CLAUDE.md](formal/CLAUDE.md)); it builds only `qasm`/`qasm2rom` from
the upstream project rather than the whole QNICE toolchain, and asserts up front that the
installed GHDL really does map `std.env.finish(0)`/`stop(1)` onto process exit codes, since the
whole pass/fail signal rests on that.

**Reaching `HALT` does not mean the test passed.** Most test programs contain many `HALT`
instructions — in the self-checking `prog.asm` every failed sub-test branches to its own `HALT`.
So the verdict is not inferred from where the program stopped: each program writes a **status
word** to the reserved address `0x7FFF` (0 = pass) just before its final `HALT`, and
`test/test_monitor.vhd` snoops the data Wishbone bus for it and ends the simulation via
`std.env.finish(0)` / `stop(1)`. A `HALT` reached with no status write — which is every failure
`HALT`, at no cost to the failure paths — fails the run, as does never reaching a `HALT` (the
`G_TIMEOUT` watchdog in `tb_cpu.vhd`). `make check` / `make test` additionally diff **two** golden
files per program: the run's register/memory write log against `test/<name>.writes.golden`, and
its statistics against `test/<name>.stats.golden`. The one exception is any program named in the
Makefile's `NO_WRITES_GOLDEN` — today only `prog_mandel_perf`, whose log is 3.0 MB and whose
arithmetic is checked in-band instead; see [test/CLAUDE.md](test/CLAUDE.md#simulated-peripherals-the-eae).
Every one of these targets exits 0 if and only
if the test passed. See [test/README.md](test/README.md); if a golden diff is *expected*,
regenerate both with `make golden` and read the `git diff` carefully.

A run can also fail before any of that, on `p_unimplemented` in `src/cpu_main/write.vhd`: a
simulation-only assertion that kills the run if an instruction retires that nothing decodes. Today
that means the control commands `RTI`, `INT`, and `EXC`, and reserved opcode `0xD`. Without it they
are **silent no-ops** — DECODE classifies every CTRL instruction as no-operand/no-read/no-write, so
the microcode ROM returns entry 0, three bare `C_VAL_LAST`, and `alu_flags` leaves the SR alone via
its `when others => null`. The assembler emits them regardless (`RTI` is `0xE040`). This matters
most while interrupts are being implemented, since a half-finished `RTI` would otherwise look like
it works. Drop each arm of the check as its instruction gains a real implementation.

The statistics file is the performance counterpart of the writes log, and exists because a change
that makes the CPU flush twice as often produces an identical writes log and passes CI green.
`test_monitor.vhd` counts cycles (reset release to the retiring `HALT`), accepted beats on each
Wishbone bus (`cyc and stb and not stall`), and cycles in which *both* buses accepted a beat. That
last one measures the Harvard split directly: for `prog.asm`, 1884 of 1927 data requests coincide
with an instruction fetch, so serialising them onto one port would cost at least +12.1% of the run.
Note the instruction count includes speculative fetches that a flush later discarded, which is part
of why it is worth watching.

Retiring a `HALT` now stops the CPU. `p_halt_fetched` in `src/cpu.vhd` gates the
ICACHE-to-DECODE handshake off as soon as a `HALT` is handed to DECODE (gating on the `halt_o`
retire pulse from WRITE would be one or two instructions too late), and clears that gate on a
pipeline flush, since a branch retiring can discard an already-accepted `HALT` —
`test/prog_pipeline.asm` branches over twelve `HALT`s used as padding and depends on this.

### Linting

`make lint` runs [VSG](https://vhdl-style-guide.readthedocs.io/) (VHDL Style Guide) over all 29
VHDL files with the repo's `vsg.yml`, which maps CODING_STYLE.md onto VSG's rule set. CI runs it
too, in its own workflow [.github/workflows/lint.yml](.github/workflows/lint.yml), from a **pinned**
vsg release — the pin is load-bearing, because VSG adds and re-scopes rules between releases and
`vsg.yml` only overrides the defaults it knows about, so an unpinned bump can turn the job red
with no VHDL change at all.

**The tree is clean: zero errors.** What remains is 39 `length_001` warnings, which are the
100-column *target* of CODING_STYLE.md section 3 advising rather than failing; warnings do not fail
the job. Every rule VSG applies here is now either stated in CODING_STYLE.md or deliberately
disabled in `vsg.yml` with the reason written next to it, so wanting to change a `vsg.yml` rule is
a sign CODING_STYLE.md has an unanswered question — answer it there first. Deliberate *local*
exceptions (an instruction-format table, an opcode matrix, an aligned boolean expression) use
VSG's own `-- vsg_off <rule>` / `-- vsg_on <rule>` markers at column 0, next to a comment saying
why; six files carry them. Most violations are machine-fixable with
`vsg -c vsg.yml --fix -f <files>`, but read the diff: `--fix` will happily reformat a deliberate
table.

Prose (both documentation and comments) shall be written using Oxford comma.

## Notes loaded on demand

Eight files carry the detail that used to sit in this one. Each is loaded automatically when a file
in its directory is read or edited — so read the relevant one *before* changing measured behaviour,
not after.

| File | Covers | The thing it exists to stop you undoing |
|---|---|---|
| [src/cpu_main/CLAUDE.md](src/cpu_main/CLAUDE.md) | microcode decomposition, register bank switch, self-modifying-code flush, early redirect | `alu_data.vhd`'s `null` arms are load-bearing; the `smc_push` window is 8 words, measured, not arbitrary |
| [src/fetch/CLAUDE.md](src/fetch/CLAUDE.md) | the redirect that leaves `CYC` asserted | the redirect step must run *before* the issue step, and `wb_stale` counts against the issue budget |
| [src/registers/CLAUDE.md](src/registers/CLAUDE.md) | writing PSL against write-before-read forwarding | a forwarding property without its escape clause fails BMC on something that is not a bug |
| [src/sub/CLAUDE.md](src/sub/CLAUDE.md) | the six elastic-pipeline primitives (no README of their own) | buffers are combinational both ways, `two_stage_fifo`'s reset is asymmetric on purpose, `dp_ram` gets one address per port |
| [src/memory/CLAUDE.md](src/memory/CLAUDE.md) | the op-type FIFO behind a bare Wishbone ACK | it requires in-order ACKs, and `mreq_accept` must read registered state only |
| [test/CLAUDE.md](test/CLAUDE.md) | differential testing, the EAE, the slow-memory model, the bus multiplexer | `make test_slow` is what gives `wb_mux` teeth; the mux is kept out of the bitstream for measured timing reasons |
| [formal/CLAUDE.md](formal/CLAUDE.md) | the `.psl`/`.sby`/`.gtkw` triplet, the stamp files, CI | all thirteen DUTs pass; anything commented out of `DUTS` to narrow scope goes back |
| [hw/CLAUDE.md](hw/CLAUDE.md) | Yosys synthesis, utilization numbers, the 7.45 ns constraint | `make synth` elaborates `cpu` and not `system` by necessity; timing is routing-dominated, so unrelated edits move it |

## Architecture

Four-stage pipeline: **FETCH → DECODE → PREPARE → WRITE**, plus two shared modules, **REGISTERS**
(2 read ports from DECODE, 1 write port from WRITE) and **MEMORY** (2 read ports from PREPARE, 1
write port from WRITE, backed by a Wishbone bus). DECODE, PREPARE, and WRITE are combined into a
single VHDL entity CPU_MAIN (in `src/cpu_main/cpu_main.vhd`) mainly to simplify formal
verification of the interactions between them. CPU_MAIN also instantiates **SEQUENCER** on the
DECODE→PREPARE link; it is not a stage (no payload registers, no latency) but a one-to-many
adapter, and it shares the two stages' flush reset. The block diagram is
[doc/cpu.tex](doc/cpu.tex), rendered to `doc/cpu.png` by `make diagrams`.

Stage-to-stage handshaking uses an AXI-style `VALID`/`READY` protocol throughout (also on the
Wishbone bus, via `stall`/`ack`). Two independent sources of back-pressure exist: an
instruction may expand into up to three micro-ops, and SEQUENCER issues one per cycle while holding
its ready low, which stalls DECODE and in turn FETCH; and MEMORY stalls PREPARE while waiting on
the Wishbone bus.

Instruction and data memory are separate interfaces (Harvard-style) but backed by the same
physical dual-port RAM, since a program must be loadable and then executable from the same memory.
That RAM is `src/sub/dp_ram.vhd`, the same module the register file uses, and it has **two
read ports but only one write port**, on the data side.
The instruction side never writes — the program arrives through `G_INIT_FILE` and self-modifying
code stores over the data bus — and it cannot: Vivado will not infer a RAM from two write ports
unless they sit in two processes over a `shared variable`, which VHDL-2008 does not allow. The
file's header records the whole argument.
The working Program Counter (`R15`) lives inside FETCH. The register file *does* have an `R15`
slot in its upper bank and WRITE writes it whenever an instruction targets `R15` (i.e. on
branches), but it is stale during sequential execution, so PREPARE substitutes the real PC for
either operand whenever `R15` is read, in any addressing mode (`src_val_pc`/`dst_val_pc` in
`prepare.vhd`; see [src/cpu_main/README.md](src/cpu_main/README.md#reading-r15)). Reading that
stale slot directly was a real bug, fixed by that substitution;
`R14` (Status Register) is handled specially in the register file (written alongside any regular
register write at the end of most instructions); `R13` (Stack Pointer) is an ordinary register,
handled in DECODE.

### Directory layout

- `src/README.md` — the map of this tree: what each file is, and the only write-up of the
  three that have none of their own (`cpu.vhd`, `cpu_constants.vhd`, `debug.vhd`).
- `src/cpu_constants.vhd` — shared constants/types used across modules.
- `src/fetch/` — WISHBONE instruction fetcher.
- `src/icache/` — two-word instruction buffer between FETCH and DECODE.
- `src/registers/` — register file (dual-port RAM based, write-before-read).
- `src/memory/` — Wishbone-facing memory arbiter (source/destination operand buffers).
- `src/cpu_main/` — DECODE, SEQUENCER, PREPARE, WRITE, and the `sub/` microcode ROM and ALU.
  SEQUENCER sits beside the stages rather than in `sub/` because `cpu_main.vhd` instantiates it
  itself, on the DECODE→PREPARE link.
- `src/interrupt/` — **no VHDL yet.** A README and a timing diagram only: the port list and
  handshake `interrupt.vhd` will have to implement, drawn ahead of the module because the bus
  protocol is the part of the feature the upstream sources disagreed about most. The CPU does
  **not** implement the `INT_N`/`IGRANT_N` daisy chain: it presents an AXI-stream request port
  (`irq_valid_i`/`irq_ready_o`/`irq_addr_i`), sees exactly one interrupt-generating device, and
  leaves chaining and arbitration to an adaptation layer outside it — the same concession already
  made for the Harvard split and Wishbone. It is task T2 of
  [doc/interrupts.md](doc/interrupts.md), and its `timing.tex` is in the Makefile's `TIMINGS`, so
  `make diagrams` renders it like any other. Read it as a specification, not as a description of
  something that exists; the diagram is to be redrawn against a real simulation once the module
  runs.
- `src/sub/` — reusable elastic-pipeline building blocks, see
  [Elastic pipeline building blocks](src/sub/CLAUDE.md).
- `src/cpu.vhd` — top-level entity tying FETCH, ICACHE, REGISTERS, MEMORY, and CPU_MAIN together.
- `test/` — testbench (`tb_cpu.vhd`), memory models, the pass/fail monitor (`test_monitor.vhd`),
  and `.asm` test programs. See [test/README.md](test/README.md) for how to tell a passing run
  from a failing one. `test/tb_upstream.vhd`, `test/upstream.patch` and `test/crosscheck.py`
  belong to the differential tests instead — see
  [Differential testing against upstream](test/CLAUDE.md#differential-testing-against-upstream). `test/eae.vhd` is a simulation-only arithmetic peripheral,
  `test/wb_dp_mem.vhd` the memory model whose latency generics drive `make test_slow`, and
  `test/wb_mux.vhd` the order-restoring data bus multiplexer between them,
  and `test/prog_mandel_stats.asm` the instrumented build of
  `test/prog_mandel_perf.asm` — see
  [Simulated peripherals: the EAE](test/CLAUDE.md#simulated-peripherals-the-eae),
  [Simulating a slow memory](test/CLAUDE.md#simulating-a-slow-memory) and
  [The data bus multiplexer](test/CLAUDE.md#the-data-bus-multiplexer).
  One of the programs, `test/prog_waveform.asm`, is not really a test: it
  is the program the pipeline timing diagram in
  [src/cpu_main/README.md](src/cpu_main/README.md#waveforms) was read off, and it is in `TESTS`
  only so that a change invalidating the diagram's quoted addresses and cycle counts fails the
  writes-log diff. The diagram itself is hand-written in `src/cpu_main/timing.tex` and rendered
  by `make diagrams`; nothing derives it from the simulation automatically.
  `test/prog_poll.asm` is the same idea for the ten-cycle polling loop drawn in
  [doc/loop_timing.tex](doc/loop_timing.tex), but it is deliberately **not** in `TESTS`: it is a
  device-polling loop with no device, so it never halts and `make check TEST=prog_poll` would run
  into the watchdog. Run it with an explicit `--stop-time`, as its own header says.
  `test/prog_poll_reg.asm` is that program's control — the same five-word loop at the same
  addresses, reading a register instead of memory, and so nine cycles per iteration rather than
  ten. That difference is the measured cost of the data access quoted in doc/README.md, so the
  two must stay word-for-word aligned; it does not halt either, and is likewise not in `TESTS`.
- `hw/` — Vivado XDC constraints / synthesis TCL (generated).
- `formal/` — one `.psl`/`.sby`/`.gtkw` triplet per formally-verified module.
- `doc/` — architecture overview and block diagram source (`cpu.tex`/`cpu.png`, TikZ, rendered by
  `make diagrams`; it replaced a diagrams.net `cpu.drawio` that could only be edited in the GUI).
