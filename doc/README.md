# A pipelined implementation of the QNICE CPU

## Architecture
This implementation is essentially a four-stage pipeline consisting of:

* FETCH: Fetches from the instruction memory and presents up to two words at a
  time to the DECODE stage.
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
stage is combinatorial apart from a small set of shadow registers used for
bypassing (`p_bypass` in [write.vhd](../src/cpu_main/write.vhd)); the ALU itself
is entirely combinatorial.

In the above we see a Harvard architecture, where we have a separate
instruction and data interface. This main reason for this choice is to simplify
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
  for an I/O device to take several clock cycles to respond.

Both are exercised at full instruction fetch throughput; the `axi_pause`
throttle that used to suppress them is now set to zero, see
[Instruction stream throttle](../src/fetch/README.md#Instruction-stream-throttle).


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

## Self-modifying code
TBD: What is possible, what is not possible. How big latency is required? Is it
enough to issue a branch instruction? Show some examples where it doesn't work
and where is does work.


## Optimizations
I have a few ideas for cycle optimizations at the moment:
* Make the fetch module not clear `wbi_cyc_o` at every branch. This will reduce
  the branch penalty by one clock cycle.


## TODO
* Formal verification: the suite in `formal/` currently passes in full (twelve
  modules, thirty-five tasks). What is still missing is `fetch_cache.vhd`, which
  has no job at all; a `prove` (k-induction) task for `cpu_main`; and closing the
  last open property of `memory`'s inductive proof.
* Add interrupts.


## Utilization

A synthesis run reported the following utilization:

|   Name    | LUTs | Regs | Slices |
| --------- | ---- | ---- | ------ |
| FETCH     |   70 |  152 |    37  |
| DECODE    |   63 |   76 |    31  |
| PREPARE   |   52 |  129 |    71  |
| WRITE     |  427 |    0 |   148  |
| Registers |  132 |  142 |    66  |
| Memory    |   31 |   37 |    15  |
| TOTAL     |  777 |  536 |   260  |

**These figures are stale and should be regenerated** (`make system.bit`, then
read the utilization report). Specifically:

* WRITE is listed with 0 registers, which predates the `p_bypass` shadow
  registers now in [write.vhd](../src/cpu_main/write.vhd).
* The LUT column sums to 775, not the 777 shown, so either a row is out of date
  or a couple of LUTs of top-level glue are unaccounted for.
* Slice counts are not additive -- slices are shared between blocks -- so the
  total being smaller than the sum of the rows is expected, not an error.
* No tool version, part number or date was recorded, and no report is checked
  in, so none of this can be re-verified as it stands.


