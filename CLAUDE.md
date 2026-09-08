# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

Test programs live in `test/*.asm` and are assembled with the external QNICE assembler at
`$HOME/git/sy2002/QNICE-FPGA/assembler/asm`, which must be checked out separately — **on the
`develop` branch**. That is the branch this repo follows, for the ISA as well as the tools, and it
is not that repository's default; the CI workflow pins it with a `ref:` for the same reason. The
path above is the top-level `Makefile`'s `ASSEMBLER ?=`, so it can be overridden —
`make test ASSEMBLER=<path>` is what
[.github/workflows/test.yml](.github/workflows/test.yml) does. That workflow runs
`make test` on every push to `main` and every pull request (formal verification and linting run in
their own workflows, see below); it builds only `qasm`/`qasm2rom` from
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
arithmetic is checked in-band instead; see below. Every one of these targets exits 0 if and only
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

`make lint` runs [VSG](https://vhdl-style-guide.readthedocs.io/) (VHDL Style Guide) over all 28
VHDL files with the repo's `vsg.yml`, which maps CODING_STYLE.md onto VSG's rule set. CI runs it
too, in its own workflow [.github/workflows/lint.yml](.github/workflows/lint.yml), from a **pinned**
vsg release — the pin is load-bearing, because VSG adds and re-scopes rules between releases and
`vsg.yml` only overrides the defaults it knows about, so an unpinned bump can turn the job red
with no VHDL change at all.

**The tree is clean: zero errors.** What remains is 38 `length_001` warnings, which are the
100-column *target* of CODING_STYLE.md section 3 advising rather than failing; warnings do not fail
the job. Every rule VSG applies here is now either stated in CODING_STYLE.md or deliberately
disabled in `vsg.yml` with the reason written next to it, so wanting to change a `vsg.yml` rule is
a sign CODING_STYLE.md has an unanswered question — answer it there first. Deliberate *local*
exceptions (an instruction-format table, an opcode matrix, an aligned boolean expression) use
VSG's own `-- vsg_off <rule>` / `-- vsg_on <rule>` markers at column 0, next to a comment saying
why; six files carry them. Most violations are machine-fixable with
`vsg -c vsg.yml --fix -f <files>`, but read the diff: `--fix` will happily reformat a deliberate
table.

### Formal verification

`make formal` runs `make -C formal`, which uses SymbiYosys (`sby`) with the GHDL plugin to
check the modules listed in the `DUTS` variable at the top of
[formal/Makefile](formal/Makefile). CI runs it too, in its own workflow
[.github/workflows/formal.yml](.github/workflows/formal.yml), taking the whole toolchain from a
pinned OSS CAD Suite release and using `make -C formal -k` so one failing DUT does not hide the
rest. All thirteen DUTs are currently enabled and **the whole suite
passes** (39 tasks); if you want to narrow scope while iterating, comment lines out there — but
put them back. Twelve of the DUTs are CPU modules under `src/`; `wb_mux` is the exception, a
testbench component under `test/`, verified because the CPU's correctness depends on it keeping
responses in order. The Makefile tracks each job with a `<dut>.stamp` file whose prerequisites are read
from that job's own `[files]` section, so `make` re-runs exactly the jobs whose `.sby`, `.psl`, or
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

### Yosys synthesis

`make synth` runs `ghdl -a` over every source file and then `yosys -m ghdl` with `synth_xilinx`. It
is a second opinion on synthesisability, not a build — nothing consumes `cpu.edif` — and it is not
in CI.

**It elaborates `cpu`, not `system`, and that is forced rather than chosen.** `system` instantiates
`test/wb_dp_mem.vhd`, whose `dp_ram` runs at `G_RAM_STYLE = "block"` and therefore reads port A on
the **falling** clock edge. That is the deliberate timing trick documented in `src/sub/dp_ram.vhd`
and in [Elastic pipeline building blocks](#elastic-pipeline-building-blocks-srcsub) above; Vivado
implements it happily. Yosys cannot: every port in its Xilinx BRAM library
(`share/yosys/xilinx/brams_*.txt`) is declared `clock posedge`, so a negedge read port has no
mapping at all and the run dies on `no valid mapping found for memory ... dp_ram_r`. Expressing the
same edge as a rising edge on an explicitly inverted clock net does **not** work — yosys folds
`posedge !clk` straight back into `negedge clk`. The alternatives were giving up the falling-edge
register, which costs Vivado timing, or letting an 8 kW array map to logic, so the scope was
narrowed instead.

Little is lost by that. Everything under `src/` is still synthesised, including both `dp_ram`
configurations the CPU itself uses (`distributed`); what drops out is testbench-only — the memory
model, `wb_mux`, `test_monitor`, and `system.vhd` — and Vivado synthesises all of that for real in
`make system.bit`. The `ghdl -a` step still covers every file, so a syntax or semantic error
anywhere still fails the target.

This broke in `1617539`, which coalesced `test/dp_mem.vhd` into `src/sub/dp_ram.vhd`: the old
testbench model read both ports on the rising edge, so the negedge port arrived in `system` for the
first time with that merge. `git bisect run` on `make synth` finds it in about eight steps —
the target takes under four seconds.

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

The upper eight bits of `R14` select which of the 256 pages of `R0`-`R7` the register file
presents, and **changing them costs a pipeline flush unless nothing already in flight would read
the old bank**. DECODE issues a register read two stages ahead of WRITE, so the instruction after
an `INCRB` has already read the old bank by the time the new one lands, and forwarding the bank
into the read address cannot fix it (the address reaches the RAM a cycle before the new bank
exists). Exactly two instructions can be affected — the one in DECODE's output register and the one
at its input — and only if they *consume* a banked value: WRITING `R0`-`R7` is safe, because the
write carries a register number down the pipeline and lands in whatever bank is current when it
retires, which is the new one. So `uses_bank` in `src/cpu_main/decode.vhd` classifies each
instruction, `bank_switch_o`/`bank_stale_i` carry the two bits between WRITE and DECODE, and an
`INCRB`/`DECRB` flushes only when the instruction in DECODE's output register reads a banked
register, holds DECODE for one cycle when the one at its input does, and costs nothing otherwise —
which is the case for the standard `INCRB` / `MOVE R8, R0` prologue and `DECRB` /
`MOVE @R13++, R15` epilogue. All ten bank switches in `prog.asm` are now free (15070 → 15030
cycles, i.e. a 4-cycle branch penalty apiece). One detail is load-bearing for TIMING rather than
function: `is_crb` is decoded in DECODE and carried in the stage records, not re-derived from
`prep_stage_i.inst` in WRITE. Deriving it there puts a ten-bit compare in front of `fetch_valid_o`
and the design **does not build** (WNS −0.036 ns at 7.25 ns, 4 failing endpoints); with the
precomputed bit it closes at +0.093 ns.

An ordinary write to `R14` still flushes **unconditionally**, and its trigger is deliberately
**syntactic** — "writes `R14`, or writes `R15`", collapsed into a single product term because the
two share `reg_addr_o(3 downto 1)` — and NOT a comparison of the new bank against the old: the
precise form is more selective but costs the entire timing margin, since `fetch_valid_o` is the
reset pin of every flip-flop in DECODE and PREPARE. So `MOVE ST____C_, R14` does cost a branch
penalty. Do not "optimise" either half of this without reading the measured numbers in the "Register bank
switch" comment in `write.vhd`.
`test/prog_hazard.asm` `H11`-`H17` pin the behaviour down (before the flush existed, `INCRB` /
`ADD 0, R0` silently copied one bank's `R0` into the next bank's; `H14`-`H15` are the write-only
case that must NOT flush), and `f_flush_on_bank_change` / `f_hold_on_bank_change` in
`formal/cpu_main.psl` state what `uses_bank` has to cover: whenever the bank bits actually change,
an in-flight instruction that consumes a banked value must be flushed or refused. Both derive
"consumes a banked value" from the raw instruction encoding rather than from `uses_bank`, so
narrowing `uses_bank` fails them. See
[src/cpu_main/README.md](src/cpu_main/README.md#register-bank-switch).

### Microcode / instruction decomposition

The core trick of this design: DECODE dynamically translates each CISC-like QNICE instruction into
1-3 RISC-like micro-operations via a combinational ROM (`src/cpu_main/sub/microcode.vhd`), indexed
by a 4-bit classification of the instruction (reads-from-dst / writes-to-dst / src-in-memory /
dst-in-memory). DECODE emits that whole list in a single beat; SEQUENCER
(`src/cpu_main/sequencer.vhd`), instantiated by CPU_MAIN **between DECODE and PREPARE**, then
issues it one micro-op per clock cycle. This exists because an instruction like `ADD @R0, @R1`
needs two memory reads and one memory write, but only one memory operation is possible per cycle —
the micro-ops serialize that. Each micro-op is a 12-bit word (`LAST`, `REG_MOD_SRC`, `REG_MOD_DST`,
`MEM_WAIT_SRC`, `MEM_WAIT_DST`, `REG_WRITE`, `MEM_READ_SRC`, `MEM_READ_DST`, `MEM_WRITE`); the
three register-op bits are mutually exclusive, as are the three memory-op bits. Immediate operands
(`@R15++`) are special-cased to skip a memory read since FETCH already supplies the value inline.
**`alu_data.vhd`'s four `null` arms are not dead code.** `CMP` and `CTRL` genuinely are don't-cares
(their microcode writes nothing), but `JMP` is **load-bearing**: DECODE rewrites a JMP's microcode
to carry `REG_WRITE` with `res_reg = R15`, so the branch target reaches the PC through
`res_other`'s `"0" & src_data_i` default. Give that arm a value of its own and every branch in the
CPU breaks — verified by forcing it, which makes the suite stop reaching `HALT` at all. The fourth,
reserved opcode `0xD`, is classified like `ADD` and so writes the source over the destination; that
is unsanctioned fall-through, which is why `p_unimplemented` traps it. See
[src/cpu_main/README.md](src/cpu_main/README.md#microcoding-of-instructions) for the full worked
examples (`MOVE R0,R1`, `MOVE @R0,@R1`, `ADD @R0,@R1`).

Data hazards from this pipelining (later WRITE-stage register writes vs. earlier DECODE-stage
register reads) are handled via bypass logic described in
[src/cpu_main/README.md](src/cpu_main/README.md#bypass), and via write-before-read semantics
built into REGISTERS itself (see [src/registers/README.md](src/registers/README.md#operation)).
Write-before-read applies to both `R14` write ports: the ordinary one and the dedicated SR port
(`wr_sr_en_i`), the latter forwarded by `src_val_o`/`dst_val_o` as well. `test/prog_hazard.asm`
exercises these paths directly.

That write-before-read/bypass forwarding is also the thing to remember when writing PSL for
`registers.vhd`: a property that predicts a forwarded `src_val_o`/`dst_val_o`/`sr_val_o` value one
cycle out is only true if no *other* write to the same register lands on that exact checked cycle
— such a write legitimately overrides the prediction via the same combinational bypass, and BMC
will find that as a "failing" counterexample that isn't actually a bug. Every forwarding property
in [formal/registers.psl](formal/registers.psl) carries an explicit escape clause for this reason.
Separately, `sr_val_o`'s combinational mux previously didn't give `rst_i` the same top priority
that `reg_sr`'s register process (`p_sr`) does, so a write coinciding with reset could briefly leak
onto `sr_val_o` before `reg_sr` caught up next edge — fixed by making `rst_i` the first term in
that mux (see [src/registers/README.md](src/registers/README.md#formal-verification)).

### Self-modifying code

Instruction and data memory are the same physical RAM, so a store can land on an
instruction that FETCH/ICACHE/DECODE/PREPARE has already read. `smc_hit` in
`src/cpu_main/write.vhd` detects a store within 32 words after the current instruction
and joins `fetch_valid_o`, flushing exactly as a taken branch does. Two constraints shape
that code and are easy to undo by accident: the flush net is the reset pin of every
flip-flop in DECODE and PREPARE, so the comparison must subtract **raw stage registers**
(the exact `mem_req_addr_o - next_pc` form misses timing at −0.042 ns), and it must stay a
*window* rather than "every store" (unconditional flushing costs +8.5% on `prog.asm`,
+64% on `prog_interleave.asm`). Over-approximating the window is always safe — a spurious
flush costs cycles, not correctness. `test/prog_self_modifying.asm` covers both edges;
see [doc/README.md](doc/README.md#self-modifying-code).

`smc_hit` is qualified by `inst_done_o`, which is correct for every store in the microcode
ROM — they all sit on the micro-op carrying `C_LAST` — and misses the **one** that does
not: the return address `ASUB`/`RSUB` pushes, which `decode.vhd` writes by hand onto the
instruction's *first* micro-op. `smc_push` is the second term that covers it, and its
shape is not interchangeable with the first. The flush must be **deferred to the last
micro-op** (a flush mid-sequence resets SEQUENCER and discards the rest of the branch,
falling through to `next_pc`); it applies **only when `early_jmp` suppressed WRITE's own
redirect**, since otherwise the `R15` write flushes anyway and FETCH refills from the
target after the push has landed; and its window is measured from the **target**
(`prep_stage_i.immediate`) and is **8, not 32**. That last number is load-bearing in the
opposite direction from the one above: a stack placed just past the end of the program is
normal, so a loose window here is not free — 16 costs `prog_mandel_perf` 4.7% and the
ordinary 32-word window costs `prog_subroutine` 8%, most of the early redirect's gain.
The bound is derived and measured in the comment above `smc_push`; `T8` in
`test/prog_self_modifying.asm` and `f_flush_on_smc_push` in `formal/cpu_main.psl` pin it.

Separately, `mem_req_op_o`'s **write** bit is ANDed with `update_reg`, the branch-taken
term that also gates `p_reg`'s register writes. Without it a conditional `ASUB`/`RSUB`
that was *not* taken still wrote its return address to `SP-1` — `SP` itself was correctly
untouched, so nothing in the suite noticed and the stray writes simply sat in
`test/prog.writes.golden`. The two **read** bits must stay ungated: a not-taken
`ASUB @R0, Z` still reaches its last micro-op, which carries `C_MEM_WAIT_SRC` and would
wait forever for a read that was never issued. `f_no_push_when_not_taken` in
`formal/cpu_main.psl` and the sentinel in `prog.asm`'s `L_COND_ASUB_00` are the tripwires.

### Early redirect (unconditional branches)

A branch normally costs **four cycles**: one to register the new PC in FETCH, one for the
instruction memory's read latency, one in ICACHE, and one because DECODE and PREPARE are then
empty. Measured on `prog.asm` before the early redirect below, the 731 redirects cost 3625 cycles
of a then-15030-cycle run — **24%**.

`ABRA`/`ASUB`/`RBRA`/`RSUB <label>, 1` escapes most of that, because DECODE can resolve it without
help: the condition selects `SR` bit 0, which reads as 1 always, and the target is the immediate
word FETCH already delivered alongside the instruction (`decode.vhd` even computes the absolute
address for the relative modes, for `seq_stage_o.immediate`). So `early_jmp` in
`src/cpu_main/decode.vhd` drives `early_valid_o`/`early_addr_o` on the cycle DECODE accepts the
instruction, two cycles before WRITE would have; `cpu.vhd` merges that with WRITE's redirect into
the single port `fetch.vhd` sees. **Four cycles becomes two, and one for `ASUB`/`RSUB`**, whose
second micro-op overlaps another cycle of the refill. **It costs 0.091 ns of the 0.093 ns of margin
there was** (WNS +0.093 → +0.002 ns): it closes, the cycles are free at the shipping frequency, and
there is now essentially nothing left for the next change. The critical path is unmoved — inside
PREPARE, through the ALU operand muxing, which this does not touch — so re-measure rather than
assume any particular edit is what moved it.

Three things are load-bearing:

* **The early redirect flushes FETCH and ICACHE only** — never DECODE or PREPARE. By the end of the
  cycle the branch is in DECODE's output register and everything downstream is *older*, so those
  two are the only place wrong-path instructions live. Hence `ic_rst` (from WRITE) and `ic_flush`
  (from DECODE) are separate signals in `cpu.vhd`.
* **The ICACHE flush must be soft.** `icache.vhd`'s `rst_i` gates `m_valid_o` combinationally, which
  is mandatory for WRITE's flush and fatal here: DECODE raises the flush *because* it is accepting
  the branch being offered this cycle, so gating `m_valid_o` withdraws the handshake the flush is
  derived from and the loop settles on "no branch accepted, no flush" — silently inert. `flush_i`
  therefore clears the buffer at the edge and gates `s_ready_o` but leaves `m_valid_o` alone, the
  same asymmetry `two_stage_fifo` documents in its contract (b). `f_flush_offers` and
  `f_cover_flush_handshake` in `formal/icache.psl` are the tripwires.
* **WRITE must not redirect again**, or it discards what the early redirect went to fetch.
  `prep_stage_i.early_jmp` carries that in the stage records beside `is_crb` and `is_sub`. Its `rst_i` companion term in
  `write.vhd` is not decoration: `p_reg` forces the `R15 = 0` write that gives FETCH its initial PC
  during reset, and PREPARE's output register is *not* cleared by reset, so a stale `early_jmp`
  would suppress it.

`test/prog_subroutine.asm` exists because the rest of the suite is unrepresentative here: only 73
of `prog.asm`'s 731 redirects are of this form (−1.0%), whereas the QNICE-FPGA monitor sources are
62% unconditional-immediate branches (328 `RSUB x, 1`, 182 `RBRA x, 1` against 308 conditional
`RBRA`). That benchmark falls 678 → 580 cycles, **−14.5%**.

Two things were measured and rejected, both defeated by the same fact — `dp_ram`'s block-RAM read
stages through a **falling-edge** register, so a RAM address path gets **half a clock period**.
Removing FETCH's `wbi_addr_o` register — the one-cycle gap between `WRITE/fetch_addr_o` and
`FETCH/wb_addr_o` in the loop timing diagram — concatenates a 7.002 ns leg (PREPARE to that
register) with a 2.698 ns one (that register to the RAM), i.e. ~9.7 ns plus a mux into a 3.625 ns
budget; it does not fit in a full 7.25 ns period either, and it would buy one cycle per redirect,
5.4% of the suite. Making ICACHE cut-through merges a 4.373 ns path with a 2.558 ns (also
half-cycle) and a 6.565 ns one. Details and numbers in doc/README.md's Optimizations section — read
them before trying either again. **The lever that works on a branch penalty is making the redirect
DECISION arrive earlier, not moving the register**, which is what the early redirect above does.

### FETCH redirect (branch penalty)

A redirect (`fetch.wr_valid_i`, i.e. CPU_MAIN's `fetch_valid_o`) does **not** terminate the
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
(MEMORY already assumes this). The old teardown remains for the one case that cannot be redirected
— a request stuck on `STB` while the slave stalls, which cannot happen against the dual-port RAM
here. See [src/fetch/README.md](src/fetch/README.md#redirect).

When touching `fetch.psl`, note that `f_wb_outstanding` is cleared on the design's *cancel*
condition, not on `wr_valid_i`. Reverting that one line is silent: `f_wb_slave_ack_idle` then
forbids the stale acknowledgements entirely, so the discard logic goes unexercised and every
assertion still passes. `f_cover_abort_redirect` and `f_cover_stale_ack` are what catch it.

### Elastic pipeline building blocks (`src/sub/`)

Six small, reusable valid/ready ("AXI-style") primitives that the rest of the design (FETCH,
REGISTERS, MEMORY, CPU_MAIN) is built from. All are formally verified (`formal/<name>.{psl,sby}`)
— **run `sby -f <name>.sby` after touching any of these**; several of the properties below only
hold because of non-obvious interactions that BMC/induction catches but casual reading won't.

| Module | Depth | Forward path (valid+data) | Backward path (ready) | Notes |
|---|---|---|---|---|
| `one_stage_buffer.vhd` | 1 | combinational when empty | combinational | zero-latency cut-through both ways |
| `one_stage_fifo.vhd` | 1 | **registered** (always ≥1 cycle) | combinational | only `ready` cuts through |
| `two_stage_buffer.vhd` | 2 | combinational when empty | combinational | 2× chained `one_stage_buffer` |
| `two_stage_fifo.vhd` | 2 | registered | combinational, gated by `rst_i` | hand-built, not chained |
| `dp_ram.vhd` | — | registered, 1-cycle, gated by `*_rd_en_i` | n/a | port A reads, port B reads+writes; read-first on same-address collision |
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
- **`dp_ram` has two ports, each with one address**: port A reads, port B reads *and writes*, both
  at `b_addr_i`. It serves both the register file (reads on A, writes on B, `G_B_READ` false) and
  the testbench memory model (reads on both, writes on B, `G_B_READ` true). Only port B writes,
  because a second writer cannot be inferred — see "no shared variables" above.
  **One address per port is load-bearing**: giving the write an address of its own makes three
  independent addresses, which does not fit a two-port primitive, and Vivado duplicates the array
  (measured: 8 RAMB36 instead of 4 on the 8 kW memory). Tying two address ports to the same net at
  the instantiation does *not* rescue it, because `make utilization` synthesises with
  `-flatten_hierarchy none` and elaborates the module in isolation. `G_B_READ` exists for the same
  reason: a caller's `b_rd_en_i => '0'` is invisible in that pass, so the dead read port gets built
  and inflates the register file's row by 40 LUTs of phantom LUTRAM.
- **`dp_ram` read/write collision is read-first**: a read and write to the same address in the same
  cycle returns the *old* value; the new value is visible from the next read. `G_RAM_STYLE="block"`
  adds a falling-edge staging register per read port to ease BRAM timing (requires a reasonably
  balanced clock duty cycle) — `"distributed"` is a plain single rising-edge read register.
  `G_INIT_FILE` loads the array from a text file; memory contents are never reset by `rst_i`
  (unused, kept only for interface uniformity).
- **`pipe_concat` has `clk_i`/`rst_i` ports that do nothing** — it's stateless combinational logic;
  the ports exist only so it fits the same instantiation convention and formal-env uniformity as
  everything else.
- All six modules require the standard valid/ready contract from upstream: once `s_valid_i='1'` and
  `s_ready_o='0'`, both `s_valid_i` and `s_data_i` must hold stable until accepted. Several files
  check this in simulation only (`pragma translate_off`/`on`), not in synthesis.

### MEMORY module (`src/memory/memory.vhd`)

Multiplexes one request channel (from WRITE) and two read-response channels (SRC/DST, back to
PREPARE) onto a single Wishbone Master interface. Full design writeup, including the back-pressure
argument and the formal property list, is in [src/memory/README.md](src/memory/README.md); the
key thing worth knowing up front:

**Wishbone ACKs carry no identifying information** — a bare pulse, not tagged with which request
or what type. This module recovers that itself via `i_two_stage_fifo_mem`, a depth-2 FIFO that
records each accepted-but-unacked request's op-type in issue order; each `wb_ack_i` is matched to
the *oldest* outstanding request (the FIFO's head) and that entry is popped to decide whether to
route `wb_data_i` to the SRC buffer, the DST buffer, or nowhere (a WRITE ack). This is correct, but
depends entirely on the Wishbone slave acking in issue order (stated in the module's header), and
would silently misattribute data against one that completed requests out of order. In a bitstream
`wbd_*` still reaches a single memory, so that holds trivially; in simulation it does not, because
`test/system.vhd` splits the bus at `0x8000`, RAM below and the simulation-only EAE above. There the
requirement is met **structurally**, by `test/wb_mux.vhd`, which releases responses in issue order
whatever the slaves' latencies are. See
[The data bus multiplexer](#the-data-bus-multiplexer) below. It also requires
at least one cycle of ACK latency: a slave that acks in the cycle it accepts the request leaves the
FIFO's registered output with nothing to route by.

**`mreq_accept` reads registered state only** — the response buffers' `tsb_*_fill`, never
`msrc_valid_o`/`mdst_valid_o` (which cut through combinationally from `wb_ack_i`) and never
`msrc_ready_i`/`mdst_ready_i` (which reach back to `wb_ack_i` through PREPARE's `wait_for_mem_dst`,
i.e. outside this file, which is why reading `memory.vhd` alone cannot tell you). Both of the more
precise forms put the response path in front of the request path — `mreq_accept` feeds `wb_stb_o` —
and both are free to drop: every test program's cycle count is bit-identical without them, and the
CPU is smaller and 0.18 ns faster. This came out of the zero-latency-slave experiment, where they
are outright combinational loops; see doc/README.md's Optimizations section for why that experiment
was rejected.

Formal status (`formal/memory.psl`): `bmc`/`cover` (depth 10) pass. K-induction (`prove`, not
currently in `formal/memory.sby`'s task list) is **partially closed**: the three buffer/FIFO
overflow-safety properties that blocked the original attempt now prove inductively, via a
self-correcting shadow register that mirrors the type-tracking FIFO's internal transition rules
(needed because GHDL's synth-for-formal flow can't read a sub-instance's internal registers
directly — confirmed by testing external names). One property, `f_wb_master_request` (≤2
outstanding Wishbone requests), remains open under induction — true up to the checked BMC depth,
with the specific remaining obstacle documented in a comment right above it in `memory.psl`.

### Simulated peripherals: the EAE

`test/eae.vhd` is the QNICE-FPGA project's Extended Arithmetic Element — a 16x16 multiply/divide
device — adapted from upstream to a Wishbone slave interface. `test/system.vhd` gives it the
**upper half of the data address space, `0x8000`-`0xFFFF`**, and it decodes only
`wbd_addr(2 downto 0)`, so its five registers alias every 8 words throughout that half. The
programs address it at `0xFF18`-`0xFF1C`, the same addresses upstream QNICE-FPGA uses.

**It is simulation only.** The instance sits inside a `pragma synthesis_off` block, exactly like
`test_monitor`, and is not part of any bitstream. Neither is the multiplexer in front of it: both
sit in `system.vhd`'s `gen_sim : if G_SIMULATION generate`, whose `else generate` wires the data
bus straight to the RAM, so the synthesized system has one slave and the RAM aliases across the
whole 64 kW data address space. Nothing in the CPU addresses the EAE's half. It exists for the
tests, not for the hardware — and excluding the mux with it is **not** tidiness, it is worth
0.21 ns of timing margin; see [The data bus multiplexer](#the-data-bus-multiplexer) below.

It is here for one reason: **a more realistic instruction mix**. Every other program in `test/` is
hand-written to corner some specific part of the CPU, which makes the suite's instruction and
memory-access patterns quite unlike real code. `test/prog_mandel_perf.asm` is a real program doing
real work, adapted from upstream, and its inner loop calls a monitor-style signed-multiply routine
— which needs a multiplier device. The EAE is that device. Its own header records what was changed
from upstream and why the upstream MIPS figures quoted in it no longer describe either this grid or
this CPU.

**`prog_mandel_perf.asm` checks its own arithmetic and keeps no writes golden.**
It used to check nothing — compute the sweep, discard it, write a passing status
word — with `prog_mandel_perf.writes.golden` standing in: 3.0 MB over 91k lines,
more than every other golden file in the tree combined, and diffed by neither
`make test_slow` nor anything else that matters under a slow memory. Now each
pixel folds its final `z0`/`z1` into `CHECKSUM` and `MANDEL_END` compares the
total against `C_CHECKSUM`, halting with status `0x0001` on a mismatch: three
instructions per pixel, none in the iteration loop, **+1.05%** of the cycle
count, and a check that works under `test_slow` where the trace did not. Fault
injection confirms the sensitivity — `+256` on the EAE's signed multiply fails
the run, `+1` does not, because the program's own `/256` discards the low byte.
So the program is listed in the Makefile's `NO_WRITES_GOLDEN`: `make check`
skips its writes diff and `make golden` writes no copy, while `.stats.golden` is
diffed as before. **`C_CHECKSUM` is part of the grid** — retuning `X_STEP` /
`Y_STEP` / `ITERATION` changes it, and the program fails until it is updated.

`test/prog_mandel_stats.asm` is a two-line file that `#define`s `INSTRUMENT`
and `#include`s `prog_mandel_perf.asm`, enabling `#ifdef INSTRUMENT` counters in
that program: pixels, pixels that used their whole `ITERATION` budget without
diverging, and total iteration count. Those and the checksum are dumped just
before the status word into the **probe window `0x7FF0`-`0x7FFE`**, which
`test_monitor.vhd` reports (`Probe 0x7FF1 = 0x006E (110)`) rather than treating
as a verdict — a one-way channel for handing a measurement to a human, checked
against nothing, inert unless a program writes to it and therefore needing no
generic plumbed through `system.vhd` or the Makefile.
`make run TEST=prog_mandel_stats`. It is not in `TESTS` and has no golden files;
the feedback exists to tune `X_STEP` / `Y_STEP` / `ITERATION`, which trade
watchdog headroom against how much of the sweep still does real iteration work
(currently 110 pixels, 18 of them full, 888 iterations), and the checksum probe
at `0x7FF0` is dumped *before* the comparison so a failing run reports the value
to paste into `C_CHECKSUM`. **Instrumenting through the preprocessor rather than
by copying the program is load-bearing**: `prog_mandel_perf.asm` is the
benchmark, so four extra instructions in the iteration loop would move every
counter in `prog_mandel_perf.stats.golden`. `make` cannot see the `#include`, so
the Makefile names the benchmark as an explicit prerequisite of
`prog_mandel_stats.rom` — without it an edit silently fails to reach the
instrumented build.

Two test programs cover the device itself. `test/prog_eae.asm` is table-driven over all four
operations (MULU, MULS, DIVU, DIVS); note its DIVS expectations follow `numeric_std`'s `mod`
semantics, where the remainder takes the sign of the divisor. `test/prog_eae_stall.asm` is the
regression test for the stall bug in `bd0b7da` — the EAE stalls the shared data bus after a write
to it, and the fix has two independent halves (a chip-select gate in `eae.vhd`, an addressed-slave
mux in `system.vhd`), either of which masks the bug alone, so the test pins the pair rather than
each line. Its header says so.

### Simulating a slow memory

`test/wb_dp_mem.vhd` models slave latency in the two independent ways a pipelined Wishbone slave
can be slow, **per port**: `G_x_STALL_DELAY` delays acceptance of a request, `G_x_ACK_DELAY` is the
total acceptance-to-ACK latency (minimum 1). The Makefile exposes all four as `A_STALL_DELAY`,
`B_STALL_DELAY`, `A_ACK_DELAY`, `B_ACK_DELAY`, defaulting to the zero-latency behaviour every
`test/*.golden` was recorded against.

`make test_slow` runs the whole suite at `2/2/3/3`, and CI runs it as a second step after
`make test`. It diffs nothing against the golden files — the delays change every cycle count, and
stalling the data bus reorders the write log's interleaving of register and memory writes — and
checks each program's own status word instead. That is the point: against a zero-latency slave,
FETCH's `wb_stale` counting and MEMORY's op-type FIFO are barely exercised, and FETCH's bus-cycle
teardown path is unreachable, since it only runs when a request is stuck on `STB` against a
**stalling** slave — the case the "Two things were measured and rejected" note above calls
impossible against the dual-port RAM. Setting `A_STALL_DELAY` is what makes it possible.

Two things are load-bearing in the model. Read data must be delayed alongside the ACK, because
`dp_ram` presents a read one cycle after its address and re-reads every cycle, so the array output
has moved on by the time a late ACK is due; being a fixed-latency shift register, that chain also
gives in-order ACKs for free. And **pending ACKs must be dropped when `CYC` deasserts**, since
dropping `CYC` cancels everything outstanding — without that, `A_STALL_DELAY` corrupts instruction
fetch through the teardown path above. Reverting that one guard leaves `make test` green while
`make test_slow` fails on 7 of 13 programs.

### The data bus multiplexer

`test/wb_mux.vhd` splits the data bus between two slaves on the top address bit — RAM below
`0x8000`, EAE above. It exists because an address decode alone is **not** enough once the two
slaves have different latencies.

A pipelined Wishbone ACK is a bare pulse, so a master with several requests in flight pairs them
with responses by position, and therefore requires its slave to acknowledge in issue order (see
[MEMORY module](#memory-module-srcmemorymemoryvhd) above). Fan that bus out to two slaves and the
requirement breaks the moment they differ: issue to the slow one and then the fast one, and the
second response comes back first. This was demonstrable — before this module existed, a single
`SUB @ram, @eae`, whose two operand reads DECODE issues on consecutive cycles, hung or computed the
wrong answer at every `B_ACK_DELAY` above 1.

So the mux records which slave each accepted request went to, in issue order, and releases
responses strictly in that order, buffering any that arrives early. Both slaves may be arbitrarily
slow, in either way and differently from each other, and the master sees nothing out of order.

Two properties are worth preserving if this is ever touched:

* **It adds no latency.** Requests fan out combinationally; a response whose slave is at the head of
  the order queue with nothing buffered ahead of it — the common case, and the only case when the
  latencies match — reaches the master in the same cycle its ACK arrives. The proof is cheap: every
  `test/*.stats.golden` is unchanged from before the module was introduced, and a single added
  cycle anywhere would have moved them.
* **Nothing on the request path comes off an ACK.** The stall the master sees is its slave's stall
  plus a term off a register, so the response path is never spliced onto the front of the request
  path — the same discipline `memory.vhd`'s `mreq_accept` documents.

`G_MAX_OUTSTANDING` (default 2) bounds the response buffers by stalling a request that would exceed
that many in flight, which is what makes overflow impossible rather than merely unlikely; an
`assert ... severity failure` catches it if the reasoning is ever wrong. Both masters cap themselves
at two outstanding (`C_MAX_PENDING` in `fetch.vhd`, the depth-2 FIFO in `memory.vhd`), so the limit
is never reached and costs nothing.

`test/prog_wb_mux.asm` is the regression test, and it is the `make test_slow` run that gives it
teeth: at the default delays both slaves answer in one cycle and nothing can reorder. Breaking the
ordering logic leaves `make test` green and fails `test_slow`.

**It is not synthesized**, and that is a measured decision rather than a stylistic one — it was
instantiated unconditionally at first and `make system.bit` failed timing, at WNS −0.148 ns with
three failing endpoints. Two separate costs, both measured by building it each way:

* the module itself, 38 flip-flops and 80 LUTs, mostly the response buffer;
* and, larger, what it does to the CPU. `wb_dp_mem` never stalls at the default latency generics,
  so with a direct connection `wbd_stall` is a synthesis **constant** `'0'` and the CPU's whole
  hold-a-stalled-request path folds away. `mux_stall` makes it live again, putting back 32
  flip-flops in MEMORY and 79 LUTs in CPU_MAIN — the latter in exactly the stage the critical path
  runs through.

1076 LUTs / 673 registers at −0.148 ns, against 939 / 603 at +0.060 ns. None of the failing paths
touched the mux; it is the area and the un-folded back-pressure logic perturbing a
routing-dominated path, which is the placement sensitivity the
[Utilization numbers](#utilization-numbers) section warns about, arriving on cue. Note the second
cost would survive a leaner multiplexer — any slave that can stall pays it — so the lever is
keeping the mux out of the bitstream, not shrinking it. The comment above the generate in
`system.vhd` carries these numbers.

It is also formally verified — `formal/wb_mux.{psl,sby,gtkw}`, four tasks, all passing. The
ordering property is stated end-to-end on the ports rather than by re-reading the module's own
order queue: each slave is *assumed* to answer with its identity in the top data bit and an
alternating sequence bit in the bottom one, and a shadow queue built only from the master-side
handshake says what each accepted request is owed. A mux that released a fast slave's answer early
fails on the top bit; one whose per-slave buffer popped backwards fails on the bottom bit.

Two things there are worth knowing before editing it. **The 3-deep task is not redundant**: at
`G_MAX_OUTSTANDING = 2` a per-slave buffer never holds more than one word (`f_buf0_bound` proves
the bound is `G_MAX_OUTSTANDING - 1`), so order *within* one slave is unreachable and a buffer that
popped backwards passes everything — fault injection confirms that fault is caught only at depth 3.
And **`f_response_order` is proven only to the BMC depth**, not by k-induction; every other
assertion does close inductively, and the specific obstacle is written above the property.

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
flip-flop added next to ICACHE for the HALT gate once cost 0.284 ns, the whole margin, without
appearing on the path; re-measure after an unrelated edit rather than assuming it cannot matter.

**The clock constraint is 7.45 ns** (`hw/system.xdc`), and has been relaxed twice. It was 7.25 ns
until that placement sensitivity made `make system.bit` a coin flip: two refactors that added no logic — the design came
out 14 LUTs *smaller* — moved WNS from +0.025 to −0.018 ns and stopped the build emitting a
bitstream, while five `place_design` directives on one unchanged netlist spanned +0.028 to
−0.028 ns. Every timing figure quoted in this file and in the per-module READMEs predates the change
and was measured at 7.25 ns; they have deliberately been left as measured, so read them as a record
of that experiment rather than as the current margin. Shortening the critical loop was tried before
relaxing the constraint and does not pay — the reasoning and the measurements are in
doc/README.md's Utilization section.

The **second** relaxation, 7.35 → 7.45 ns, paid for a correctness fix rather than a refactor. Two
flush terms landed on `fetch_valid_o` in quick succession and between them spent more than the
margin. The subroutine-push term (see [Self-modifying code](#self-modifying-code)) cost 0.055 ns of
the 0.060 ns there was, without touching the critical path — it reads `prep_stage_i.immediate`,
which WRITE had no other use for, so sixteen flip-flops synthesis used to optimise away came back
and the area moved the placement. Deferring the R14/R15 pointer flush then cost about 0.11 ns more,
and the design missed at 7.35 ns by −0.100 ns with 21 failing endpoints. Neither is logic depth that
can be optimised away: the failing path runs `r14` → `update_reg` → `reg_we_o` → `fetch_valid_o` →
ICACHE's clock enable and is 80% routing, and `update_reg` cannot leave that net. Two attempts to
buy it back — lifting `rst_i` out of a series OR into its own term, and deleting a provably dead arm
of `smc_hit` — moved WNS by 0.004 ns between them. Current build: **WNS +0.017 ns**, no failing
endpoints.

The script rewrites **numbers only** — the surrounding analysis is a hand-written design argument.
Every substitution is anchored on an exact pattern and a missing anchor is a hard error, so
rewording one of those sentences breaks `make utilization` loudly rather than silently leaving a
stale figure behind. **This cannot run in CI**: Vivado is a 38 GB licensed install and
GitHub-hosted runners cannot host it, so the numbers are refreshed deliberately, on a machine that
has Vivado.

### Directory layout

- `src/cpu_constants.vhd` — shared constants/types used across modules.
- `src/fetch/` — WISHBONE instruction fetcher.
- `src/icache/` — two-word instruction buffer between FETCH and DECODE.
- `src/registers/` — register file (dual-port RAM based, write-before-read).
- `src/memory/` — Wishbone-facing memory arbiter (source/destination operand buffers).
- `src/cpu_main/` — DECODE, SEQUENCER, PREPARE, WRITE, and the `sub/` microcode ROM and ALU.
  SEQUENCER sits beside the stages rather than in `sub/` because `cpu_main.vhd` instantiates it
  itself, on the DECODE→PREPARE link.
- `src/sub/` — reusable elastic-pipeline building blocks, see
  [Elastic pipeline building blocks](#elastic-pipeline-building-blocks-srcsub) above.
- `src/cpu.vhd` — top-level entity tying FETCH, ICACHE, REGISTERS, MEMORY, and CPU_MAIN together.
- `test/` — testbench (`tb_cpu.vhd`), memory models, the pass/fail monitor (`test_monitor.vhd`),
  and `.asm` test programs. See [test/README.md](test/README.md) for how to tell a passing run
  from a failing one. `test/eae.vhd` is a simulation-only arithmetic peripheral,
  `test/wb_dp_mem.vhd` the memory model whose latency generics drive `make test_slow`, and
  `test/wb_mux.vhd` the order-restoring data bus multiplexer between them,
  and `test/prog_mandel_stats.asm` the instrumented build of
  `test/prog_mandel_perf.asm` — see
  [Simulated peripherals: the EAE](#simulated-peripherals-the-eae),
  [Simulating a slow memory](#simulating-a-slow-memory) and
  [The data bus multiplexer](#the-data-bus-multiplexer) above.
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
