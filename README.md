# A pipelined implementation of the QNICE CPU

[![test](https://github.com/MJoergen/qnice_cpu/actions/workflows/test.yml/badge.svg)](https://github.com/MJoergen/qnice_cpu/actions/workflows/test.yml)
[![formal](https://github.com/MJoergen/qnice_cpu/actions/workflows/formal.yml/badge.svg)](https://github.com/MJoergen/qnice_cpu/actions/workflows/formal.yml)

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
* `make test`       : Run all test programs headless; this is the CI entry point
* `make check`      : Run a single test program headless
* `make run`        : Run a single test program without the golden comparisons
* `make sim`        : Run simulation, then open the waveform in gtkwave
* `make golden`     : Regenerate the `test/*.{writes,stats}.golden` files
* `make system.bit` : Run synthesis using Vivado
* `make utilization`: Refresh `doc/README.md`'s numbers (needs Vivado)
* `make synth`      : Run synthesis using yosys
* `make diagrams`   : Re-render every `.tex` diagram to `.png` (needs pdflatex)
* `make formal`     : Run formal verification
* `make lint`       : Check every VHDL file against `CODING_STYLE.md` (needs vsg)
* `make clean`      : Remove all generated files

By default these assemble and run [`test/prog.asm`](test/prog.asm); pass
`TEST=<name>` to pick one of the other programs in [`test/`](test).

### Reading a simulation result

`make test` exits 0 if and only if every test passed, so it can be run
unattended. The thing that could otherwise mislead you is that **reaching
`HALT` does not mean the test passed** — most of the test programs contain many
`HALT` instructions, and the self-checking `prog.asm` branches to one on every
failed sub-test.

So the verdict is not inferred from where the program stopped. Each program
states it, by writing a status word to the reserved address `0x1FFF` just before
its final `HALT`; `test/test_monitor.vhd` reads that off the bus and ends the
simulation with the matching exit code. A `HALT` reached without such a write —
which is every failure `HALT` — fails the run, as does never reaching a `HALT`
at all. On top of that, `make test` compares the log of every register and
memory write against a committed reference copy.

[`test/README.md`](test/README.md) describes both checks in full.

CI runs `make test`, `make formal` and `make lint` on every push to `main` and
every pull request, as three independent workflows so that each can go red on
its own: [`test.yml`](.github/workflows/test.yml) builds the QNICE assembler
from the upstream project (only `qasm` and `qasm2rom` are needed, not the whole
toolchain) and points the Makefile at it with `ASSEMBLER=<path>`;
[`formal.yml`](.github/workflows/formal.yml) takes SymbiYosys, Yosys with the
GHDL plugin, GHDL and the SMT solvers from a pinned
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) release; and
[`lint.yml`](.github/workflows/lint.yml) runs VSG from a pinned release. The two
badges above are `test.yml` and `formal.yml`.

