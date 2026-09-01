# Test programs and how to tell whether they passed

This directory holds the testbench (`tb_cpu.vhd`), the memory models it needs
(`wb_dp_mem.vhd`, `system.vhd`), the test-result monitor
(`test_monitor.vhd`), and the QNICE assembly programs run against the CPU.

The memory model has two read ports and one write port: the instruction bus
(port A) reads, the data bus (port B) reads and writes. The program is loaded
through `G_INIT_FILE`, not over the bus. The array itself is
[`src/sub/dp_ram.vhd`](../src/sub/dp_ram.vhd) — the same module the register
file uses — and its header explains why it cannot have a second write port and
still be VHDL-2008 that Vivado will infer a RAM from.

```
make test                      # run every test program headless; this is the CI entry point
make check TEST=prog_r15       # run just one of them, same checks
make run   TEST=prog_r15       # run it without the writes-log comparison
make sim                       # assemble test/prog.asm, simulate, open gtkwave
make sim TEST=prog_interleave  # run test/prog_interleave.asm instead
make test READ_REG=false       # ...against a zero-latency memory instead
```

Every one of these exits 0 if and only if the test passed, so they can be run
unattended.

The `.asm` files are assembled by the external QNICE assembler at
`$HOME/git/sy2002/QNICE-FPGA/assembler/asm`, which must be checked out
separately. It emits a `.rom` (loaded by the testbench), a `.out`, and a `.lis`
listing that maps every instruction to its address.

## Pass criterion: the program reports its own verdict

**Reaching a `HALT` does not mean a test passed.** Reaching `HALT` is the only
way any of these programs ever terminates, and most of them contain many `HALT`
instructions scattered throughout — the self-checking test suite in `prog.asm`
branches to a nearby `HALT` on *every* failed sub-test.

So the verdict is not inferred from where the program stopped; the program
states it. Just before its final `HALT`, each program writes a **status word**
to the reserved address `0x1FFF`:

```asm
EXIT            MOVE    OK, R8
                MOVE    0x1FFF, R0      ; Test status word
                MOVE    0x0000, @R0     ; 0 = pass
                HALT
```

`test_monitor.vhd` snoops the data Wishbone bus for that write and ends the
simulation with an exit code:

| What the monitor saw                              | Result                          |
| ------------------------------------------------- | ------------------------------- |
| status word `0x0000`                              | `TEST PASSED`, exit code 0      |
| status word anything else                         | `TEST FAILED: status code 0x…`, exit code 1 |
| `HALT` reached, no status word ever written       | `TEST FAILED: HALT reached without a test status write`, exit code 1 |
| no `HALT` at all within `G_TIMEOUT` (2 ms)        | `TEST FAILED: no HALT within …`, exit code 1 (watchdog in `tb_cpu.vhd`) |

The third row is what makes the convention cheap: **every failure `HALT` is a
failure automatically**, with nothing written on the failure paths at all. So a
new test program only needs the two instructions above at its success exit, and
is treated as failing until it reaches them. Giving individual failure paths
their own status codes (`MOVE 0x0007, @R0` before the `HALT`) is optional, and
only sharpens the diagnostic.

When a test does fail, the address of the last disassembled `HALT` still tells
you *which* one was reached:

```
src/cpu_constants.vhd:238:13:@143550ns:(report note): 1696 (E000) HALT
                                                      ^^^^
```

Look that address up in the program's generated `.lis` file. Because the
addresses shift whenever a program is edited, they are deliberately no longer
recorded here.

Two details of the mechanism are worth knowing:

* `0x1FFF` is the top word of the 8 kW memory, and no test program uses it. It
  is an ordinary RAM location, not a decoded I/O register — the monitor watches
  the bus, so the write itself is harmless.
* A `HALT` now stops the CPU. `src/cpu.vhd` gates the Icache-to-DECODE
  handshake off as soon as a `HALT` is handed to DECODE (`p_halt_fetched`), so
  the `HALT` is the last instruction that ever enters the pipeline and the CPU
  idles instead of executing whatever data follows it in memory. Gating on the
  `HALT` *retiring* instead would be too late — one or two later instructions
  are already in the pipeline by then. Outstanding memory writes still drain,
  which is why the monitor waits `G_DRAIN_CYCLES` before deciding.

## What each program covers

`prog.asm` is the broad self-checking instruction suite; the other six are
narrow. `prog_simple.asm` walks the addressing modes of `MOVE`/`ADD`/`CMP` and
the branch instructions. `prog_pipeline.asm` and `prog_interleave.asm` exist to
exercise pipeline behaviour rather than instruction semantics — respectively a
`@R7++, @R7++` hazard and the throughput of interleaved instruction/data memory
accesses.

`prog_flags.asm` covers the ALU's *flags input* path, i.e. the value that
reaches `sr_i` in `src/cpu_main/sub/alu_flags.vhd` and `alu_data.vhd`. That path
is used as the carry-in of `ADDC`/`SUBC` and as the fill bits of `SHL`/`SHR`.

`prog.asm` already covers the *values* on that path well — its stimulus tables
run both polarities of the relevant bit (`STIM_ADDC` has 7 rows with C=0 and 7
with C=1, `STIM_SUBC` 6 and 6, and `STIM_SHL`/`STIM_SHR` sweep four SR-input
patterns each across 69 and 65 rows). Note when reading those tables that they
are split into blank-line-separated groups, so looking at only the first group
gives a misleading picture.

What `prog_flags.asm` adds is *timing*: it makes an instruction consume the
Status Register on the clock cycle right after another instruction produced it,
across several producer/consumer spacings and addressing modes, which is where
a stale flags value would show up:

* `T1`/`T2` — carry produced by `ADD`, consumed by the immediately following
  `ADDC`, for C = 1 and C = 0.
* `T3` — SR written through the ordinary register write port (`MOVE imm, R14`)
  and consumed by the next instruction.
* `T4`/`T5` — one and two instructions of spacing between producer and consumer.
* `T6` — `ADDC` with a memory source operand, so the consumer is a multi
  micro-op instruction that stalls on the memory read.
* `T7`/`T8` — differential `SUBC` and `SHR`: the same operands with the SR input
  bit clear and set must give different results.

`prog_r15.asm` covers `R15` used as an ordinary ALU operand. The working Program
Counter lives in the FETCH stage, so the register file's `R15` copy is stale
during sequential execution and PREPARE has to substitute the real PC; these
tests pin that down against the reference semantics in `qnice.c`, where a single
PC register is advanced right after the instruction fetch and both operands are
read through it:

* `T1` — `CMP R15, R15`: the source and destination read paths must agree. This
  is the differential probe that originally exposed the bug, when only the
  source path was being substituted.
* `T2` — `R15` as a source reads the address of the next instruction.
* `T3` — `ADD 0x0002, R15`, a PC-relative jump, which exercises `R15` as a
  destination on a two-word instruction (so the PC has already advanced past
  the immediate).
* `T4` — `@R15`, PC-relative memory addressing, which reaches the PC through a
  different path again: the WRITE stage derives the memory address from
  `src_val`, not from the ALU operand.

`prog_hazard.asm` covers read-after-write data hazards between *adjacent*
instructions: a register written and then read, used as a memory pointer, used
as both ALU operands, chained through four instructions; the Status Register
written and then consumed by a branch condition, read back as an ordinary
register, and read while a multi-micro-op instruction is in flight; a
post-increment pointer reused immediately; and the stack pointer written and
then used as a pre-decrement pointer.

`H11`-`H13` cover the register bank instead of a single register. `H11` and
`H12` switch banks — with `INCRB`/`DECRB` and with an ordinary write to `R14` —
and then read `R0` from the very next instruction, as source and as destination.
Both read the previous bank unless the bank switch flushes the pipeline, see
[Register bank switch](../src/cpu_main/README.md#Register-bank-switch); `H12` is
the case that silently copies one bank's value into another. `H13` writes `R14`
*without* changing the bank — the flag-setup idiom — and checks that `R0` still
reads back correctly afterwards. Note it cannot check that no flush happened:
the trigger is syntactic, so that write does flush, and the cost is invisible to
a self-checking program. Only the cycle count would show it.

`prog.asm` also has a `L_BANK_00` section checking that banking works at all —
`R0` is banked, `R8` is not, and a value survives a round trip. Its reads are
two or more instructions after their `INCRB`/`DECRB`, so it does *not* cover the
hazard above; that is what `H11`-`H13` are for. The exhaustive walk over all 256
banks that follows it is left commented out, since it dominates the simulation
time of the whole program.

`prog_self_modifying.asm` covers stores into the program's own instruction
stream. The hazard is that FETCH, the Icache, DECODE and PREPARE have all read
ahead of the instruction retiring in WRITE, so without the flush described in
[Self-modifying code](../src/cpu_main/README.md#Self-modifying-code) the *old*
instruction executes and nothing reports a problem.

* `T1`/`T2` — rewrite the opcode, and the immediate operand, of the very next
  instruction.
* `T4` — rewrite the instruction two ahead; the one in between must still run as
  originally written.
* `T5` — reach the instruction through a pre-decrement pointer, which is a
  different path to the store address in WRITE (`dst_val-1`, not `dst_val`).
* `T7` — patch an instruction inside a loop, so the hazard is hit on every one
  of three iterations.

Those five all fail without the RTL fix, checked by stashing it and running each
sub-test on its own. The remaining two are the opposite by design, and pass
either way:

* `T3` — store *outside* the flush window, where correctness comes from nothing
  having prefetched the address yet. This is the test that would notice if the
  window were ever sized below the real read-ahead depth.
* `T6` — store to data that merely happens to sit near the program counter. It
  costs a needless flush, which must not change what executes.

`prog_waveform.asm` is different in kind from the rest: it exists to *generate*
the pipeline timing diagram in
[src/cpu_main/README.md](../src/cpu_main/README.md#Waveforms). It is a straight
run of `ADD @R0++, @R0++` at address `0x0006` surrounded by `MOVE R1, R1`
padding, and that README quotes concrete addresses, register values and cycle
numbers read off a simulation of it. It is in `TESTS` so that a change which
invalidates those numbers — by shifting an address, or by changing how many
cycles the instruction takes — breaks the writes-log diff instead of silently
leaving the diagram wrong. Its own self-check is thin on purpose: that `R0` ends
up past both post-increments and that the sum `0x1234 + 0x2345 = 0x3579` landed
in memory. When it does need to change, re-read the values from a fresh
simulation and run `make timing`.

## Unimplemented instructions fail the run

Independently of the verdict protocol above, `p_unimplemented` in
[src/cpu_main/write.vhd](../src/cpu_main/write.vhd) kills the simulation if an
instruction retires that nothing in the CPU decodes:

```
write.vhd:132:13:@180ns:(assertion failure): UNIMPLEMENTED instruction at
address 0x0002: control command 01 (RTI). It is not decoded anywhere and would
otherwise retire as a no-op.
```

The list is currently the control commands `RTI`, `INT` and `EXC`, plus reserved
opcode `0xD`. It exists because the alternative is worse than useless: DECODE
classifies every CTRL instruction as having no operands and neither reading nor
writing its destination, so the microcode ROM hands back entry 0 — three bare
`C_VAL_LAST` — and `alu_flags` leaves the Status Register alone. Those
instructions therefore *execute as nothing*, and the assembler emits them
without complaint. A test program containing `RTI` used to pass.

It is a simulation-only check (`pragma synthesis_off`), and deliberately so:
QNICE defines no illegal-instruction exception, so there is nothing here the ISA
would have synthesised hardware do. Remove an arm of the check as its
instruction gains a real implementation.

## The golden writes-log comparison

`src/cpu.vhd` instantiates `src/debug.vhd` (inside a `pragma synthesis_off`
block), which logs every register write and every Wishbone memory write to the
file named by the `G_WRITES_FILE` generic. `make` points that at
`test/<program>.writes`, and the committed `test/<program>.writes.golden` next
to it is the output of a passing run.

`make check` (and therefore `make test`) diffs the two, so a run has to produce
the exact same sequence of writes, in the same order, as well as reporting a
pass. That catches regressions the program's own self-checks do not — a write
that lands at the right value but in the wrong order, or an extra write nobody
asserts on.

When a change to the CPU or to a test program is *meant* to change the writes,
regenerate the reference copies with

```
make golden
```

and read the resulting `git diff` carefully — these files are the regression
check, so a diff that is not fully understood is a bug report, not noise.
`make golden` regenerates the statistics reference copies described below at the
same time.

For `prog.asm` there is one further human-readable signal: the instruction just
before the successful exit sequence is `MOVE OK, R8`, which loads `R8` with a
pointer to the string `"OK\n"`.

## The statistics comparison

The writes log catches changes in *behaviour*. It says nothing about
performance: a change that makes the CPU flush twice as often produces an
identical writes log and passes CI green. That is not hypothetical — three
recent changes each added a pipeline flush, and each one was measured by hand,
once, and then never again.

So `test/test_monitor.vhd` also counts four things per run and writes them to
the file named by `G_STATS_FILE`, which `make` points at
`test/<program>.stats`:

```
cycles: 15811
instruction memory requests: 13484
data memory requests: 1848
simultaneous requests: 1822
```

`cycles` runs from the release of reset up to and including the cycle the `HALT`
retires. A "request" is an accepted Wishbone beat — `cyc and stb and not
stall` — so a stalled request counts once rather than once per cycle it is held,
and it is the cycle the slave *takes* the request, not the cycle the data comes
back. `simultaneous requests` counts cycles in which both buses accepted a beat.

`make check` diffs this against the committed `test/<program>.stats.golden`
exactly as it does the writes log, so a performance change is now as loud as a
behavioural one. Nothing here decides pass or fail on its own — a program that
got slower still passes its own self-checks — it just produces a diff that has
to be explained. Regenerate with `make golden`.

### Zero-latency memory (`READ_REG=false`)

`READ_REG` selects how [`wb_dp_mem.vhd`](wb_dp_mem.vhd) answers. The default,
`true`, is an ordinary pipelined slave: the ACK comes a cycle after the request
is accepted. `false` makes it a **zero-latency slave** — combinational ACK, read
data valid in the same cycle — which is what exercises the same-cycle paths in
the two bus masters, [Memory](../src/memory/README.md#Zero-latency-ACKs) and
[FETCH](../src/fetch/README.md#Zero-latency-ACKs). The generic runs all the way
down to `G_READ_REG` in [`dp_ram.vhd`](../src/sub/dp_ram.vhd), which removes the
read output registers; both halves have to move together, or the ACK would
announce data that has not arrived.

The two modes split the golden files asymmetrically, and the asymmetry is the
point:

* **`<program>.writes.golden` is shared.** A zero-latency memory changes *when*
  data arrives, never *what* it is, so the writes log must be byte-identical in
  both modes. It is, for all nine programs. That is the real correctness check
  on the whole zero-latency path — and it is why `make golden READ_REG=false`
  deliberately does *not* refresh it.
* **`<program>.stats_zerolat.golden` is separate.** Cycle counts legitimately
  differ, so they get their own reference. `make test READ_REG=false` checks
  against it, and `make golden READ_REG=false` regenerates it.

The measured effect on `prog.asm` is 15070 cycles down to 13511, **−10.3%**,
with the instruction- and data-request counts unchanged. Per program the range
is −0.4% (`prog_flags`, almost all ALU work) to −18.5% (`prog_interleave`, which
is dominated by memory operands).

The mode is synthesisable, and the memory stays a Block RAM — but only because
`dp_ram` moves port B's *write* to the falling edge along with its read. Stage
only the read and the port wants two clocks at once, which Vivado cannot build:
it reports `[Synth 8-6849] Infeasible attribute ram_style = "block"` and drops
the 8Kx16 array into 4096 LUTRAMs. The measured comparison, including that
wrong turn, is in [`wb_dp_mem.vhd`](wb_dp_mem.vhd)'s header. Nothing
synthesised in this repo sets `READ_REG=false` regardless; the default is what
the shipping bitstream is built from.

#### It is a net loss on wall time

Fewer cycles is not the same as less time, and this is the case where the
distinction bites. **The zero-latency memory is about 29% SLOWER in wall-clock
terms**, because the clock it can close at falls further than the cycle count
does.

Measured with Vivado 2022.2 on `xc7a100tcsg324-1`, full place-and-route with
the same directives the shipping build uses, at commit `a04aa90`:

| | closes at | fails at | period | frequency | LUTs |
| --- | --- | --- | --- | --- | --- |
| `READ_REG=true` | 7.45 ns (+0.121) | 7.40 ns (−0.014) | **7.45 ns** | 134 MHz | 927 |
| `READ_REG=false` | 10.70 ns (+0.005) | 10.60 ns (−0.131) | **10.70 ns** | 93.5 MHz | 896 |

At the shipping 8.50 ns constraint the zero-latency build misses by
**WNS −1.084 ns with 189 failing endpoints**. Multiplying cycles by period:

| program | cycles | wall, registered | wall, zero-latency | wall |
| --- | --- | --- | --- | --- |
| `prog` | −10.3% | 112.27 µs | 144.57 µs | **+28.8%** |
| `prog_interleave` | −18.5% | 0.40 µs | 0.47 µs | +17.0% |
| `prog_flags` | −0.4% | 1.85 µs | 2.64 µs | +43.0% |
| all nine | −9.9% | 120.17 µs | 155.48 µs | **+29.4%** |

Zero latency would need to close at **8.27 ns** to break even overall, or
equivalently to remove **30.4%** of cycles at the clock it does reach. The best
any program manages is 18.5%, and that is `prog_interleave`, the one most
dominated by memory operands. There is no program in the suite for which the
trade pays.

Two notes on reading those numbers. The periods were found by bracketing —
building at successive constraints until the design stops closing — not by
extrapolating from WNS at 8.50 ns, which is badly optimistic here: `−1.084` at
8.50 implies 9.58 ns, and the design actually needs 10.70. And the placement
noise this design shows (±0.284 ns, see [doc/README.md](../doc/README.md)) is
larger than the bracket step, so read the periods as ~7.4–7.5 and ~10.6–10.8.
The 3.25 ns gap between them is an order of magnitude beyond that noise.

**The Block RAM fix is not what costs the clock**, which is worth knowing before
trying to win the time back by undoing it. The superseded LUTRAM variant —
asynchronous port B, write left on the rising edge, so no half-period path at
all — closes at 10.50 ns using 5950 LUTs. Same clock, six times the area, and
its critical path is a full-period path inside PREPARE rather than anything in
the memory. The ~10.5–10.7 ns floor is the cost of the combinational ACK
reaching into PREPARE; the falling-edge write is worth about 0.2 ns of it and
saves ~5000 LUTs.

So `READ_REG=false` earns its keep as a **verification** configuration — it is
what exercises the same-cycle paths in both bus masters against a slave that
really is one — and not as a performance option.

### What the numbers say about the Harvard split

Instruction and data memory are separate Wishbone interfaces backed by one
dual-port RAM (see [doc/README.md](../doc/README.md)), so the fourth counter is
a direct measure of what that split buys. Every simultaneous request is a cycle
a single-ported design would have had to serialise. For `prog.asm`:

| | |
| --- | --- |
| cycles | 15811 |
| instruction requests | 13484 (85% of cycles) |
| data requests | 1848 |
| ...of which simultaneous | 1822 (**98.6%** of data requests) |

Almost every data access collides with an instruction fetch, which follows from
the instruction bus being busy 85% of the time. Serialising them would cost at
least 1822 extra cycles, i.e. **+11.5%**, and in practice more, since each
inserted stall also delays whatever was behind it in the pipeline. That is a
lower bound in a second sense too: it counts only the collisions that actually
happened in a machine built not to have to avoid them.

The ratio is not uniform across the programs. `prog_flags.asm` is almost pure
register arithmetic (2 data requests in 271 cycles) and gains nothing;
`prog_interleave.asm` is the store-heavy one (21 data requests in 54 cycles,
17 of them simultaneous) and gains most.

One caveat on the instruction count: fetches are speculative, so a flush
discards work that has already been requested. The instruction-request count
therefore includes fetches that were never executed, and it rises when flushes
become more frequent — which is exactly what makes it worth watching.
