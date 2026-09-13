# Testbench, peripherals, and the differential tests

Guidance for Claude Code when working in `test/`. Claude Code loads this file on demand,
when it touches a file in this directory; the repository-wide rules stay in the top-level
[CLAUDE.md](../CLAUDE.md). How to tell a passing run from a failing one is in [README.md](README.md);
the pass criterion itself is in the top-level file, because it governs `make test`
before anything here is opened.

## Differential testing against upstream

`make test` and `make test_slow` compare this CPU against **itself**: every `test/*.golden` file
was recorded from a passing run of this implementation, so an answer that has been wrong since the
goldens were written passes them green forever. Two targets close that gap by running each program
on an upstream implementation and diffing the final architectural state against what this CPU left
behind. `make crosscheck` uses QNICE-FPGA's C emulator; `make crosscheck_rtl` uses **upstream's own
CPU**, `vhdl/qnice_cpu.vhd`, under GHDL. Both build their reference from the Makefile's
`QNICE_REF` — the same commit `.github/workflows/test.yml` pins for the assembler — into
`test/crosscheck/`, which is generated and gitignored. The harness is `test/crosscheck.py`, shared
by the two via `--reference emulator|rtl`; its header carries the design.

**What is compared is memory AND registers**: all 32768 words of `0x0000`-`0x7FFF`, plus `R0`-`R13`.
The register half rests on `src/debug.vhd` logging the **bank** a write to `R0`-`R7` lands in —
without it "to register 3" names eight different registers over a program's life and no final
register file can be reconstructed. The bank comes from `registers.vhd`'s `wr_bank_o`, a port that
exists only for this, and it must be `reg_sr` rather than `sr_val_o`: the latter forwards a write in
flight, including the dedicated SR port that fires alongside most ordinary register writes, and that
this never disturbs the bank bits is a property of what WRITE puts on it rather than something the
register file guarantees. `wr_bank_o`'s only consumer sits inside `pragma synthesis_off`, so it is
unconnected in every synthesised build and optimises away. Adding the bank moved every
`test/*.writes.golden`; the diff was purely the added suffix, with no value, order or count changing
anywhere, and that is what to check if it ever has to be done again.

`R14` and `R15` are deliberately excluded. `R14` is mostly flags, which the two implementations are
not obliged to agree on (`prog.asm`'s `PTR_SR` group is the standing example) and which neither side
logs, since the dedicated flag port fires on nearly every instruction. `R15` is the PC, which this
CPU keeps in FETCH and writes to the register file only on branches, so at `HALT` the two references
are not describing the same object. Coverage of the banks differs by reference and the output says
which: `crosscheck_rtl` compares **every bank** either side wrote, because `tb_upstream.vhd` logs
upstream's writes in the same format, while `crosscheck` compares only the window the emulator
halted in — its `RDUMP` resolves `R0`-`R7` through the current bank and cannot be asked for the
other 255. The two banks are cross-checked before any register is, so a disagreement is reported as
itself rather than as eight spurious diffs.

**Running both is not redundancy, it is the point.** The three programs that fail are different in
each direction, and every one of them is a place where the two upstream implementations disagree
with *each other*, so a single reference would have made each look like a settled question. The
two EAE programs fail on the emulator (DIVS remainder sign; when the EAE recomputes) and pass on
the RTL, which turns an argument from reading upstream's source into an end-to-end result.
`prog_r15` fails on the RTL: upstream's `cs_decode` latches both operands at once, before the
source `@R15++` post-increment, so `ADD 0x0002, R15` reads its destination one word low; the
emulator reads the destination after the source, and this CPU follows the emulator. Each is
recorded in `KNOWN_DIVERGENCE` and **asserted** — if a divergence disappears the harness fails,
rather than quietly passing.

`test/tb_upstream.vhd` also writes a log of upstream's own register and memory writes, in
`debug.vhd`'s format, reached by VHDL-2008 **external names** into the register file instance's
ports (declared inside the process, because an alias in the architecture's declarative part
elaborates before the instances and GHDL rejects it). That is both the input to the register
comparison and the diagnostic that was missing when `prog_r15` diverged and had to be traced by
hand. It is not something to `diff -u` against this repo's log — a pipeline and a multi-cycle FSM
interleave their writes differently, and neither order is wrong.

The RTL reference runs in `test/tb_upstream.vhd`, which is ours and is linted with everything else.
It gives upstream's CPU the smallest system these programs need — one writable 32 kW RAM over
`0x0000`-`0x7FFF` plus the EAE and the Interrupt Generator, with the RAM modelled on upstream's own
`block_ram.vhd` — rather
than upstream's `env1.vhd`, whose map puts ROM where every program here is linked. Three things
are load-bearing. Upstream's sources are analysed into a **GHDL library of their own**
(`test/crosscheck/work`), because upstream's `cpu_constants.vhd` and this repo's
`src/cpu_constants.vhd` declare packages of the same name. **`-fsynopsys` is required** and is
upstream's choice, not ours: `qnice_cpu.vhd` and `register_file.vhd` use `ieee.std_logic_arith`
and `ieee.std_logic_unsigned` — it applies only to that separate analysis, and nothing under
`src/` is touched by it. And exactly one upstream file is modified, by `test/upstream.patch`: two
hunks make the register file simulate under GHDL at all (an `integer` signal that overflows on the
initial process run at time 0, and a delta-cycle-stale array index that goes out of bounds), and
one zeroes its register arrays so that the reference powers up in the same architectural state
this CPU and the emulator do. `patch` fails the build loudly if it stops applying, which is what
should happen when `QNICE_REF` moves.

**The Interrupt Generator in `tb_upstream.vhd` is `test/interrupt.vhd`, the same file `system.vhd`
instantiates**, so that a divergence between the two CPUs cannot turn out to be a divergence
between two interrupt generators. It is therefore analysed into upstream's library as well, which
is what the Makefile's `UPSTREAM_LOCAL` is for. Sharing it costs two adapters, both argued in the
testbench's header. The device's ACK and read data are registered, while upstream's bus has to be
answered in the cycle that presents the address, so the device is given an **inverted clock** and
becomes a falling-edge slave, like the RAM model. And the device speaks this repo's AXI-stream
request port while upstream's CPU wants `INT_N`/`IGRANT_N`, so an adapter drives `INT_N` from
`irq_valid`, accepts on the grant, and drives the ISR address it **captured at the accept** onto the
data bus for as long as the grant is low. That capture is not optional: the device scrambles its
address the cycle after an accept, precisely so that a late capture fails. Every slave enable, the
RAM's included, is gated on `IGRANT_N` high, which is upstream's own rule (`mmio_mux.vhd`); for a
program that takes no interrupt the term is constant, and no other program's result moved.

**Taking an interrupt at a `HALT` is a known divergence, and it is why `prog_int_halt.asm` is a
program of its own.** Upstream's `cs_fetch` tests `INT_N` *before* it latches the fetched word as an
instruction, so an interrupt that is pending when the `HALT` is fetched is taken and the `HALT` never
executes: upstream ends that program with status `0x1802`, from inside the ISR. This CPU stops
handing instructions to DECODE once a `HALT` has been handed over (`p_halt_fetched` in
`src/cpu.vhd`), so an accepted `HALT` wins. The case exists to probe that pipeline structure, which
upstream has no counterpart to. Split out like this, `prog_int_hw.asm` runs to status `0x0000` on
upstream's CPU, and so compares word for word once this CPU passes it; `prog_int_halt` needs a
`KNOWN_DIVERGENCE` entry for `rtl` if it ever joins `TESTS`. Until interrupt entry exists here,
`make crosscheck_rtl TESTS=prog_int_hw` stops on this CPU's failing run before comparing anything;
the testbench's header gives the `ghdl -r` line that runs the reference half alone.

The upstream CPU's cycle count is reported per program and checked against nothing — it is a
multi-cycle FSM, so `prog.asm` costs it 22333 cycles against this CPU's 15581 and
`prog_mandel_perf.asm` 281583 against 170041.


## Simulated peripherals: the EAE

`test/eae.vhd` is the QNICE-FPGA project's Extended Arithmetic Element — a 16x16 multiply/divide
device — adapted from upstream to a Wishbone slave interface. `test/system.vhd` gives it the
**top quarter of the data address space, `0xC000`-`0xFFFF`**, and it decodes only
`wbd_addr(2 downto 0)`, so its five registers alias every 8 words throughout that quarter. The
programs address it at `0xFF18`-`0xFF1C`, the same addresses upstream QNICE-FPGA uses.

**It is simulation only**, and so are the Interrupt Generator below it and the multiplexers in front
of both: all of them sit in `system.vhd`'s `gen_sim : if G_SIMULATION generate`, whose
`else generate` wires the data bus straight to the RAM, so the synthesized system has one slave and
the RAM aliases across the whole 64 kW data address space. Nothing in the CPU addresses the upper
half. The devices exist for the tests, not for the hardware — and excluding the muxes with them is
**not** tidiness, it is worth 0.21 ns of timing margin; see
[The data bus multiplexer](#the-data-bus-multiplexer) below.

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


## Simulated peripherals: the Interrupt Generator

`test/interrupt.vhd` is the testbench's interrupt source, task T1 of
[doc/interrupts.md](../doc/interrupts.md). It is a Wishbone slave on the **second quarter of the
data address space, `0x8000`-`0xBFFF`**, decoding only `wbd_addr(2 downto 0)` like the EAE; the
programs address it at `0xBF00`-`0xBF03`. On the other side it drives the CPU's three-signal
request port (`irq_valid`/`irq_ready`/`irq_addr`, see
[src/interrupt/README.md](../src/interrupt/README.md)). The register map in its header is copied
verbatim into each program that uses it, and the copies must follow any change:

| Address | Register |
|---|---|
| `0xBF00` | Countdown. A write of `n` asserts the request after `n` idle cycles; reads back as zero once fired. |
| `0xBF01` | The ISR address presented with the request. Resets to `0x0000`. |
| `0xBF02` | Bit 0 is the request line itself, so it can only read `1` from inside an ISR. |
| `0xBF03` | The number of requests accepted since reset. |

Four behaviours are load-bearing:

* **Program-triggered, not free-running.** A timer would be deterministic too, but the interrupt
  would land on a different instruction after any pipeline change and churn the golden files on
  unrelated commits. The countdown still lets a program place a request at a chosen cycle offset,
  which is how the programs sweep a request across every stage an instruction occupies.
* **The countdown only runs while no request is pending**, and a write overrides it. The timer
  update follows the accept in the same process, so without that guard a countdown expiring in the
  accept cycle would re-assert the request the accept had just cleared, and one expiring while a
  request is held would silently merge into it.
* **The CPU's side of the handshake is asserted**, and more strictly than AXI-stream requires:
  `irq_ready` must be a one-cycle pulse ("Duplicate irq_ready_i") and only while the request stands
  ("Stray irq_ready_i"). Both are `severity failure`, so a CPU that breaks the contract kills the
  run rather than passing. The same assertions police upstream's CPU in `tb_upstream.vhd`.
* **`irq_addr` is scrambled to all-ones the cycle after an accept.** A CPU that captures the ISR
  address late, rather than at the accept, then jumps to `0xFFFF` instead of passing by luck.

Its ACK is registered, one cycle after the request, the same latency as the EAE's. So
`i_wb_mux_dev` never actually has anything to reorder, and its ordering is covered by
`formal/wb_mux` rather than by any program; `make test_slow` slows only the RAM.

Two programs use it, and **neither is in `TESTS`**, because they were written ahead of the CPU
feature they test. `test/prog_int_hw.asm` covers cases 4-6 of the doc's test list plus pipeline
edge cases the doc does not name: three-micro-op and two-word instructions, a slow EAE operand,
flushes from a taken branch, a bank change, and self-modifying code, a request during a software
`INT`, a post-increment walk, and `R14` restore. Failure codes are `0x1abc` (test, subcase, check),
and `TOTAL_ACCEPT` is **hand-counted** from the per-test tally above it, so a sweep that changes
length must update both. It fails today, as it must. `test/prog_int_halt.asm` checks that an
interrupt pending at the final `HALT` is **not** taken; it passes today, vacuously, since nothing
here takes interrupts yet, and it is kept apart because upstream's CPU legitimately answers it the
other way (see [Differential testing against upstream](#differential-testing-against-upstream)).
Neither has golden files yet.


## Simulating a slow memory

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
**stalling** slave — the case the "Two things were measured and rejected" note in
[src/cpu_main/CLAUDE.md](../src/cpu_main/CLAUDE.md#early-redirect-unconditional-branches) calls
impossible against the dual-port RAM. Setting `A_STALL_DELAY` is what makes it possible.

Two things are load-bearing in the model. Read data must be delayed alongside the ACK, because
`dp_ram` presents a read one cycle after its address and re-reads every cycle, so the array output
has moved on by the time a late ACK is due; being a fixed-latency shift register, that chain also
gives in-order ACKs for free. And **pending ACKs must be dropped when `CYC` deasserts**, since
dropping `CYC` cancels everything outstanding — without that, `A_STALL_DELAY` corrupts instruction
fetch through the teardown path above. Reverting that one guard leaves `make test` green while
`make test_slow` fails on 7 of 13 programs.


## The data bus multiplexer

`test/wb_mux.vhd` splits a Wishbone bus between two slaves on a select input, `s_sel_i`, which the
instantiator derives from the address. `system.vhd` uses it twice: `i_wb_mux` on bit 15, RAM below
`0x8000` and the devices above, and `i_wb_mux_dev` behind it on bit 14, the Interrupt Generator
below `0xC000` and the EAE above. The select is a port rather than a fixed address bit so that the
module stays agnostic of the address map. The mux exists because an address decode alone is **not**
enough once the slaves have different latencies.

A pipelined Wishbone ACK is a bare pulse, so a master with several requests in flight pairs them
with responses by position, and therefore requires its slave to acknowledge in issue order (see
[MEMORY module](../src/memory/CLAUDE.md#memory-module-srcmemorymemoryvhd)). Fan that bus out to two slaves and the
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
[Utilization numbers](../hw/CLAUDE.md#utilization-numbers) section warns about, arriving on cue. Note the second
cost would survive a leaner multiplexer — any slave that can stall pays it — so the lever is
keeping the mux out of the bitstream, not shrinking it. The comment above the generate in
`system.vhd` carries these numbers.

It is also formally verified — `formal/wb_mux.{psl,sby,gtkw}`, four tasks, all passing. The
ordering property is stated end-to-end on the ports rather than by re-reading the module's own
order queue: each slave is *assumed* to answer with its identity in the top data bit and an
alternating sequence bit in the bottom one, and a shadow queue built only from the master-side
handshake says what each accepted request is owed. A mux that released a fast slave's answer early
fails on the top bit; one whose per-slave buffer popped backwards fails on the bottom bit. The
shadow queue classifies requests by `s_sel_i`, and `f_s_stable` holds `s_sel_i` stable under a
stalled request along with the address and data; dropping it from that assumption fails BMC at
step 2 on `f_m0_stable` or `f_m1_stable`, since the combinational fan-out re-routes a held request.

Two things there are worth knowing before editing it. **The 3-deep task is not redundant**: at
`G_MAX_OUTSTANDING = 2` a per-slave buffer never holds more than one word (`f_buf0_bound` proves
the bound is `G_MAX_OUTSTANDING - 1`), so order *within* one slave is unreachable and a buffer that
popped backwards passes everything — fault injection confirms that fault is caught only at depth 3.
And **`f_response_order` is proven only to the BMC depth**, not by k-induction; every other
assertion does close inductively, and the specific obstacle is written above the property.
