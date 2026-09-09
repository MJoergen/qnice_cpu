# The CPU source tree

Everything the CPU is made of. This page is the map: what each file is, which
of them have a design write-up of their own, and where the three files that do
*not* — [`cpu.vhd`](cpu.vhd), [`cpu_constants.vhd`](cpu_constants.vhd) and
[`debug.vhd`](debug.vhd) — are described.

Twenty-two VHDL files, all **VHDL-2008**, all synthesised into the bitstream
except the two simulation-only pieces named below. The testbench, the memory
models and the test programs are not here; they are in
[`test/`](../test/README.md).

## The map

| Path | What it is | Write-up |
|---|---|---|
| [`cpu.vhd`](cpu.vhd) | Top level: wires the five blocks together | [below](#the-top-level) |
| [`cpu_constants.vhd`](cpu_constants.vhd) | Instruction encoding, microcode bits, the three pipeline records | [below](#the-shared-declarations) |
| [`debug.vhd`](debug.vhd) | Simulation-only log of every register and memory write | [below](#the-write-log) |
| [`fetch/`](fetch/README.md) | Wishbone instruction fetcher, one word at a time | [FETCH](fetch/README.md) |
| [`icache/`](icache/README.md) | Two-word buffer, so DECODE sees an instruction and its immediate together | [ICACHE](icache/README.md) |
| [`registers/`](registers/README.md) | Register file: 2 read ports, 1 write port, write-before-read | [REGISTERS](registers/README.md) |
| [`memory/`](memory/README.md) | Wishbone data-side arbiter and operand response buffers | [MEMORY](memory/README.md) |
| [`cpu_main/`](cpu_main/README.md) | DECODE, SEQUENCER, PREPARE, WRITE, the microcode ROM and the ALU | [the main pipeline](cpu_main/README.md) |
| [`sub/`](sub) | Reusable valid/ready primitives everything above is built from | [below](#the-building-blocks) |
| [`interrupt/`](interrupt/README.md) | **No VHDL yet** — a specification and a timing diagram | [interrupts](interrupt/README.md) |

The pipeline those pieces form, and the reasoning behind it, is
[doc/README.md](../doc/README.md); the block diagram is
[doc/cpu.png](../doc/cpu.png). Start there if you are reading the design rather
than looking for a file.

## The top level

`cpu.vhd` instantiates FETCH, ICACHE, REGISTERS, MEMORY and CPU_MAIN and names
the signals between them. It is mostly a wiring file, but four things happen
here and nowhere else:

* **The redirect mux.** FETCH sees one redirect port; two blocks drive it —
  WRITE when a branch retires, and DECODE when it resolves an unconditional
  immediate branch on the spot (see
  [Early redirect](cpu_main/README.md#early-redirect)). They cannot fire in the
  same cycle, but WRITE still takes priority in the mux rather than the two
  being OR-ed, so that the address does not depend on that exclusivity.
* **The hard/soft flush split.** `ic_rst` (from WRITE) and `ic_flush` (from
  DECODE) are separate signals because ICACHE must treat them differently: one
  withdraws what it is offering DECODE in the same cycle, the other must not.
  [The soft flush](icache/README.md#the-soft-flush) is where that is pinned
  down.
* **The HALT gate**, `p_halt_fetched`: a fetched HALT closes the
  ICACHE-to-DECODE handshake immediately, so the HALT is the last instruction
  to enter the pipeline as well as the last to retire. A flush clears it again,
  because a branch retiring can discard a HALT that was already accepted —
  `test/prog_pipeline.asm` branches over twelve of them.
* **`halt_o`**, the level "this CPU has executed a HALT", latched from the
  single-cycle pulse CPU_MAIN reports.

Three generics: `G_REGISTER_BANK_WIDTH` (no default; the Makefile passes 8) and
the two simulation-only ones, `G_WRITES_FILE` and `G_DEBUG`.

## The shared declarations

`cpu_constants.vhd` is one package, used by every module. It holds four
unrelated things:

* **The instruction format** as `subtype` ranges (`R_OPCODE`, `R_SRC_MODE`,
  `R_CTRL_CMD`, …) and the opcode, addressing-mode, branch-mode and status-bit
  constants. This is the ISA as this CPU reads it.
* **The microcode encoding**: the 4-bit ROM index (`C_READ_DST`, `C_WRITE_DST`,
  `C_MEM_SRC`, `C_MEM_DST`) and the 12 bits of a micro-op, both as bit numbers
  and as the `C_VAL_*` one-hot vectors the ROM is written in. What they mean is
  in [Microcoding of instructions](cpu_main/README.md#microcoding-of-instructions).
* **The three pipeline records** — `t_dec2seq`, `t_seq2prep`, `t_prep2wr`, one
  per link. They used to be a single record carrying the union of all three,
  with every early link leaving the later stages' fields undriven; three
  records mean a link cannot name an element that is not meaningful on it yet.
  The comment above them says which two elements deliberately change name
  rather than meaning in flight.
* **`disassemble`** and **`ctrl_str`**, used by `write.vhd` under `G_DEBUG` and
  by its unimplemented-instruction check.

## The write log

`debug.vhd` writes every register and memory write the CPU retires, in retire
order, to `G_WRITES_FILE`. It is instantiated inside `pragma synthesis_off` and
is absent from every bitstream; an empty file name disables it entirely.

It is not a debugging aid that happens to be checked in — it is an input to two
of the repo's five checks. `make check` diffs it against
`test/<prog>.writes.golden`, and `test/crosscheck.py` replays it to reconstruct
what this CPU left in memory and in the register file, to compare against
upstream. That second use is why a write to `R0`-`R7` carries the **bank** it
landed in: without it, "to register 3" names eight different registers over a
program's life. See
[Differential testing against upstream](../CLAUDE.md#differential-testing-against-upstream).

## The building blocks

`src/sub/` holds six small valid/ready ("AXI-style") primitives. FETCH,
REGISTERS, MEMORY and CPU_MAIN are built from them, which is what makes the
back-pressure in this design uniform rather than hand-written per stage.

| Module | Depth | Forward path | Backward path |
|---|---|---|---|
| `one_stage_buffer.vhd` | 1 | combinational when empty | combinational |
| `one_stage_fifo.vhd` | 1 | registered | combinational |
| `two_stage_buffer.vhd` | 2 | combinational when empty | combinational |
| `two_stage_fifo.vhd` | 2 | registered | combinational, gated by `rst_i` |
| `dp_ram.vhd` | — | registered, 1 cycle | n/a |
| `pipe_concat.vhd` | 0 | combinational | combinational |

Each file's header carries its own contract, and several of them document a
subtlety that is not visible from the instantiation: `s_afull_o` is occupancy
and not "not ready"; `two_stage_fifo`'s reset is asymmetric on purpose, so its
consumer must share `rst_i`; `dp_ram` has one address per port, and that is
load-bearing for RAM inference rather than an omission. Read the header before
reusing or modifying one. The set is summarised in
[CLAUDE.md](../CLAUDE.md#elastic-pipeline-building-blocks-srcsub), and
`dp_ram`'s two configurations are also discussed in
[test/README.md](../test/README.md).

## What is verified how

Twelve of the thirteen formal jobs in [`formal/`](../formal) are modules from
this tree: all six primitives in `sub/`, plus `icache`, `memory`, `sequencer`,
`registers`, `fetch` and `cpu_main`. Each has a `.psl` / `.sby` / `.gtkw`
triplet; `make formal` runs the lot. The thirteenth, `wb_mux`, is a testbench
component.

DECODE, PREPARE and WRITE have no job of their own — they are verified through
`cpu_main`, which is exactly why the three stages share one entity. `cpu.vhd`,
the ALU and the microcode ROM are covered only by simulation: the test suite,
the differential tests against upstream's emulator and RTL, and — for the
top-level wiring above — `test/prog_pipeline.asm` and the flush tests in
`test/prog_hazard.asm`.

Style is machine-checked over all of these by `make lint`; the rules are
[CODING_STYLE.md](../CODING_STYLE.md).
