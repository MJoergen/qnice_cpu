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
make sim                              # assemble test/prog.asm, run GHDL simulation, open gtkwave
make sim TEST=prog_interleave         # run a different test program (test/<name>.asm)
make sim REGISTER_BANK_WIDTH=8        # override register bank address width (default 8)
make system.bit                       # Vivado synthesis + bitstream (needs Vivado at $XILINX_DIR)
make synth                            # Yosys synthesis (ghdl -a, then yosys -m ghdl synth_xilinx)
make formal                           # run all formal verification (delegates to formal/Makefile)
make clean                            # remove all generated files, including formal/ outputs
```

Test programs live in `test/*.asm` and are assembled with the external QNICE assembler at
`$HOME/git/sy2002/QNICE-FPGA/assembler/asm` (must be checked out separately; path is hardcoded in
the top-level `Makefile`).

### Formal verification

`make formal` runs `make -C formal`, which uses SymbiYosys (`sby`) with the GHDL plugin to
bounded-model-check the module(s) listed in the `DUTS` variable at the top of
[formal/Makefile](formal/Makefile). **Only one DUT is typically uncommented at a time** — check
that file before running to see what's active, and comment/uncomment lines there to change scope.
To run/inspect a single module directly:

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
Wishbone bus, via `stall`/`ack`). Two independent sources of back-pressure exist: DECODE can emit
up to three cycles of micro-ops per fetched instruction (stalling FETCH), and the Memory module
stalls PREPARE while waiting on the Wishbone bus.

Instruction and data memory are separate interfaces (Harvard-style) but backed by the same
physical dual-port RAM, since a program must be loadable and then executable from the same memory.
The Program Counter (`R15`) lives entirely inside FETCH and is *not* part of the register file;
`R14` (Status Register) is handled specially in the register file (written alongside any regular
register write at the end of most instructions); `R13` (Stack Pointer) is an ordinary register,
handled in DECODE.

### Microcode / instruction decomposition

The core trick of this design: DECODE dynamically translates each CISC-like QNICE instruction into
1-3 RISC-like micro-operations via a combinational ROM (`src/cpu_main/sub/microcode.vhd`), indexed
by a 4-bit classification of the instruction (reads-from-dst / writes-to-dst / src-in-memory /
dst-in-memory). The `Sequencer` (`src/cpu_main/sub/sequencer.vhd`) then issues that list of
micro-ops one per clock cycle. This exists because an instruction like `ADD @R0, @R1` needs two
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
[src/registers/README.md](src/registers/README.md#Operation)).

### Directory layout

- `src/cpu_constants.vhd` — shared constants/types used across modules.
- `src/fetch/` — instruction fetch + `icache.vhd`/`fetch_cache.vhd`.
- `src/registers/` — register file (dual-port RAM based, write-before-read).
- `src/memory/` — Wishbone-facing memory arbiter (source/destination operand buffers).
- `src/cpu_main/` — DECODE, PREPARE, WRITE, and the `sub/` microcode ROM, sequencer, ALU.
- `src/sub/` — reusable low-level building blocks (buffers, FIFOs, dual-port RAM, `pipe_concat`)
  shared across the above; most have their own formal verification in `formal/`.
- `src/cpu.vhd` — top-level entity tying FETCH, Registers, Memory, and `cpu_main` together.
- `test/` — testbench (`tb_cpu.vhd`), memory models, and `.asm` test programs.
- `hw/` — Vivado XDC constraints / synthesis TCL (generated).
- `formal/` — one `.psl`/`.sby`/`.gtkw` triplet per formally-verified module.
- `doc/` — architecture overview and block diagram source (`cpu.drawio`/`cpu.png`).
