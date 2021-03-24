# A pipelined implementation of the QNICE CPU

This version of the QNICE CPU (from the QNICE-FPGA project) is not a drop-in
replacement, for the following three reasons:
* This design uses the Wishbone memory bus.
* This design uses separate instruction and data interfaces.
* This design expects (at least) one clock cycle delay when reading from
  instruction and/or data memory.

However, it should be a simple operation to modify the QNICE-FPGA project to
support this implementation.

The overall idea of this implementation is to convert each instruction into a
sequence of micro-operations, such as:
* Read from memory to source operand buffer
* Read from memory to destination operand buffer
* Write to memory
* Write to register

The reason is that e.g. the instruction `ADD @R0, @R1` performs two memory
reads (from `@R0` and `@R1`) and one memory write (to `@R1`). Since only one
memory operation is possible in each clock cycle, such an instruction will
need to be serialized and will take a total of three clock cycles.


## Architecture
This is essentially a three-stage pipeline consisting of:

* FETCH: Fetches from the instruction memory and presents up to two words at a
  time to the DECODE module.
* DECODE: Outputs a sequence of single micro-operations.
* EXECUTE: Executes one micro-operation.

See the following block diagram:

![Block Diagram](doc/cpu.png)


## Interleaving
Analyzing the timing of a QNICE assembly program is not simple, due to the
pipeline architecture. Some instructions - like `MOVE 0x0000, R0` are limited
by the bandwidth of the instruction memory, while other instrucions - like
`MOVE @R0, @R1` are limited by the bandwidth of the data memory.

What this means is that the instruction `MOVE 0x0000, R0` need only take one
clock cycle to execute, but it needs to read two words from the instruction
memory. On the other hand the instruction `MOVE @R0, @R1` needs at least two
clock cycles to execute, but only reads one word from instruction memory.

In the file `test/prog_interleave.asm` I conduct a small experiment, where I
first have a sequence of idential instruction `MOVE 0x0000, R0` that each take
two clock cycles, then a sequence of identical instructions `MOVE @R0, @R1`
that again take two clock cycles each. The final part contains alternating
instructions `MOVE 0x0000, R0` and `MOVE @R0, @R1`, and this sequence of two
instructions take a total of three instructions to execute. So the pair of
instructions are faster than each individual instruction.


## Makefile
The current makefile supports a number of different targets:
* `make sim`        : Run simulation"
* `make system.bit` : Run synthesis using Vivado"
* `make synth`      : Run synthesis using yosys"
* `make formal`     : Run formal verification"
* `make clean`      : Remove all generated files"


## Optimizations
I would like to make the instruction cache combinatorial. This will reduce the
latency through the module, thus improving the performance of branches.


## TODO
* Add remaining formal verification.
* Add interrupts.
* Timing optimizations.


## Utilization

|   Name    | LUTs | Regs | Slices |
| --------- | ---- | ---- | ------ |
| Fetch     |   83 |  152 |    57  |
| Decode    |   73 |   76 |    37  |
| Execute   |  524 |    0 |   190  |
| Registers |  110 |  141 |    65  |
| Memory    |   43 |   37 |    43  |
| TOTAL     |  833 |  406 |   280  |


