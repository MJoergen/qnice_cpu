# Interrupts: the design record

Interrupts are implemented: `INT`, `RTI`, and hardware entry through the
`irq_valid_i`/`irq_ready_o`/`irq_addr_i` port. **How they work is described in
[doc/README.md](README.md#interrupts)**, and the request port in
[src/interrupt/README.md](../src/interrupt/README.md). This note is what is left
of the design note the work was planned in: the upstream sources and how they
were ranked, where they disagree, each decision and why it was taken, the test
cases, and what changed between the plan and the implementation. It is kept
because every one of those decisions was argued, and someone revisiting one
should not have to re-derive the argument.

One feature is still open, and it is recorded in the [TODO](README.md#todo)
list: `EXC` is not implemented. Four limits are known and accepted, each
described where it belongs:

* **No adaptation layer exists.** A QNICE-FPGA system needs one to use this
  CPU's interrupts, and nothing here builds or tests one. `test/tb_upstream.vhd`
  has its mirror image, a device on this port in front of upstream's CPU; see
  [src/interrupt/README.md](../src/interrupt/README.md#what-the-adaptation-layer-has-to-do).
* **Withdrawal is verified formally, not in simulation.** No test program
  withdraws a request; see [Withdrawal](#withdrawal-and-what-allowing-it-would-cost).
* **The formal interrupt properties are bounded.** `cpu_main` has no `prove`
  task; see [Formal verification](#formal-verification).
* **Masking takes effect later than upstream.** Software that masks interrupts
  through an external register can still be interrupted after the instruction
  that masks; see [Masking](#masking-and-why-it-lands-later-than-upstream).

## Requirements

Sources, in the upstream [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA)
repository, on branch **`develop`**. That is the branch this repo tracks, for the
ISA as well as the tools; it is not that repository's default, which is why the
CI workflow pins it with a `ref:`.

Getting this branch wrong was the most expensive mistake available, and it was
made twice: an early reading came from `dev-cpu-pipeline`, an experimental
branch, and the one that replaced it from `dev-V1.61`, which predates upstream's
interrupt work. Between `dev-V1.61` and `develop` the reference grew a shadow
register file, the emulator grew shadow registers and an `EXC` implementation,
and both the ISA document and the programming card gained `EXC`. Check
`git branch --show-current` in the QNICE-FPGA checkout before trusting anything
below.

* `doc/intro/qnice_intro.tex` — the Interrupts slides; the programmer's model.
* `doc/int-device.md` — the daisy-chain bus protocol. The definitive source on
  that protocol, but no longer a specification of anything inside this CPU; see
  [The interrupt request interface](#the-interrupt-request-interface).
* `doc/programming_card/programming_card.tex` — a one-page ISA summary with an
  `Interrupts` section of its own. Terse, and it disagrees with the slides.
* `doc/best-practices.md` — the rules ISR *authors* are told to follow, which
  bound how much the saved-state divergence can cost.
* `vhdl/qnice_cpu.vhd` and `vhdl/register_file.vhd` — what the reference CPU
  actually does, which is not in every respect what the slides say.
* `emulator/qnice.c` and `assembler/qasm.c` — the other two implementations. The
  assembler is decisive on encoding, since the test programs go through it.

Cite these **by symbol** — `SP_org`, `cs_int_wait_isr`, the `ctrlRTI` arm,
`fsm_output_decode` — never by line number. Every line number an earlier draft
carried had gone stale.

DECISION: When external evidence is contradicting, use the following priority:
1. Ground truth is ISA (documented in doc/intro/qnice_intro.tex)
2. For questions not answered in the ISA document, the definitive source is then
   doc/int-device.md.
3. For behaviour specified in neither document, the reference implementation
   (`vhdl/qnice_cpu.vhd`, `vhdl/register_file.vhd`) is the fallback. It ranks
   below both documents, never above them.
4. If there are any discrepancies between any of these external sources, then
   list them clearly, and document the implemented choice. See
   [Where the sources disagree](#where-the-sources-disagree) below.

Two riders on that ranking. The programming card is a document, but it is a
*summary* document: it ranks between rules 2 and 3, and loses to the slides
wherever the two disagree. And rule 1 makes the slides ground truth about
*intent*, not about encoding — they get the control-instruction field layout
flatly wrong, and on a bit position the assembler wins, because a bit position
is only true if the toolchain agrees.

### Where the sources disagree

Applying rule 4, derived against **`develop`**.

**`EXC` — the ISA document contradicts itself, and only the reference CPU is
silent.** The instruction table lists `EXC const, dst — Exchange shadow
register`; the control-command bit table three slides later stops at
`000100 DECRB` and gives `EXC` no encoding at all. Everything else except the
hardware knows it. The programming card says what it is for: on an interrupt
"the CPU saves the contents of `R8` to `R15` in eight shadow registers which can
be accessed with the `EXC` instruction". The assembler emits control command `5`
and takes a constant of 0..31. The emulator implements it, and halts on a shadow
register number above 7. The reference CPU's `vhdl/cpu_constants.vhd` stops at
`ctrlDECRB`, so the encoding falls into the `Ctrl_Cmd` case's `when others` arm,
commented "illegal command: HALT". **Implemented choice: `EXC` is out of scope,
and its arm of `p_unimplemented` stays armed** — see
[below](#exc-is-out-of-scope-and-that-is-not-a-shortcut).

**`INT`'s operand field — the ISA document contradicts itself twice, and the
destination field wins.** The instruction table says `INT dst`. The
control-command table says the address is "supplied by the source operand", and
the Interrupts slide says it again one sentence after writing the opposite: "A
software interrupt is triggered by `INT <dst op>`. The source operand contains
the address of the ISR." Everything else agrees on the destination: the
instruction table, the programming card, the reference CPU (which switches on
`Dst_Mode` and uses `reg_read_data2`), the emulator, and — decisively — the
assembler, which ORs `dest_op_code` into bits 5..0. **Implemented choice: the
destination field.**

*Why* the slides say "source" twice is a third error and a live trap. The
control-instruction slide states that "the command to be executed is specified
by bits **5..0** of the instruction". The assembler builds a control word as

```c
0xe000 | ((opcode & 0x3f) << 6) | (dest_op_code & 0x3f)
```

and the reference CPU decodes `Ctrl_Cmd <= Instruction(11 downto 6)`. The command
sits in bits **11..6**, the operand in bits **5..0**. In the slide's own
(incorrect) frame, the field left over at 11..6 *is* the source field. This
design has it right — `subtype R_CTRL_CMD is natural range 11 downto 6` in
`src/cpu_constants.vhd` — but anyone implementing `INT` from the ISA document
alone decodes the wrong field. `INT <constant>` assembles to **two words**.

**Saved state — three sources say `R8`-`R15` and only the slides say two.**

| Source | Saved and restored |
|---|---|
| `qnice_intro.tex`, the Interrupts slide (rule 1) | `R14`, `R15` — "two invisible latches" |
| `programming_card.tex`, `Interrupts` section | `R8` to `R15`, "in eight shadow registers" |
| `vhdl/register_file.vhd` (rule 3) | `R8` to `R15` |
| `emulator/qnice.c` | `R8` to `R15` |

The reference register file has a shadow array, `shadow_en`, `shadow_spr_en` and
`revert_en` ports, and revert loops over `R8`-`R12` and `R13`-`R15`; the emulator
matches it (`NUMBER_OF_SHADOW_REGISTERS` is 8). Against `dev-V1.61` the table had
read differently — slides and emulator `R14`/`R15`, reference `R13`-`R15` — and
the decision was first taken on that evidence. **Implemented choice: `R14` and
`R15` only**, re-derived on this evidence and confirmed — see
[The decision to make first](#the-decision-to-make-first-what-state-is-saved).

**A request pending at a `HALT`.** Found by the differential test rather than by
reading: upstream's `cs_fetch` tests for a pending interrupt *before* it latches
the next instruction, so a request pending as the `HALT` comes up is taken and
the `HALT` never executes. This CPU takes a request only at the boundary after a
retiring instruction, and after a `HALT` there is none. Neither document
addresses the case. **Implemented choice: the `HALT` wins**;
`test/prog_int_halt.asm` is a known divergence against upstream's RTL.

### The interrupt request interface

The CPU's pins were first specified as upstream's `INT_N`/`IGRANT_N` daisy chain.
They are not.

DECISION: **this CPU does not have to be a pin-compatible drop-in replacement**,
and an adaptation layer around it is accepted. That is the same concession
already made twice over: the CPU is Harvard where the original is not, and speaks
Wishbone where the original speaks a bespoke bus, and the layer that reconciles
both exists — `env1.vhd` in the QNICE-FPGA tree, commit `cfb0893`, written up in
`doc/cpu_replacement.md` there. Interrupts get the same treatment.

DECISION: **the CPU is agnostic of daisy chaining.** Position-is-priority, the
grant pass-through, the wait-your-turn rules — all of it is an *optional*
implementation detail of the surrounding system.

DECISION: **the CPU sees exactly one interrupt-generating device**, in the same
way it sees exactly one memory on each of its other two buses. Arbitration
between several devices is not in the CPU.

DECISION: **the interface is three signals** — `irq_valid_i`, `irq_ready_o`,
`irq_addr_i` — a valid/ready handshake with the address as payload, the same
discipline every stage boundary in this design uses. It is AXI-stream except
that a device may withdraw a request; see
[Withdrawal](#withdrawal-and-what-allowing-it-would-cost).

DECISION: the ISR address arrives on a **port of its own**, `irq_addr_i`, not on
the data Wishbone. The address is not the result of any bus transaction, so
putting it on `wbd_data_i` would mean a Wishbone protocol violation, a mux
outside the CPU, or modelling the interrupt as a read from a reserved address.

DECISION: port names are lower case, per CODING_STYLE.md, and active high.

DECISION: Make a timing diagram (similar to src/cpu_main/timing.tex) that shows
the relationship between the important signals, and in particular which changes
are registered and which are combinational. **Done**: it was drawn first as the
specification of the planned module, and has since been redrawn from a
simulation of `test/prog_int_waveform.asm`; see
[src/interrupt/README.md](../src/interrupt/README.md#walking-the-diagram).

What dropping the daisy chain bought: no grant, so no address driven
combinationally off one — which had been the single place this design was
*tighter* than upstream, where a device may take any number of cycles between
grant and data; no shared address bus and its turnaround rules; and no
`int_wait`, the back-pressure WRITE needed while commit and redirect were two
cycles apart. The cost **moved, it did not vanish**: somebody still has to run
the chain, and in a QNICE-FPGA system that is the adaptation layer, whose
obligations are in
[src/interrupt/README.md](../src/interrupt/README.md#what-the-adaptation-layer-has-to-do).
Nothing in `make test` exercises a chain.

#### Withdrawal, and what allowing it would cost

**DECISION: a device may withdraw a request before it is accepted. This is
"Option A" below, and it is what `write.vhd` implements.**

The question arose because **upstream's own masking mechanism withdraws
requests.** The ISA has no CPU-side interrupt mask — the status register's `M`
and `I` bits are *commented out* in `qnice_intro.tex` — and masking is explicitly
external: "an extremely simple (optional) interrupt controller implemented as an
external device which allows to mask interrupts using a simple register and an
`AND`-gate". An `AND` gate on the request line drops a request on whatever cycle
software's write lands. A hold rule would have made that non-conforming.

The planned design registered the request into a leaf module (`pending_o`,
`addr_o`) and committed on the registered copy, which breaks under withdrawal in
three places: a request withdrawn during the commit cycle still enters an ISR; the
redirect has already flushed the pipeline by the time anything could re-check;
and a registered `irq_ready_o` lands a cycle later, into a device that has let go.
There were two ways to fix it:

* **Option A — pay timing, keep the cycle count.** Use `irq_valid_i` directly in
  the commit. Withdrawal is honoured at no latency cost, but a signal from outside
  CPU_MAIN enters the cone of `fetch_valid_o`, the reset pin of every flip-flop in
  DECODE and PREPARE.
* **Option B — pay one cycle, keep the topology.** Accept at the boundary, latch
  everything, and redirect a cycle later off a single register bit. `int_wait`
  returns for that cycle, since an instruction could otherwise retire between the
  saved PC and the redirect.

Implemented as Option A, the questions settle as consequences: nothing remembers a
request, so a withdrawn one is simply never seen; `irq_ready_o` is high only in a
cycle whose `irq_valid_i` is, by construction; and the address is read in the
cycle it is accepted, so an arbiter may switch devices freely. **Withdrawal is
not simulated**: `test/interrupt.vhd` holds its request until it is accepted,
so it never withdraws one, and the case is covered only by the formal
properties, whose request port is unconstrained (the cover `c_irq_withdrawn`
shows the solver reaches it). **The price**,
measured once the Interrupt Generator was synthesised so that the port is driven:
the request path itself has well over a nanosecond of slack, but the logic it
brings to life moved the placement enough that the clock constraint went from
7.70 to 7.80 ns.
And withdrawal **does not make masking behave as it does upstream**; see the
next section.

#### Masking, and why it lands later than upstream

Allowing withdrawal makes an external mask *legal*. It does not make it *prompt*,
and here this CPU diverges from upstream in a way a program can see.

**Upstream: no interrupt after the masking instruction.** QNICE-FPGA's mask is
`vhdl/interrupt_controller.vhd`, instantiated in `env1.vhd` between the CPU and
the daisy chain. It holds an enable bit and a block bit in a register, `ic_csr`,
and `int_n_o` is combinational in that register. Upstream's CPU is not
pipelined: an indirect store drives the bus in `cs_exepost_store_dst_indirect`,
the register takes the write on the clock edge that leaves that state, and the
next state is `cs_fetch`, which is where the CPU tests `INT_N`. So by the time
the instruction after the mask write could be interrupted, `INT_N` is already
masked. This is read off the RTL, not simulated.

**This CPU: at least one more boundary.** A request is taken as an instruction
retires, and the instruction that writes the mask retires in the cycle MEMORY
accepts its write request. In that cycle the write has at best just reached the
Wishbone bus, so the mask register still holds its old value and `irq_valid_i`
is still up: the boundary directly after the masking instruction is always
open. More boundaries open whenever the write waits behind the bus — a stalled
slave, or earlier requests still outstanding — because MEMORY buffers the write
and the instructions behind it go on retiring. A mask register that gates
`irq_valid_i` through a further register, or an adaptation layer that adds
latency after the mask, adds cycles too. How many instructions that is in a
real system has not been measured, and no test program masks.

**Why the CPU does not close it.** A CPU-side mask would give "no
interrupt after this instruction", but the ISA has none: the status register's
`M` and `I` bits are commented out in `qnice_intro.tex`. Holding back the
retire of every data write until the bus has acknowledged it would close the
window, at the cost of a bus round trip on every write, and it would still not
cover latency outside the CPU.

**What software can do.** Read the mask register back straight after writing
it. The Wishbone slave acknowledges in request order, and an instruction that
reads memory cannot retire before its read is acknowledged, so the read-back
retires only after the write has landed. Provided the path from the mask
register to `irq_valid_i` is combinational, no request is taken as the
read-back retires or after it; a request can still be taken at the boundaries
between the masking instruction and the read-back, so the read-back belongs
before the critical section, not inside it. This follows from how MEMORY and
WRITE work, but it has not been tested.

### Programmer's model

* **Interrupts do not nest.** A request is accepted only when no ISR is already
  running. The reference gates this on `Int_Active` in the `cs_fetch` arm of
  `fsm_output_decode`.
* **`R14` (SR) and `R15` (PC) are saved** into latches invisible to software.
  The reference and the emulator save `R8`-`R15`; this design follows the
  document. See [Where the sources disagree](#where-the-sources-disagree).
* **`RTI`** restores them, clears the in-ISR state, and resumes.
* **`INT <dst op>`** is a software interrupt; the destination operand supplies
  the ISR address, in any of the four addressing modes.
* **A rogue `RTI`** — one executed outside an ISR — halts the CPU (the `else` of
  `if Int_Active = '1'` in the reference's `ctrlRTI` arm). So does a **rogue
  `INT`**, one executed inside an ISR. The emulator halts on both too, printing a
  diagnostic that names each as "Rogue".

  DECISION: both halt, and both are documented as such. Note the provenance:
  neither the ISA document nor `int-device.md` says anything about either case,
  so this is rule 3 above — the reference implementation as fallback. It is also
  the only defined behaviour on offer anywhere, and it fails loudly, which is how
  this design already treats the rest of this area (`p_unimplemented`).

  DECISION, reaffirmed after hardware entry landed: **change the implementation
  so that both halt, and write the tests.** Done; how the stop works, and why it
  cannot use the `HALT` gate, is in
  [doc/README.md](README.md#interrupts).
* Bit 0 of the SR is always 1 (`alu_flags.vhd`). The reference forces it in the
  saved copy too.
* **An ISR must leave every register as it found it.** That is upstream's rule,
  from `doc/best-practices.md`: "When writing an interrupt service routine (ISR),
  make sure that you do not leave any register modified when calling `RTI`. You
  may use the stack." The same file lets ISR authors use register banks, and
  requires the bank selector to point at the highest active bank at all times, so
  that an ISR can safely `INCRB` on entry. The first rule bounds what saving only
  `R14`/`R15` can break; the second is what test case 7 exercises.

### `EXC` is out of scope, and that is not a shortcut

`EXC` is specified — the programming card says what it does, the assembler emits
it, and the emulator implements it — though it lacks an encoding in the ISA
document's table and any implementation in the reference CPU. It is out of scope
for a simpler reason: it exchanges a register with one of the eight shadow
registers an interrupt fills, so it is meaningless until those shadow registers
exist. It is part of the saved-state design, not an instruction that can be added
beside it. If the saved-state decision is ever revisited towards `R8`-`R15`,
`EXC` comes back into scope with it.

## The decision to make first: what state is saved

**DECISION: save `R14` and `R15` only — re-derived against `develop`, and
confirmed.**

On `develop` the reference register file and the emulator both save `R8`-`R15`,
and the programming card says so too; only the slides say two latches. So the
gap is six registers (`R8`-`R13`), and the decision rests on three things:

* **Rule 1.** The slides are ground truth, and they say `R14` and `R15`. Three
  sources outvoting them is exactly the situation the ranking exists for.
* **Cost.** `R8`-`R13` are ordinary banked registers in a
  [dp_ram.vhd](../src/sub/dp_ram.vhd)-backed file with one ordinary write port,
  and `RTI` already spends it: `R14` is restored through that port, and `R15`
  through the redirect to FETCH, in the one cycle `RTI` retires in. (The
  dedicated Status Register port fires on every retiring instruction and loses
  to the ordinary one.) Every further restore needs another cycle,
  and therefore micro-ops, turning `RTI` from a single-beat instruction into a
  sequenced one. The reference's model — a continuous mirror of the upper
  registers into shadow copies — cannot be built here at all: it needs a second
  writer into the same array, which the header of `dp_ram.vhd` explains cannot be
  inferred without a `shared variable`.
* **The divergence is invisible to a conforming ISR.** No ISR written to
  upstream's own best-practices rule can tell whether the CPU restores `R8`-`R13`
  as well. What breaks is an ISR that relies on upstream's shadow copies to
  clobber `R8`-`R13` freely, which that rule already forbids.

The consequence follows directly: `EXC` stays out of scope, because in this design
the shadow registers it exchanges do not exist.

## What changed between the plan and the implementation

The plan assumed several things that turned out wrong, each found by a test or a
proof rather than by review. Recorded so that the reasons for the code's shape
are not lost.

* **The return address is not `next_pc` for hardware entry.** `next_pc` is right
  for `INT`, and it is the value `RSUB` pushes. But a hardware interrupt is taken
  as an arbitrary instruction retires, and if that instruction is a taken branch,
  execution continues at the target. Likewise `R14` must be saved as the retiring
  instruction leaves it, not as it entered. Both were implemented as planned and
  both were bugs, caught by Tests 6H, 6I, and 6J in `test/prog_int_hw.asm`;
  `write.vhd` saves `resume_pc` and `irq_r14_next` instead, but only on hardware
  entry, since making them live for `INT` too cost measurable slack.
* **A request must not be taken at a retiring `HALT`.** The plan listed "check
  interrupt entry cannot un-gate a `HALT`" as a risk. It could: entry flushed the
  pipeline, which cleared `cpu.vhd`'s `HALT` gate, and the CPU ran the ISR past
  its own `HALT`. `test/prog_int_halt.asm` caught it only under `make test_slow`,
  and only after `test/test_monitor.vhd` learned to fail a run in which anything
  retires after the `HALT`.
* **`INT` and `RTI` are not JMP-shaped.** The plan had both reuse the branch
  path. `INT` is instead decoded as reading its destination operand, and entry and
  exit redirect through a term of their own on `fetch_valid_o`
  (`irq_sw_valid_s`). The `INT`/`RTI` decode is carried down the stage records
  from DECODE (`is_int`, `is_rti`), for the same timing reason as `is_crb`.
* **The leaf module was never built.** See
  [Withdrawal](#withdrawal-and-what-allowing-it-would-cost). The last design
  argument for it was keeping the pins out of CPU_MAIN's timing, and measured, the
  request path is not what limits it.
* **The timing budget was spent anyway.** T0 measured a fourth term on
  `fetch_valid_o` as free. Hardware entry nonetheless took the design from WNS
  +0.003 ns to −0.163 ns at 7.45 ns on a netlist that is logically unchanged, and
  the clock constraint was relaxed to 7.70 ns. Synthesising the Interrupt
  Generator, so that the path is driven and measurable, then failed at 7.70 ns
  (−0.054 ns) on the usual routing-dominated paths, while the request path had
  +1.343 ns; the constraint went to 7.80 ns. See
  [Utilization](README.md#utilization) and `hw/system.xdc`.
* **A rogue instruction cannot be stopped where a `HALT` is.** Whether an `RTI` or
  `INT` is rogue is only known as it retires, so WRITE stops the pipeline itself
  (`irq_halted`).
* **The formal properties found a bug of their own**: `irq_ready_o` was not held
  low during reset.

## Test cases

Written as self-checking `.asm` in the existing style. See
[test/README.md](../test/README.md).

Happy path:

1. `INT R0`, with `R0` holding the ISR address; the ISR sets a marker and
   `RTI`s. Checks the ISR is entered, runs once, and returns.
2. As above, but the instruction after `INT` increments a counter. Checks the
   return address is exact — that instruction must run **exactly once**, neither
   skipped nor repeated.
3. Set flags, `INT`, have the ISR deliberately clobber them, `RTI`. Checks `R14`
   is restored bit for bit.
4. Hardware path: the program writes the trigger address, the device asserts
   `irq_valid_i` with an ISR address. Checks the whole handshake, including that
   the device's request is released after `irq_ready_o`.
5. Request a second interrupt from inside an ISR. Checks it is **not** accepted
   until after the `RTI`.
6. Interrupt an instruction that is two words, e.g. `MOVE 0x1234, R0`. Checks
   the `+2` path of the return address. The reference handles the two-word
   `INT <constant>` explicitly: its `amIndirPostInc` arm bumps the *saved* PC so
   that `RTI` resumes after the constant word rather than on it.
7. `INT` immediately after `INCRB`, with an ISR that changes the bank. Checks
   the bank-change flush still holds across an interrupt.

Not happy path: rogue `RTI` and rogue `INT`, which halt.

Not a test at all: `test/prog_int_waveform.asm` is the program the timing
diagram in [src/interrupt/README.md](../src/interrupt/README.md) was read off. It
is in `TESTS` only so that a change invalidating the addresses and cycles the
diagram quotes fails the writes-log diff.

Where they live: cases 1, 2, 3, 6 (for `INT`), and 7 in `test/prog_int_sw.asm`;
cases 4, 5, and 6 in `test/prog_int_hw.asm`, together with edge cases the list
does not name (see its header); the pending-at-`HALT` case in
`test/prog_int_halt.asm`; and the rogue cases in `test/prog_int_rogue_rti.asm`
and `test/prog_int_rogue_int.asm`. All are in `TESTS`.

### Formal verification

The properties in [formal/cpu_main.psl](../formal/cpu_main.psl) cover both halves
a second way, in its "Interrupts: INT, RTI, and hardware entry" section.

The state an interrupt saves is invisible to software by design, and invisible to
the proof too: a `vunit` bound to `cpu_main` cannot see inside the WRITE instance.
So the properties are stated against a shadow model built from the instruction
encoding, the retire pulse, and the request pin — never from `irq_ready_o` —
which is what makes them a requirement rather than a transcription. The round
trip is checked against a return address the shadow computed cycles earlier.

* **Hardware entry** (task T9): taken at the first boundary it is present at, and
  redirected to `irq_addr_i` (`f_irq_entry`); and at no other time — only while
  requested, only at an instruction boundary and never in reset, never inside a
  service routine including at its `RTI`, and never at a `HALT`, `INT`, or `RTI`
  (`f_irq_ready_requested`, `f_irq_ready_boundary`, `f_irq_ready_not_nested`,
  `f_irq_ready_not_ctrl`). A request withdrawn before the boundary that would
  have taken it is reached by the cover `c_irq_withdrawn`, which is the only
  place withdrawal is exercised at all.
* **The round trip**: `f_rti_return` and `f_rti_restore_r14`, against state saved
  on `INT` and on hardware entry alike.
* **Rogue instructions** must not redirect, must pulse `halt_o`, and must leave
  the CPU doing nothing at all afterwards (`f_halted_quiet`).
* **The nested-`INT` property has to be asserted separately.** It does not follow
  from the round trip: the saved pair is latched on entry only, so a design that
  wrongly nested would still return to the outer address correctly. A mutation
  found this.

The request port is left **entirely unconstrained**, so the CPU is shown to need
no obligation from the device. That costs run time: `cpu_main`'s BMC task went
from about 4 to about 16 minutes. The properties were checked against the bugs
simulation found, by putting each back: saving `next_pc` instead of the branch
target fails `f_rti_return`, saving `R14` from before the instruction fails
`f_rti_restore_r14`, and taking a request at a `HALT` fails
`f_irq_ready_not_ctrl`. Withdrawal, which no simulation exercises, was checked
the same way: a CPU that remembers a request once seen, and so takes one that
was withdrawn, fails `f_irq_ready_requested` at step 3.

**All of this is bounded model checking, to depth 20, and not a proof.**
`formal/cpu_main.sby` has `bmc` and `cover` tasks but no `prove`
(k-induction) task, as the [TODO](README.md#todo) records for `cpu_main` as a
whole. So a property holds for every trace of 20 cycles from reset, and a
round trip deep enough to need more is not covered. The covers show how much
fits: the shortest hardware round trip is reached at step 6.

## How the work went

The task plan, one line per task. The task numbers are referred to elsewhere in
the tree.

* **T0. Timing spike.** A toggle flip-flop standing in for the entry term on
  `fetch_valid_o`, measured at commit `342ca31`: WNS +0.135 → +0.167 ns, i.e.
  below the noise floor. It did not predict what hardware entry later cost; see
  above.
* **T1. Interrupt source for the testbench.** `test/interrupt.vhd`,
  program-triggered through a countdown, so that an interrupt lands at the same
  instruction after unrelated pipeline changes and the golden files do not churn.
  All test programs were written up front, at this step, for review. It has since
  been synthesised too, as a listen-only tap on the data bus, so that the request
  path is placed and timed; see
  [test/CLAUDE.md](../test/CLAUDE.md#simulated-peripherals-the-interrupt-generator).
* **T2. `src/interrupt/interrupt.vhd`.** Never built; see
  [What changed](#what-changed-between-the-plan-and-the-implementation).
  `formal/interrupt.psl` verifies the test device instead.
* **T2b. Protocol timing diagram.** Drawn ahead of the implementation as the
  specification, redrawn twice as the interface changed, and finally read off a
  simulation.
* **T3-T6. Interrupt state, `RTI`, `INT`, and hardware entry**, in WRITE.
* **T7. Top-level ports** on `cpu.vhd` and `test/system.vhd`.
* **T8. The test programs**, all in `TESTS`.
* **T9. Formal properties** for hardware entry; see
  [Formal verification](#formal-verification).
* **T10. The trap**: the `RTI` and `INT` arms of `p_unimplemented` are gone; `EXC`
  and reserved opcode `0xD` remain.
* **T11. Documentation**: this trimming, the [Interrupts](README.md#interrupts)
  section in doc/README.md, and CLAUDE.md.
* **T12. Re-measure.** `make lint`, `make test`, `make test_slow`, and
  `make -C formal -k` all pass, and `make utilization` has been re-run with the
  Interrupt Generator synthesised, at 7.80 ns.
