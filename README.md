# A pipelined implementation of the QNICE CPU

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

Please go to the [doc](doc) directory for more in-depth descrition of the
arhictecture and the design.

## Makefile
The current makefile supports the following targets:
* `make sim`        : Run simulation
* `make system.bit` : Run synthesis using Vivado
* `make synth`      : Run synthesis using yosys
* `make formal`     : Run formal verification
* `make clean`      : Remove all generated files

The simulation and synthesis options assemble and run the test program in
[`test/prog.asm`](test/prog.asm).

