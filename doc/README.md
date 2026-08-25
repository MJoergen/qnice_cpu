# A pipelined implementation of the QNICE CPU

## Architecture
This implementation is essentially a four-stage pipeline consisting of:

* FETCH: Fetches from the instruction memory and presents up to two words
  (instruction plus immediate operand) at a time to the DECODE stage.
* DECODE: Translates the instruction into a list of up to three
  micro-operations, and reads the operand registers.
* PREPARE: Sequences that list into one micro-operation per clock cycle, and
  prepares the input operands for the ALU.
* WRITE: Contains the ALU and performs write-back of the result to register
  and/or memory.

See the following block diagram:

![Block Diagram](cpu.png)

The block diagram contains two additional blocks:
* Registers: Contains the CPU registers and supports two read ports (connected
  to DECODE) and one write port (connected to WRITE). Note that the working copy
  of the Program Counter `R15` lives in the FETCH stage, not here. The register
  file's `R15` copy is only written when an instruction targets `R15`, so it is
  stale during sequential execution; PREPARE substitutes the real PC for either
  operand whenever `R15` is read, in any addressing mode.
* Memory: Interfaces to the Wishbone memory bus and supports two read ports
  (connected to PREPARE) and one write port (connected to WRITE).

Not drawn in the block diagram is the path from WRITE back to FETCH. Any write
to `R15` is forwarded to FETCH as a new Program Counter, and the same signal
flushes the DECODE and PREPARE stages. That is how every branch works, and it is
the only way the pipeline is cleared other than a global reset.

The flow through the pipeline is that an instruction will spend one or two
clock cycles in the FETCH stage (two cycles if it uses an immediate operand),
and up to three clock cycles in DECODE -- one per micro-operation, because the
Sequencer in PREPARE holds DECODE stalled until it has issued the last one. The
PREPARE stage additionally waits for any memory operands to be read. The WRITE
stage is entirely combinatorial, the ALU included; the only registers it drives
are the outputs of the other blocks.

In the above we see a Harvard architecture, where we have a separate
instruction and data interface. The main reason for this choice is to simplify
the implementation. It does also provide a nice side effect of increasing the
available memory bandwidth, because we can read from instruction and data
memory simultaneously, see below section on [Interleaving](#Interleaving).

There is one important detail to note about the Harvard architecture and that
is that it requires dual port memory. This is because we want the system to
allow loading a program to memory and then executing the program. This requires
that the same memory can be accessed both as data memory and as instruction
memory.  Thankfully, most modern FPGAs have built-in dual port memories that
support this construct natively.


## Back-pressure
The thick arrows indicate the AXI-like pipeline handshake, consisting of a
`VALID` signal from source to sink and a `READY` signal from sink to source.
This handshake is used to control back-pressure.

There are two sources of back-pressure in the design:
* An instruction may expand into up to three micro-operations. The Sequencer in
  the PREPARE stage issues one per clock cycle and holds its ready signal low
  until the last one has been accepted, which stalls DECODE, which in turn
  applies back-pressure to the FETCH stage.
* The Memory module will generate back-pressure while waiting for the result
  read from the memory bus. This is part of the Wishbone protocol and allows
  for an I/O device to take more than one clock cycle to respond.


## Detailed design description
For more detailed information about the design look here:
* [FETCH](../src/fetch/README.md)
* [Registers](../src/registers/README.md)
* [Memory](../src/memory/README.md)
* [DECODE/PREPARE/WRITE](../src/cpu_main/README.md)

The four stages and the two shared blocks are all built from a small set of
reusable valid/ready primitives in `src/sub/` (`one_stage_buffer`,
`one_stage_fifo`, `two_stage_buffer`, `two_stage_fifo`, `dp_ram`,
`pipe_concat`); they are described in the top-level
[CLAUDE.md](../CLAUDE.md#Elastic-pipeline-building-blocks-src-sub) and each has
its own formal job in `formal/`. How to run the test programs, and how to tell a
passing run from a failing one, is in [test/README.md](../test/README.md).


## Wishbone
I think it's worthwhile to give here a short summary of the Wishbone protocol as
it is used in this design.

The CPU is a Wishbone *master* on two independent buses: `wbi_*` for instruction
fetch and `wbd_*` for data. Both use the **pipelined** flavour of Wishbone, in
which a master may issue a new request before earlier ones have completed. The
master-side signals, as declared in [cpu.vhd](../src/cpu.vhd), are:

```
wb_cyc_o   : out std_logic;                       -- bus cycle active
wb_stb_o   : out std_logic;                       -- request strobe
wb_stall_i : in  std_logic;                       -- slave cannot accept yet
wb_addr_o  : out std_logic_vector(15 downto 0);
wb_we_o    : out std_logic;                       -- 1 = write, 0 = read
wb_dat_o   : out std_logic_vector(15 downto 0);   -- write data
wb_ack_i   : in  std_logic;                       -- request completed
wb_data_i  : in  std_logic_vector(15 downto 0);   -- read data
```

A slave sees the same signals with the directions reversed (`wb_cyc_i : in`,
`wb_stall_o : out`, and so on). The instruction bus is read-only and so has no
`wb_we_o`/`wb_dat_o`.

Each transaction has **two** separate handshakes, and it is worth keeping them
apart:

* **Request accepted.** The master asserts `wb_cyc_o` and `wb_stb_o` together
  with the address, `wb_we_o`, and (for a write) the write data. The request is
  accepted on any clock edge where `wb_stb_o` is high and `wb_stall_i` is low.
  This only means the slave has taken the request -- it does *not* mean the
  transaction is finished.
* **Request completed.** The slave later pulses `wb_ack_i`, once per accepted
  request. For a read it drives the result onto `wb_data_i` in that same cycle.
  **Writes are acknowledged too**, with no meaningful data.

Because acknowledgements are just pulses carrying no identifying information,
and because several requests may be outstanding at once, the master has to
remember what it asked for and in what order. That is exactly what the FIFO
inside the [Memory module](../src/memory/README.md) does: it records the type of
every accepted-but-unacknowledged request, and matches each `wb_ack_i` against
the oldest one to decide whether the returned data belongs to the source operand
buffer, the destination operand buffer, or nowhere at all (a write). This relies
on the slave acknowledging in issue order.

## Interleaving
Analyzing the timing of a QNICE assembly program is not simple, due to the
pipeline architecture. Some instructions - like `MOVE 0x0000, R0` - are limited
by the bandwidth of the instruction memory, while other instructions - like
`MOVE @R0, @R1` - are limited by the bandwidth of the data memory.

What this means is that the instruction `MOVE 0x0000, R0` needs only one clock
cycle to execute, but it needs two clock cycles to read the instruction and
immediate operand from the instruction memory. On the other hand the
instruction `MOVE @R0, @R1` needs only one clock cycle to read from instruction
memory, but needs at least two clock cycles to execute.

In the file [`test/prog_interleave.asm`](../test/prog_interleave.asm) I conduct a
small experiment, where I first have a run of `MOVE <imm>, R0` instructions that
each take two clock cycles, then a run of `MOVE @Rx, @Ry` instructions that again
take two clock cycles each. The final part alternates the two forms, and each
such *pair* takes a total of three clock cycles rather than four. So the pair is
faster than the sum of the two instructions taken separately, because the
instruction and data memories are operating simultaneously.

### How much the split is worth

That experiment shows the effect on three instructions. `test/test_monitor.vhd`
measures it over whole programs: it counts accepted beats on each Wishbone bus,
and cycles in which *both* buses accepted one. The counts are written to
`test/<program>.stats` and diffed against a committed reference copy by
`make check`, so they cannot silently drift — see
[test/README.md](../test/README.md#The-statistics-comparison).

Every simultaneous request is a cycle a single-ported design would have had to
serialise. For `test/prog.asm`, the longest of the test programs:

| | |
| --- | --- |
| cycles | 15811 |
| instruction requests | 13484 (85% of cycles) |
| data requests | 1848 |
| ...of which simultaneous | 1822 (**98.6%** of data requests) |

Almost every data access collides with an instruction fetch — which follows from
the instruction bus being busy 85% of the time. Serialising them onto one port
would cost at least 1822 cycles, i.e. **+11.5%**, and more in practice, since
each inserted stall also delays whatever was behind it in the pipeline. It is a
lower bound in a second sense as well: it counts only the collisions that
actually occurred in a machine built not to have to avoid them.

The gain is uneven across programs, as the reasoning above predicts.
`test/prog_flags.asm` is almost pure register arithmetic — 2 data requests in
271 cycles — and gains essentially nothing. `test/prog_interleave.asm`, the
experiment described above, is at the other end: 21 data requests in 54 cycles,
17 of them simultaneous.

## Self-modifying code
Instruction and data memory are two ports of the same physical RAM, so a program
can store into its own instruction stream. Doing so is fully supported, with no
latency requirement: an instruction may be rewritten by the store immediately
before it.

That did not use to be true, and the failure was silent. FETCH, the Icache,
DECODE and PREPARE have all read ahead of the instruction retiring in WRITE, so
a store landing on one of those addresses changed the RAM but not the copy about
to execute — the *old* instruction ran, with nothing anywhere reporting a
problem. Five instructions of padding, or a branch, was enough to hide it,
which is the worst possible property for a bug to have.

WRITE now treats such a store as a control transfer. When a store retires, it
checks whether the address is close enough to the program counter to have been
read already, and if so asserts the same `fetch_valid_o` that a taken branch
uses: DECODE and PREPARE are reset, FETCH and the Icache discard their buffers,
and execution restarts at the following instruction, which is re-fetched from
the updated RAM. The write has landed by then — the memory is true dual-port,
and the re-fetch cannot get back to the bus in the same cycle.

Two things are worth knowing:

* **The check is deliberately over-approximate.** It flushes on any store within
  32 words after the current instruction, where the real read-ahead is at most 8
  (2 words each for PREPARE and DECODE, 2 in the Icache and `C_MAX_PENDING` = 2
  in FETCH; probing the fetch pointer against the Icache output over the whole
  of `prog.asm` gives a maximum of 4 for the last two together). The slack is
  what makes the comparison cheap enough to sit on the flush net at all — see
  the comment above `smc_delta` in
  [write.vhd](../src/cpu_main/write.vhd), where the exact version is recorded
  along with the −0.042 ns it cost. Over-approximating is safe by construction:
  a spurious flush costs cycles, never correctness.
* **So a store near the PC costs a branch penalty**, whether or not it was aimed
  at code. This is why the window is not simply "every store": flushing
  unconditionally costs 8.5% of the run time of `prog.asm` and 64% of
  `prog_interleave.asm`. With the window, `prog.asm` pays 0.07% and
  `prog_interleave.asm` pays nothing.

[`test/prog_self_modifying.asm`](../test/prog_self_modifying.asm) covers this
from both sides. `T1` rewrites the opcode of the very next instruction, `T2` its
immediate operand, `T4` the instruction two ahead, `T5` reaches the instruction
through a pre-decrement pointer, and `T7` patches an instruction inside a loop
so the hazard is hit on every iteration; each of those fails without the flush.
`T3` stores *outside* the window and `T6` stores to data that merely sits near
the PC — both pass either way, and are there to pin the two edges.


## Optimizations
I have a few ideas for cycle optimizations at the moment:
* Make the fetch module not clear `wbi_cyc_o` at every branch. This will reduce
  the branch penalty by one clock cycle.


## TODO
* Formal verification: the suite in `formal/` currently passes in full (twelve
  modules, thirty-five tasks). What is still missing is a `prove` (k-induction)
  task for `cpu_main`, and closing the last open property of `memory`'s
  inductive proof.
* Add interrupts.


## Utilization

Measured with Vivado 2022.2 on commit `96baad8`.

Refresh with `make utilization` (needs Vivado). That re-runs both passes below
and rewrites every number on this page — the provenance line above, both tables,
the timing figure, and the figures quoted in the prose. The prose itself is
hand-written and is left alone; the script fails rather than continue if a
sentence it fills in has been reworded, so a stale number cannot slip through
unnoticed.

### Device totals

From the shipping build (`make system.bit`), **after place-and-route**. These
cover the whole `system`, i.e. the CPU plus the testbench memory model — but the
memory model is essentially all Block RAM, so the LUTs are the CPU's:

| Resource        | Used | Available | %    |
| --------------- | ---- | --------- | ---- |
| Slice LUTs      |  873 |     63400 | 1.38 |
| Slice Registers |  580 |    126800 | 0.46 |
| Slices          |  292 |     15850 | 1.84 |
| Block RAM Tile  |    6 |       135 | 4.44 |

Timing at the 8.50 ns constraint: **WNS +0.260 ns**, no failing endpoints. The
build aborts on negative slack, so a bitstream implies timing was met — see the
comment above the tcl-generating rule in the top-level `Makefile`.

### The critical path

<!-- generated: critical path -->
The worst setup path runs from `i_prepare/wr_stage_o_reg[r14][3]` to
`i_icache/m_addr_reg[18]`: 9 logic levels, with 76% of the delay in routing
rather than logic.
<!-- end -->

**Read those instance names with care.** The shipping build uses
`-flatten_hierarchy rebuilt`, which re-attributes logic across module
boundaries, so every net on this path is reported under `i_prepare/` even though
most of it is the ALU, which lives in WRITE. The full path listing in
`timing_summary.rpt` gives it away: the second hop is `i_write/i_alu/addend[0]`.

What the path really is, in both builds where the full listing was examined, is
the **Status Register loop**:

```
PREPARE's registered ALU operand
   -> the ALU in WRITE
   -> the flag logic, which produces the Status Register
   -> the register file, which forwards an SR write combinationally
   -> DECODE, which passes it through live and unregistered
   -> latched again by PREPARE
```

That loop has to close in a single clock cycle — it is what lets an instruction
consume flags produced by the instruction immediately before it, which
[`test/prog_flags.asm`](../test/prog_flags.asm) exercises directly — and it is
what sets this CPU's Fmax. Both endpoints are `wr_stage_o` fields in every build
measured; which fields they are moves around, but it is one loop, not several
unrelated paths.

It was 11 levels deep, including the adder's 16-bit carry chain, until the ALU
result mux was split in two; see the comment above `p_res_other` in
[alu_data.vhd](../src/cpu_main/sub/alu_data.vhd). The Zero flag is a 16-bit
reduction of the ALU result, so the entire 16-way result mux sat between the
adder and the flags. Muxing everything except the addition first, in parallel
with the adder, left the adder facing a single 2:1 select: 11 logic levels
became 7, and WNS went from +0.272 ns to +0.344 ns.

Adding the register-bank flush cost **0.098 ns** of that margin (+0.344 ns to
+0.246 ns at 4 LUTs *fewer*, both measured at commit `b987964`). That is not a
data path: `fetch_valid_o` resets every flip-flop in DECODE and PREPARE, so it
arrives at the reset pin of both endpoints above, and putting an extra term on a
net with that fanout perturbs the placement of the loop it gates. Worth knowing
because the first version of that flush compared the *value* landing in `R14`
against the old one, which put the ALU result and an 8-bit comparator in front
of the same net and cost **0.334 ns** — the whole margin — for a precision that
only saves a pipeline flush on `MOVE <flags>, R14`. See "Register bank switch"
in [write.vhd](../src/cpu_main/write.vhd).

Two things to know before trying to optimise it further:

* **It is now routing-bound, not logic-bound.** Only about a fifth of the delay
  is logic; the rest is interconnect, so further reductions in logic depth will
  buy much less than the level count suggests. The largest single item is the
  very first hop: `alu_src_val` bit 0 has a fanout of about 75 — it feeds the
  adder, both barrel shifters' shift-amount decode, the comparators and every
  bitwise operation — and that one net costs roughly 1.4 ns, a sixth of the
  whole budget.

  Reducing that fanout is the obvious next lever, and both easy ways of doing
  it have been tried and do not work:

  * A `MAX_FANOUT` attribute on `wr_stage_o` in
    [prepare.vhd](../src/cpu_main/prepare.vhd) does work — it is worth
    **+0.057 ns**, at a cost of 45 flip-flops and 14 LUTs. But it cannot be
    kept. In the architecture, `ghdl -a` accepts it only under `-frelaxed`,
    which the simulation flow passes and the formal flow does not: an attribute
    specification for a port must sit in the same immediate scope as the port.
    Moved into the entity, where the LRM wants it, GHDL's *synthesis* front end
    crashes with an internal assertion (`synth-vhdl_decls.adb:298`) — a GHDL
    bug, not a VHDL error — which breaks `make formal` outright.
  * `synth_design -fanout_limit 24` avoids VHDL entirely, but has no effect
    whatsoever: identical slack, identical LUT and flip-flop counts, and the
    fanout still 75. Vivado's global fanout limit does not replicate registers.

  What is left is replicating the register by hand: a second copy of
  `alu_src_val` in the stage record, carried through to the shifters, held
  against merging with `DONT_TOUCH`. That is a new record field threaded
  through three modules and into a formally verified one, for something the
  attribute experiment bounds at about 0.06 ns. Worth knowing the price before
  starting.
* **Unrelated logic elsewhere can move this number.** Because the path is
  placement-sensitive, logic that is nowhere near it can still perturb it. A
  single flip-flop added next to the Icache, for the HALT gate, once cost
  0.284 ns here — the entire margin — without appearing on the path at all;
  see the commit that introduced `make utilization`. Treat a slack change after
  an unrelated edit as plausible rather than surprising, and re-measure rather
  than reasoning about it.

### Where the logic is

The shipping build uses `-flatten_hierarchy rebuilt`, which lets synthesis
optimise across module boundaries. That is worth real slack here, because the
critical path crosses four modules — but it makes a per-module breakdown of that
build useless as a design statement: the ALU ends up reported inside PREPARE,
and `i_write` shows 16 LUTs.

The table below therefore comes from a **separate `-flatten_hierarchy none`
synthesis of the same source**, which keeps each module's logic where it was
written:

| Module          | LUTs | FFs |
| --------------- | ---- | --- |
| FETCH           |   54 |  90 |
| CACHE (icache)  |   40 |  66 |
| DECODE          |   54 |  74 |
| PREPARE         |   81 | 131 |
| WRITE           |  463 |   0 |
| Registers       |  166 | 142 |
| Memory          |   57 |  74 |
| Glue            |    8 |   1 |
| **CPU total**   |  923 | 578 |

The `Glue` row is logic sitting directly at the `cpu` and `cpu_main` levels,
belonging to no sub-module.

Two things stand out:

* **WRITE dominates, at 50% of the CPU's LUTs**, and 247 of its 463 are the ALU
  (`alu_data` 195, `alu_flags` 52). The two barrel shifters in `alu_data` are the
  single largest block in the design. They were 230 LUTs until the shift amount
  was constrained to its reachable range of 0 to 16 — indexing with an
  unconstrained integer made the synthesiser build a far wider shifter than
  necessary. Further reduction there is the most promising area optimisation
  left.
* **WRITE holds no registers at all.** It is purely combinatorial: the ALU is
  combinatorial, and the Status Register shadow registers it used to carry were
  removed once they were shown to be dead — see
  [cpu_main/README.md](../src/cpu_main/README.md#Why-the-WRITE-stage-needs-no-Status-Register-bypass).

The two tables do not add up to each other (923 vs 873 LUTs). That is expected:
the first is measured after place-and-route, where physical optimisation
replicates logic to meet timing, while the second stops after synthesis. Slices
are not listed per module because slices are shared between modules and are not
attributable that way.
