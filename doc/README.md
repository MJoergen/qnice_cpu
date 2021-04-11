# A pipelined implementation of the QNICE CPU

## Architecture
This implementation is essentially a four-stage pipeline consisting of:

* FETCH: Fetches from the instruction memory and presents up to two words at a
  time to the DECODE stage.
* DECODE: Outputs a sequence of single micro-operations.
* PREPARE: Prepares the input operands for the ALU.
* WRITE: Contains the ALU and performs write-back of the result to register and/or memory.

See the following block diagram:

![Block Diagram](cpu.png)

The block diagram contains two additional blocks:
* Registers: Contains all the CPU registers and supports two read ports
  (connected to DECODE) and one write port (connected to WRITE).
* Memory: Interfaces to the Wishbone memory bus and supports two read ports
  (connected to PREPARE) and one write port (connected to WRITE).

The flow through the pipeline is that an instruction will spend one or two
clock cycles in the FETCH stage (two cycles if it uses an immediate operand),
and up to three clock cycles in the DECODE stage. The PREPARE stage waits for
any memory operands to be read, while the WRITE stage is purely combinatorial.

In the above we see a Harward architecture, where we have a separate
instruction and data interface. This main reason for this choice is to simplify
the implementation. It does also provide a nice side effect of increasing the
available memory bandwidth, because we can read from from instruction and data
memory simultaneously, see below section on [Interleaving](#Interleaving).

There is one important detail to note about the Harward architecture and that
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
* The DECODE stage may generate up to three clock cycles of data for the
  PREPARE stage. While doing so, it applies back-pressure to the FETCH stage.
* The Memory module will generate back-pressure while waiting for the result
  read from the memory bus. This is part of the Wishbone protocol and allows
  for an I/O device to take several clock cycles to respond.


## Detailed design description
For more detailed information about the design look here:
* [FETCH](../src/fetch/README.md)
* [Registers](../src/registers/README.md)
* [Memory](../src/memory/README.md)
* [DECODE/PREPARE/WRITE](../src/cpu_main/README.md)


## Wishbone
I think it's worh while to give here a short summary of the Wishbone protocol.
Any wishbone slave (e.g. the memory) must have the following signals.
```
wb_cyc_i   : out std_logic;
wb_stb_i   : out std_logic;
wb_stall_o : in  std_logic;
wb_addr_i  : out std_logic_vector(15 downto 0);
wb_we_i    : out std_logic;
wb_data_i  : out std_logic_vector(15 downto 0);
wb_ack_o   : in  std_logic;
wb_data_o  : in  std_logic_vector(15 downto 0)
```

A write transaction is indicated by the CPU asserting all three signals
`wb_cyc_i`, `wb_stb_i`, and `wb_we_i` simultaneously together with the address
and data signals `wb_addr_i` and `wb_data_i`. The signal `wb_stall_o` is used
to indicate the end of the transaction: When `wb_stall_o` is de-asserted the
slave has accepted the transaction.

A read transaction is indicated by the CPU asserting the two signals `wb_cyc_i`
and `wb_stb_i`, and de-asserting `wb_we_i`. Again the signal `wb_stall_o` is
used to indicate the end of the transaction: When `wb_stall_o` is de-asserted
the slave has accepted the transaction.  When the data is ready, the slave
drives the data onto `wb_data_o` and asserts the signal `wb_ack_o`.


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
small experiment, where I first have a sequence of identical instructions `MOVE
0x0000, R0` that each take two clock cycles, then a sequence of identical
instructions `MOVE @R0, @R1` that again take two clock cycles each. The final
part contains alternating instructions `MOVE 0x0000, R0` and `MOVE @R0, @R1`,
and this sequence of two instructions takes a total of three instructions to
execute. So the pair of instructions are faster than the sum of each individual
instruction, because the instruction and data memories are operating
simultaneously.

## Self-modifying codfe
TBD: What is possible, what is not possible. How big latency is required? Is it
enough to issue a branch instruction? Show some examples where it doesn't work
and where is does work.


## Optimizations
I have a few ideas for cycle optimizations at the moment:
* Make the fetch module not clear `wbi_cyc_o` at every branch. This will reduce
  the branch penalty by one clock cycle.


## TODO
* Add remaining formal verification.
* Add interrupts.


## Utilization

The current synthesis report shows the following utilization:

|   Name    | LUTs | Regs | Slices |
| --------- | ---- | ---- | ------ |
| FETCH     |   70 |  152 |    37  |
| DECODE    |   63 |   76 |    31  |
| PREPARE   |   52 |  129 |    71  |
| WRITE     |  427 |    0 |   148  |
| Registers |  132 |  142 |    66  |
| Memory    |   31 |   37 |    15  |
| --------- | ---- | ---- | ------ |
| TOTAL     |  777 |  536 |   260  |


