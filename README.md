# A pipelined implementation of the QNICE CPU

The reason for this implementation is to increase the performance of the QNICE
CPU, and to use techniques from formal verification to prove its correctness.

This version of the QNICE CPU (from the [QNICE-FPGA
project](https://github.com/sy2002/QNICE-FPGA)) is not a drop-in replacement,
for the following three reasons:
* This design uses the [Wishbone memory
  bus](https://zipcpu.com/doc/wbspec_b4.pdf).
* This design uses separate instruction and data interfaces.
* This design expects (at least) one clock cycle delay when reading from
  instruction and/or data memory.

However, it should be a simple operation to modify the QNICE-FPGA project to
support this implementation.

The overall idea of this implementation is to convert each
[instruction](https://github.com/sy2002/QNICE-FPGA/blob/master/doc/intro/qnice_intro.pdf)
into a sequence of micro-operations, such as:
* Read from memory to source operand buffer
* Read from memory to destination operand buffer
* Write to memory
* Write to register

The reason is that e.g. the instruction `ADD @R0, @R1` performs two memory
reads (from `@R0` and `@R1`) and one memory write (to `@R1`). Since only one
memory operation is possible in each clock cycle, such an instruction will
need to be serialized and will take a total of three clock cycles.

## Documentation
Please go to the [doc](doc) directory for more in-depth description of the
architecture and the design.

## Makefile
The current makefile supports the following targets:
* `make sim`        : Run simulation, then open the waveform in gtkwave
* `make system.bit` : Run synthesis using Vivado
* `make synth`      : Run synthesis using yosys
* `make formal`     : Run formal verification
* `make clean`      : Remove all generated files

By default these assemble and run [`test/prog.asm`](test/prog.asm); pass
`TEST=<name>` to pick one of the other programs in [`test/`](test).

### Reading a simulation result

Two things will mislead you on a first run:

* **Every run ends in an error.** The disassembler terminates the simulation
  with `report "HALT" severity failure`, so GHDL exits non-zero and `make`
  prints `Error 1` whether the test passed or failed.
* **Reaching `HALT` does not mean the test passed.** Most of the test programs
  contain many `HALT` instructions, and the self-checking `prog.asm` branches to
  one on every failed sub-test. A run is judged by *which address* it halted at.

[`test/README.md`](test/README.md) lists the success address for each program,
and describes the stronger golden-output check against `test/writes.txt`.

### Instruction fetch throughput

`G_PAUSE_SIZE` in [`src/fetch/fetch_cache.vhd`](src/fetch/fetch_cache.vhd) can
throttle the instruction stream. It is set to `0` — no pauses. It was held at
`-8` for a long time to work around pipeline bugs, which drained the pipeline
between instructions so that no data hazard could arise; setting it negative
again is a quick way to check whether a failure belongs to that class. See
[Instruction stream throttle](src/fetch/README.md#Instruction-stream-throttle).

