# Test programs and how to tell whether they passed

This directory holds the testbench (`tb_cpu.vhd`), the memory models it needs
(`tdp_ram.vhd`, `wb_tdp_mem.vhd`, `system.vhd`), and the QNICE assembly programs
run against the CPU.

```
make sim                       # assemble test/prog.asm, simulate, open gtkwave
make sim TEST=prog_interleave  # run test/prog_interleave.asm instead
make test/tb_cpu.ghw           # same, but without launching gtkwave afterwards
```

The `.asm` files are assembled by the external QNICE assembler at
`$HOME/git/sy2002/QNICE-FPGA/assembler/asm`, which must be checked out
separately. It emits a `.rom` (loaded by the testbench), a `.out`, and a `.lis`
listing that maps every instruction to its address.

## Pass criterion: check the HALT address

**A simulation that stops at `HALT` has not necessarily passed.** Reaching
`HALT` is the only way any of these programs ever terminates, and most of them
contain many `HALT` instructions scattered throughout — the self-checking test
suite in `prog.asm` branches to a nearby `HALT` on *every* failed sub-test.

The pass criterion is therefore **the address of the `HALT` that was reached**,
which the disassembler prints as the last instruction line of the run:

```
src/cpu_constants.vhd:238:13:@837960ns:(report note): 1692 (E000) HALT
                                                      ^^^^
```

| Program                | Success address | Notes                                                                       |
| ---------------------- | --------------- | --------------------------------------------------------------------------- |
| `prog.asm`             | `0x1692`        | The `HALT` after the `EXIT` label at `0x1690`. Every other `HALT` is a failed sub-test, reachable only via an `E_*` error label. |
| `prog_simple.asm`      | `0x0027`        | Reached by returning from the `ASUB L_3` at the end. The three earlier `HALT`s are branched over. |
| `prog_pipeline.asm`    | `0x0015`        | The first `HALT` after `L_START`. The twelve `HALT`s at `0x0004`-`0x000F` are padding that must be jumped over. |
| `prog_interleave.asm`  | `0x001E`        | The only `HALT` in the program, so here reaching `HALT` at all is sufficient. |

If you add a program, find its success address in the generated `.lis` file and
add a row here.

## The simulation always reports a failure

The `disassemble` procedure in `src/cpu_constants.vhd` ends the run with

```vhdl
report "HALT" severity failure;
```

so GHDL exits non-zero and `make` prints `Error 1` on **every** run, passing or
failing:

```
src/cpu_constants.vhd:258:10:@837960ns:(report failure): HALT
ghdl:error: report failed
make: *** [Makefile:87: test/tb_cpu.ghw] Error 1
```

That trailing error is expected and says nothing about the result. Read the
`HALT` address on the line above it instead.

For `prog.asm` there is one further signal: the instruction just before the
successful `HALT` is `MOVE OK, R8`, which loads `R8` with a pointer to the
string `"OK\n"`.

## `writes.txt` as a golden-output check

`src/cpu.vhd` instantiates `src/debug.vhd` (inside a `pragma synthesis_off`
block), which logs every register write and every Wishbone memory write to
`test/writes.txt`. The copy committed to git is the output of a passing
`TEST=prog` run, so after

```
make test/tb_cpu.ghw
git diff --quiet test/writes.txt && echo PASS
```

an empty diff is a much stronger regression check than the `HALT` address alone
— it confirms the CPU produced the exact same sequence of writes, in the same
order.

Note that the file is rewritten by *every* simulation run, so running any
`TEST=` other than the default `prog` will leave a large spurious diff in your
working tree. Re-run `make test/tb_cpu.ghw` with the default program to restore
it.
