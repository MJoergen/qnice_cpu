# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A pipelined VHDL re-implementation of the QNICE CPU (from the
[QNICE-FPGA project](https://github.com/sy2002/QNICE-FPGA)), rewritten to use the Wishbone bus,
separate instruction/data interfaces, and formal verification techniques to prove correctness.
It is not a drop-in replacement for the original QNICE-FPGA CPU.

All VHDL in this repo is **VHDL-2008** (`ghdl --std=08`, `read_vhdl -vhdl2008` in the Vivado flow).
Use 2008 constructs freely (e.g. `ieee.numeric_std_unsigned`, unconstrained record elements).

Full architecture description: [doc/README.md](doc/README.md). Per-module design notes live next
to the code: [src/fetch/README.md](src/fetch/README.md), [src/registers/README.md](src/registers/README.md),
[src/memory/README.md](src/memory/README.md), [src/cpu_main/README.md](src/cpu_main/README.md).

## Commands

All from the repo root unless noted.

```
make test                             # run every test program headless; the CI entry point
make check TEST=prog_r15              # run one test program headless (sim + golden writes diff)
make run   TEST=prog_r15              # same, without the golden writes diff
make golden                           # regenerate every test/*.writes.golden reference file
make sim                              # assemble test/prog.asm, run GHDL simulation, open gtkwave
make sim TEST=prog_interleave         # run a different test program (test/<name>.asm)
make sim REGISTER_BANK_WIDTH=8        # override register bank address width (default 8)
make system.bit                       # Vivado synthesis + bitstream (needs Vivado at $XILINX_DIR)
make utilization                      # refresh the measured numbers in doc/README.md (needs Vivado)
make timing                           # re-render src/cpu_main/timing.png from timing.tex (needs pdflatex)
make synth                            # Yosys synthesis (ghdl -a, then yosys -m ghdl synth_xilinx)
make formal                           # run all formal verification (delegates to formal/Makefile)
make clean                            # remove all generated files, including formal/ outputs
```

Test programs live in `test/*.asm` and are assembled with the external QNICE assembler at
`$HOME/git/sy2002/QNICE-FPGA/assembler/asm` (must be checked out separately). That default lives in
the top-level `Makefile` as `ASSEMBLER ?=`, so it can be overridden — `make test ASSEMBLER=<path>`
is what [.github/workflows/test.yml](.github/workflows/test.yml) does. That workflow runs
`make test` on every push to `main` and every pull request (formal verification runs separately,
see below); it builds only `qasm`/`qasm2rom` from
the upstream project rather than the whole QNICE toolchain, and asserts up front that the
installed GHDL really does map `std.env.finish(0)`/`stop(1)` onto process exit codes, since the
whole pass/fail signal rests on that.

**Reaching `HALT` does not mean the test passed.** Most test programs contain many `HALT`
instructions — in the self-checking `prog.asm` every failed sub-test branches to its own `HALT`.
So the verdict is not inferred from where the program stopped: each program writes a **status
word** to the reserved address `0x1FFF` (0 = pass) just before its final `HALT`, and
`test/test_monitor.vhd` snoops the data Wishbone bus for it and ends the simulation via
`std.env.finish(0)` / `stop(1)`. A `HALT` reached with no status write — which is every failure
`HALT`, at no cost to the failure paths — fails the run, as does never reaching a `HALT` (the
`G_TIMEOUT` watchdog in `tb_cpu.vhd`). `make check` / `make test` additionally diff **two** golden
files per program: the run's register/memory write log against `test/<name>.writes.golden`, and
its statistics against `test/<name>.stats.golden`. Every one of these targets exits 0 if and only
if the test passed. See [test/README.md](test/README.md); if a golden diff is *expected*,
regenerate both with `make golden` and read the `git diff` carefully.

The statistics file is the performance counterpart of the writes log, and exists because a change
that makes the CPU flush twice as often produces an identical writes log and passes CI green.
`test_monitor.vhd` counts cycles (reset release to the retiring `HALT`), accepted beats on each
Wishbone bus (`cyc and stb and not stall`), and cycles in which *both* buses accepted a beat. That
last one measures the Harvard split directly: for `prog.asm`, 1822 of 1848 data requests coincide
with an instruction fetch, so serialising them onto one port would cost at least +11.5% of the run.
Note the instruction count includes speculative fetches that a flush later discarded, which is part
of why it is worth watching.

Retiring a `HALT` now stops the CPU. `p_halt_fetched` in `src/cpu.vhd` gates the
Icache-to-DECODE handshake off as soon as a `HALT` is handed to DECODE (gating on the `halt_o`
retire pulse from WRITE would be one or two instructions too late), and clears that gate on a
pipeline flush, since a branch retiring can discard an already-accepted `HALT` —
`test/prog_pipeline.asm` branches over twelve `HALT`s used as padding and depends on this.

### Formal verification

`make formal` runs `make -C formal`, which uses SymbiYosys (`sby`) with the GHDL plugin to
check the modules listed in the `DUTS` variable at the top of
[formal/Makefile](formal/Makefile). CI runs it too, in its own workflow
[.github/workflows/formal.yml](.github/workflows/formal.yml), taking the whole toolchain from a
pinned OSS CAD Suite release and using `make -C formal -k` so one failing DUT does not hide the
rest. All twelve DUTs are currently enabled and **the whole suite
passes** (35 tasks); if you want to narrow scope while iterating, comment lines out there — but
put them back. The Makefile tracks each job with a `<dut>.stamp` file whose prerequisites are read
from that job's own `[files]` section, so `make` re-runs exactly the jobs whose `.sby`, `.psl` or
VHDL sources changed, and nothing otherwise. A stamp exists only if that job's last run passed
(the recipe deletes it before invoking `sby`), so a failure is always retried. Note `make` still
stops at the first failing job — pass `-k` to attempt the whole suite. To run/inspect a single
module directly:

```
cd formal
sby --yosys "yosys -m ghdl" -f memory.sby          # e.g. run just the memory module
gtkwave memory_bmc/engine_0/trace.vcd memory.gtkw  # inspect a failing counterexample trace
```

Each module has a matching `<name>.psl` (PSL assertions/assumptions, usually embedded as VHDL
comments inside or alongside the `.vhd` file), a `<name>.sby` (SymbiYosys job config: bmc/cover
tasks, file list, top-level generics), and a `<name>.gtkw` (GTKWave save file for viewing
counterexamples). When adding formal properties to a new module, follow this same
`.psl` + `.sby` + `.gtkw` triplet pattern next to the existing ones in `formal/`.

## Architecture

Four-stage pipeline: **FETCH → DECODE → PREPARE → WRITE**, plus two shared modules, **Registers**
(2 read ports from DECODE, 1 write port from WRITE) and **Memory** (2 read ports from PREPARE, 1
write port from WRITE, backed by a Wishbone bus). DECODE, PREPARE, and WRITE are combined into a
single VHDL entity `cpu_main` (in `src/cpu_main/cpu_main.vhd`) mainly to simplify formal
verification of the interactions between them.

Stage-to-stage handshaking uses an AXI-style `VALID`/`READY` protocol throughout (also on the
Wishbone bus, via `stall`/`ack`). Two independent sources of back-pressure exist: an
instruction may expand into up to three micro-ops, and the Sequencer in PREPARE issues one per
cycle while holding its ready low, which stalls DECODE and in turn FETCH; and the Memory module
stalls PREPARE while waiting on the Wishbone bus.

Instruction and data memory are separate interfaces (Harvard-style) but backed by the same
physical dual-port RAM, since a program must be loadable and then executable from the same memory.
The working Program Counter (`R15`) lives inside FETCH. The register file *does* have an `R15`
slot in its upper bank and WRITE writes it whenever an instruction targets `R15` (i.e. on
branches), but it is stale during sequential execution, so PREPARE substitutes the real PC for
either operand whenever `R15` is read, in any addressing mode (`src_val_pc`/`dst_val_pc` in
`prepare.vhd`; see [src/cpu_main/README.md](src/cpu_main/README.md#Reading-R15)). Reading that
stale slot directly was a real bug, fixed by that substitution;
`R14` (Status Register) is handled specially in the register file (written alongside any regular
register write at the end of most instructions); `R13` (Stack Pointer) is an ordinary register,
handled in DECODE.

The upper eight bits of `R14` select which of the 256 pages of `R0`-`R7` the register file
presents, and **changing them flushes the pipeline** — `is_crb` in `src/cpu_main/write.vhd`, plus
the `reg_addr_o` term next to it, join `fetch_valid_o` and redirect FETCH to the next instruction.
This is not an optimisation choice: DECODE issues a register read two stages ahead of WRITE, so the
instruction after an `INCRB` has already read the old bank by the time the new one lands, and
forwarding the bank into the read address cannot fix it (the address reaches the RAM a cycle before
the new bank exists). The trigger is deliberately **syntactic** — "writes `R14`, or is
`INCRB`/`DECRB`" — and NOT a comparison of the new bank against the old: the precise form is more
selective but costs the entire timing margin, since `fetch_valid_o` is the reset pin of every
flip-flop in DECODE and PREPARE. So `MOVE ST____C_, R14` does cost a branch penalty. Do not
"optimise" this without reading the measured numbers in the comment above `is_crb`.
`test/prog_hazard.asm` `H11`-`H13` pin the behaviour down (before the flush existed, `INCRB` /
`ADD 0, R0` silently copied one bank's `R0` into the next bank's), and `f_flush_on_bank_change` in
`formal/cpu_main.psl` states what the syntactic over-approximation has to cover: whenever the bank
bits actually change, `fetch_valid_o` must assert. See
[src/cpu_main/README.md](src/cpu_main/README.md#Register-bank-switch).

### Microcode / instruction decomposition

The core trick of this design: DECODE dynamically translates each CISC-like QNICE instruction into
1-3 RISC-like micro-operations via a combinational ROM (`src/cpu_main/sub/microcode.vhd`), indexed
by a 4-bit classification of the instruction (reads-from-dst / writes-to-dst / src-in-memory /
dst-in-memory). DECODE emits that whole list in a single beat; the `Sequencer`
(`src/cpu_main/sub/sequencer.vhd`), which lives in **PREPARE**, then issues it one micro-op per
clock cycle. This exists because an instruction like `ADD @R0, @R1` needs two
memory reads and one memory write, but only one memory operation is possible per cycle — the
micro-ops serialize that. Each micro-op is a 12-bit word (`LAST`, `REG_MOD_SRC`, `REG_MOD_DST`,
`MEM_WAIT_SRC`, `MEM_WAIT_DST`, `REG_WRITE`, `MEM_READ_SRC`, `MEM_READ_DST`, `MEM_WRITE`); the
three register-op bits are mutually exclusive, as are the three memory-op bits. Immediate operands
(`@R15++`) are special-cased to skip a memory read since FETCH already supplies the value inline.
See [src/cpu_main/README.md](src/cpu_main/README.md#Microcoding-of-instructions) for the full
worked examples (`MOVE R0,R1`, `MOVE @R0,@R1`, `ADD @R0,@R1`).

Data hazards from this pipelining (later WRITE-stage register writes vs. earlier DECODE-stage
register reads) are handled via bypass logic described in
[src/cpu_main/README.md](src/cpu_main/README.md#Bypass), and via write-before-read semantics
built into the Registers module itself (see
[src/registers/README.md](src/registers/README.md#Operation)). Write-before-read applies to both
`R14` write ports: the ordinary one and the dedicated SR port (`wr_sr_en_i`), the latter forwarded
by `src_val_o`/`dst_val_o` as well. `test/prog_hazard.asm` exercises these paths directly.

That write-before-read/bypass forwarding is also the thing to remember when writing PSL for
`registers.vhd`: a property that predicts a forwarded `src_val_o`/`dst_val_o`/`sr_val_o` value one
cycle out is only true if no *other* write to the same register lands on that exact checked cycle
— such a write legitimately overrides the prediction via the same combinational bypass, and BMC
will find that as a "failing" counterexample that isn't actually a bug. Every forwarding property
in [formal/registers.psl](formal/registers.psl) carries an explicit escape clause for this reason.
Separately, `sr_val_o`'s combinational mux previously didn't give `rst_i` the same top priority
that `reg_sr`'s register process (`p_sr`) does, so a write coinciding with reset could briefly leak
onto `sr_val_o` before `reg_sr` caught up next edge — fixed by making `rst_i` the first term in
that mux (see [src/registers/README.md](src/registers/README.md#Formal-verification)).

### Self-modifying code

Instruction and data memory are the same physical RAM, so a store can land on an
instruction that FETCH/Icache/DECODE/PREPARE has already read. `smc_hit` in
`src/cpu_main/write.vhd` detects a store within 32 words after the current instruction
and joins `fetch_valid_o`, flushing exactly as a taken branch does. Two constraints shape
that code and are easy to undo by accident: the flush net is the reset pin of every
flip-flop in DECODE and PREPARE, so the comparison must subtract **raw stage registers**
(the exact `mem_req_addr_o - next_pc` form misses timing at −0.042 ns), and it must stay a
*window* rather than "every store" (unconditional flushing costs +8.5% on `prog.asm`,
+64% on `prog_interleave.asm`). Over-approximating the window is always safe — a spurious
flush costs cycles, not correctness. `test/prog_self_modifying.asm` covers both edges;
see [doc/README.md](doc/README.md#Self-modifying-code).

### FETCH redirect (branch penalty)

A redirect (`fetch.dc_valid_i`, i.e. `cpu_main`'s `fetch_valid_o`) does **not** terminate the
Wishbone cycle. `CYC` stays asserted and the first request of the new instruction stream goes out on
the next clock cycle; tearing the bus cycle down instead costs an extra cycle before `STB` can be
reasserted, and that cycle lands on the critical path of every taken branch. Worth **−4.7%** on
`prog.asm` and up to −9.1% on branch-dense programs, one cycle per redirect.

Two things are load-bearing and easy to undo. The redirect step in `p_wishbone` must run **before**
the issue step (it used to run after and override it) — that ordering *is* the optimisation. And the
issue budget must count `wb_stale` alongside the allocated slots, or a redirect can push the number
of unacknowledged requests past `C_MAX_PENDING`.

Because the requests abandoned by a redirect are no longer cancelled by dropping `CYC`, they still
owe acknowledgements; `wb_stale` counts them and `wb_rsp_accept` is gated to discard them. That
replaces interface contract (c) with a new contract (d): **the slave must acknowledge in order**
(the Memory module already assumes this). The old teardown remains for the one case that cannot be
redirected — a request stuck on `STB` while the slave stalls, which cannot happen against the
dual-port RAM here. See [src/fetch/README.md](src/fetch/README.md#Redirect).

When touching `fetch.psl`, note that `f_wb_outstanding` is cleared on the design's *cancel*
condition, not on `dc_valid_i`. Reverting that one line is silent: `f_wb_slave_ack_idle` then
forbids the stale acknowledgements entirely, so the discard logic goes unexercised and every
assertion still passes. `f_cover_abort_redirect` and `f_cover_stale_ack` are what catch it.

### Elastic pipeline building blocks (`src/sub/`)

Six small, reusable valid/ready ("AXI-style") primitives that the rest of the design (FETCH,
Registers, Memory, `cpu_main`) is built from. All are formally verified (`formal/<name>.{psl,sby}`)
— **run `sby -f <name>.sby` after touching any of these**; several of the properties below only
hold because of non-obvious interactions that BMC/induction catches but casual reading won't.

| Module | Depth | Forward path (valid+data) | Backward path (ready) | Notes |
|---|---|---|---|---|
| `one_stage_buffer.vhd` | 1 | combinational when empty | combinational | zero-latency cut-through both ways |
| `one_stage_fifo.vhd` | 1 | **registered** (always ≥1 cycle) | combinational | only `ready` cuts through |
| `two_stage_buffer.vhd` | 2 | combinational when empty | combinational | 2× chained `one_stage_buffer` |
| `two_stage_fifo.vhd` | 2 | registered | combinational, gated by `rst_i` | hand-built, not chained |
| `dp_ram.vhd` | — | registered, 1-cycle, gated by `rd_en_i` | n/a | read-first on same-address collision |
| `pipe_concat.vhd` | 0 | fully combinational | fully combinational | pure join, no storage, `clk_i`/`rst_i` unused |

Subtleties worth knowing before reusing or modifying any of these:

- **`one_stage_buffer` / `two_stage_buffer` are combinational in *both* directions when empty** —
  valid+data ripple forward, ready ripples backward, in the same cycle. Chaining N of them creates
  an O(N) combinational path each way; budget this against Fmax. `one_stage_fifo` / `two_stage_fifo`
  avoid this by registering the forward path, at the cost of a guaranteed cycle of latency.
- **`s_afull_o` (on `one_stage_buffer`) is raw occupancy, not "not ready."** `s_ready_o` can still be
  `'1'` while `s_afull_o='1'` if downstream drains in the same cycle. Gate acceptance on `s_ready_o`,
  never on `s_afull_o`.
- **`m_valid_o` on `one_stage_buffer`/`two_stage_buffer` is gated combinationally by `rst_i`**
  (`(m_valid_r or s_valid_i) and not rst_i`), so asserting reset clears it *within the same cycle*,
  not just on the next clock edge. Any PSL property (or downstream logic) reasoning about "stability
  until accepted" must account for this — a missing `abort rst_i`/`rst_i='1' or ...` escape here is
  exactly the kind of bug that silently breaks k-induction (this has happened before; see git
  history on `formal/two_stage_buffer.psl`).
- **`two_stage_fifo`'s reset is asymmetric by design**, because it doubles as a mid-stream pipeline
  flush (callers like FETCH OR it with the global reset): `s_ready_o` IS gated by `rst_i` (no input
  can be accepted during a flush), but `m_valid_o` is deliberately NOT gated by `rst_i` (an output
  handshake can still complete on the same cycle a flush is asserted). This means **the consumer
  must share the same `rst_i`**, or it will silently accept a word the flush is discarding upstream.
- **`dp_ram` read/write collision is read-first**: a read and write to the same address in the same
  cycle returns the *old* value; the new value is visible from the next read. `G_RAM_STYLE="block"`
  adds a falling-edge staging register to ease BRAM timing (requires a reasonably balanced clock
  duty cycle) — `"distributed"` is a plain single rising-edge read register. Memory contents are
  never reset by `rst_i` (unused, kept only for interface uniformity).
- **`pipe_concat` has `clk_i`/`rst_i` ports that do nothing** — it's stateless combinational logic;
  the ports exist only so it fits the same instantiation convention and formal-env uniformity as
  everything else.
- All six modules require the standard valid/ready contract from upstream: once `s_valid_i='1'` and
  `s_ready_o='0'`, both `s_valid_i` and `s_data_i` must hold stable until accepted. Several files
  check this in simulation only (`pragma translate_off`/`on`), not in synthesis.

### Memory module (`src/memory/memory.vhd`)

Multiplexes one request channel (from WRITE) and two read-response channels (SRC/DST, back to
PREPARE) onto a single Wishbone Master interface. Full design writeup, including the back-pressure
argument and the formal property list, is in [src/memory/README.md](src/memory/README.md); the
key thing worth knowing up front:

**Wishbone ACKs carry no identifying information** — a bare pulse, not tagged with which request
or what type. This module recovers that itself via `i_two_stage_fifo_mem`, a depth-2 FIFO that
records each accepted-but-unacked request's op-type in issue order; each `wb_ack_i` is matched to
the *oldest* outstanding request (the FIFO's head) and that entry is popped to decide whether to
route `wb_data_i` to the SRC buffer, the DST buffer, or nowhere (a WRITE ack). This is correct, but
depends entirely on the Wishbone slave acking in issue order (stated in the module's header) — safe
here since `wbd_*` (see `cpu.vhd`) connects to a single, non-reordering physical memory, but would
silently misattribute data against a slave that completed requests out of order.

Formal status (`formal/memory.psl`): `bmc`/`cover` (depth 10) pass. K-induction (`prove`, not
currently in `formal/memory.sby`'s task list) is **partially closed**: the three buffer/FIFO
overflow-safety properties that blocked the original attempt now prove inductively, via a
self-correcting shadow register that mirrors the type-tracking FIFO's internal transition rules
(needed because GHDL's synth-for-formal flow can't read a sub-instance's internal registers
directly — confirmed by testing external names). One property, `f_wb_master_request` (≤2
outstanding Wishbone requests), remains open under induction — true up to the checked BMC depth,
with the specific remaining obstacle documented in a comment right above it in `memory.psl`.

### Utilization numbers

The "Utilization" section of [doc/README.md](doc/README.md) is generated, not hand-maintained:
`make utilization` runs two Vivado passes and `hw/update_utilization.py` rewrites the numbers.
Two passes are needed because the two tables measure different things on purpose — device totals
come from the shipping `-flatten_hierarchy rebuilt` build after place-and-route (reused from
`make system.bit`, since place-and-route is the expensive part), while the per-module table needs a
synthesis-only `-flatten_hierarchy none` pass, because "rebuilt" lets synthesis move logic across
module boundaries and reports the ALU inside PREPARE.

It also fills in the "The critical path" note there. That path has been the same in every build
measured: register-to-register inside PREPARE, between two fields of `wr_stage_o`, through the ALU
operand muxing. It is **routing-dominated** (about two thirds interconnect), which has a practical
consequence — logic nowhere near it can still move the slack by perturbing placement. A single
flip-flop added next to the Icache for the HALT gate once cost 0.284 ns, the whole margin, without
appearing on the path; re-measure after an unrelated edit rather than assuming it cannot matter.

The script rewrites **numbers only** — the surrounding analysis is a hand-written design argument.
Every substitution is anchored on an exact pattern and a missing anchor is a hard error, so
rewording one of those sentences breaks `make utilization` loudly rather than silently leaving a
stale figure behind. **This cannot run in CI**: Vivado is a 38 GB licensed install and
GitHub-hosted runners cannot host it, so the numbers are refreshed deliberately, on a machine that
has Vivado.

### Directory layout

- `src/cpu_constants.vhd` — shared constants/types used across modules.
- `src/fetch/` — instruction fetch + instruction cache.
- `src/registers/` — register file (dual-port RAM based, write-before-read).
- `src/memory/` — Wishbone-facing memory arbiter (source/destination operand buffers).
- `src/cpu_main/` — DECODE, PREPARE, WRITE, and the `sub/` microcode ROM, sequencer, ALU.
- `src/sub/` — reusable elastic-pipeline building blocks, see
  [Elastic pipeline building blocks](#Elastic-pipeline-building-blocks-src-sub) above.
- `src/cpu.vhd` — top-level entity tying FETCH, Icache, Registers, Memory, and `cpu_main` together.
- `test/` — testbench (`tb_cpu.vhd`), memory models, the pass/fail monitor (`test_monitor.vhd`),
  and `.asm` test programs. See [test/README.md](test/README.md) for how to tell a passing run
  from a failing one. One of them, `test/prog_waveform.asm`, is not really a test: it
  is the program the pipeline timing diagram in
  [src/cpu_main/README.md](src/cpu_main/README.md#Waveforms) was read off, and it is in `TESTS`
  only so that a change invalidating the diagram's quoted addresses and cycle counts fails the
  writes-log diff. The diagram itself is hand-written in `src/cpu_main/timing.tex` and rendered
  by `make timing`; nothing derives it from the simulation automatically.
- `hw/` — Vivado XDC constraints / synthesis TCL (generated).
- `formal/` — one `.psl`/`.sby`/`.gtkw` triplet per formally-verified module.
- `doc/` — architecture overview and block diagram source (`cpu.drawio`/`cpu.png`).
