# Interrupts

Design note for a feature that is **not implemented yet**. It records what the
ISA requires, which parts of this pipeline already fit, the one behavioural
question that has to be answered before any code is written, and the order the
work should happen in. Nothing here is measured yet except where it says so.

## What exists today

Nothing decodes `RTI`, `INT`, or `EXC`. Without help they would retire as silent
no-ops: DECODE classifies every CTRL instruction as no-operand/no-read/no-write,
the microcode ROM returns entry 0, and `alu_flags` leaves the SR alone through
its `when others => null`. The assembler emits them regardless — `RTI` is
`0xE040`.

`p_unimplemented` in [write.vhd](../src/cpu_main/write.vhd) turns that into a
simulation failure instead, so a half-finished implementation cannot look like a
working one. Drop each arm of that check as its instruction gains a real
implementation, and not before.

## Requirements

Sources, in the upstream [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA)
repository, on branch **`develop`**. That is the branch this repo tracks, for the
ISA as well as the tools; it is not that repository's default, which is why the
CI workflow pins it with a `ref:`.

Getting this branch wrong is the single most expensive mistake available in this
note, and it has now been made twice. An early reading came from
`dev-cpu-pipeline`, an experimental branch; the reading that replaced it came
from `dev-V1.61`, which is real but predates upstream's interrupt work. Between
`dev-V1.61` and `develop` the reference grew a shadow register file, the emulator
grew shadow registers and an `EXC` implementation, and both the ISA document and
the programming card gained `EXC` — so two of the four disagreements recorded
under [Where the sources disagree](#where-the-sources-disagree) reverse outright.
Check `git branch --show-current` in the QNICE-FPGA checkout before trusting
anything below.

* `doc/intro/qnice_intro.tex` — the Interrupts slides; the programmer's model.
* `doc/int-device.md` — the daisy-chain bus protocol. Still the definitive
  source on that protocol, but it is no longer a specification of anything
  inside this CPU; see
  [The interrupt request interface](#the-interrupt-request-interface).
* `doc/programming_card/programming_card.tex` — a one-page ISA summary with an
  `Interrupts` section of its own. Terse, and it disagrees with the slides.
* `doc/best-practices.md` — the rules ISR *authors* are told to follow, which
  turn out to bound how much the divergence below can cost.
* `vhdl/qnice_cpu.vhd` and `vhdl/register_file.vhd` — what the reference CPU
  actually does, which is not in every respect what the slides say.
* `emulator/qnice.c` and `assembler/qasm.c` — the other two implementations. The
  assembler is decisive on encoding, since the test programs go through it.

Cite these **by symbol** — `SP_org`, `cs_int_wait_isr`, the `ctrlRTI` arm,
`fsm_output_decode` — never by line number. Every line number an earlier draft of
this note carried had gone stale, in both directions: some pointed at the wrong
line of the right file, and some pointed at code that only ever existed on
`dev-cpu-pipeline`.

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

Two riders on that ranking, both earned below. The programming card is a
document, but it is a *summary* document: it ranks between rules 2 and 3, and
loses to the slides wherever the two disagree. And rule 1 makes the slides ground
truth about *intent*, not about encoding — they get the control-instruction field
layout flatly wrong, and on a bit position the assembler wins, because a bit
position is only true if the toolchain agrees.

### Where the sources disagree

Applying rule 4 above. What follows is the full list, re-derived against
**`develop`**, which is the branch this repo follows.

An earlier pass derived it against `dev-V1.61` and got two of the four items
backwards, because upstream did substantial interrupt work between the two. Both
are corrected below and both reverse: `EXC` is no longer assembler-only, and the
saved-state disagreement is wider than it looked, not narrower. The other two
items — `INT`'s operand field and the bit-numbering error behind it — were
re-checked against `develop` and are unchanged.

**`EXC` — the ISA document contradicts itself, and only the reference CPU is
silent.** The instruction table lists `EXC const, dst — Exchange shadow
register`; the control-command bit table three slides later stops at
`000100 DECRB` and gives `EXC` no encoding at all. So the document names an
instruction it never encodes.

Everything else except the hardware knows it. The programming card names it and
says what it is for: on an interrupt "the CPU saves the contents of `R8` to `R15`
in eight shadow registers which can be accessed with the `EXC` instruction". The
assembler emits control command `5` and takes a constant of 0..31. The emulator
implements it — `EXC const, dst` exchanges shadow register `const` with the
destination operand, and halts on a shadow register number above 7. The one
source that does not is the reference CPU: `vhdl/cpu_constants.vhd` still defines
`ctrlHALT`, `ctrlRTI`, `ctrlINT`, `ctrlINCRB` and `ctrlDECRB` and stops there, so
the encoding falls into the `Ctrl_Cmd` case's `when others` arm, commented
"illegal command: HALT".

This reverses what this note said when it was derived against `dev-V1.61`, where
`EXC` really was assembler-only: the instruction-table line came in with commit
`19a1657`, "Added EXC instruction to qnice_intro", which is an ancestor of
`develop` but not of `dev-V1.61`, and the emulator's implementation and the
programming card's wording arrived over the same period. **Implemented choice:
unchanged — `EXC` is out of scope and its arm of `p_unimplemented` stays armed —
but the reasoning is now the opposite of "nobody has specified it".** See
[below](#exc-is-out-of-scope-and-that-is-not-a-shortcut).

**`INT`'s operand field — the ISA document contradicts itself twice, and the
destination field wins.** The instruction table says `INT dst`. The
control-command table says the address is "supplied by the source operand", and
the Interrupts slide says it again one sentence after writing the opposite: "A
software interrupt is triggered by `INT <dst op>`. The source operand contains
the address of the ISR."

Everything else agrees on the destination: the instruction table, the programming
card ("the ISR address is specified by the `dst` part of the instruction"), the
reference CPU (which switches on `Dst_Mode` and uses `reg_read_data2`), the
emulator (which reads `destination_mode`/`destination_regaddr`), and —
decisively, since the test programs go through it — the assembler, which ORs
`dest_op_code` into bits 5..0. **Implemented choice: the destination field.**

*Why* the slides say "source" twice is worth writing down, because it is a third
error and a live trap. The control-instruction slide states that "the command to
be executed is specified by bits **5..0** of the instruction". That is wrong. The
assembler builds a control word as

```c
0xe000 | ((opcode & 0x3f) << 6) | (dest_op_code & 0x3f)
```

and the reference CPU decodes `Ctrl_Cmd <= Instruction(11 downto 6)`. The command
sits in bits **11..6**, the operand in bits **5..0**. In the slide's own
(incorrect) frame, with the command in 5..0, the field left over at 11..6 *is*
the source field — `Src_RegNo` at 11..8, `Src_Mode` at 7..6. So one bit-numbering
error explains both "source operand" sentences.

This design already has it right: `src/cpu_constants.vhd` declares
`subtype R_CTRL_CMD is natural range 11 downto 6`. That is exactly why the error
belongs in this list rather than being quietly ignored — anyone implementing
`INT` from the ISA document alone decodes the wrong field, and rule 1 points them
straight at it.

Worth knowing alongside all this: `INT <constant>` assembles to **two words**, so
`INT` can itself be a two-word instruction. That interacts with `next_pc` and
gets its own test case.

**Saved state — three sources say `R8`-`R15` and only the slides say two.**
This is the item that moved most between the branches, and it moved against the
decision recorded below.

| Source | Saved and restored |
|---|---|
| `qnice_intro.tex`, the Interrupts slide (rule 1) | `R14`, `R15` — "two invisible latches" |
| `programming_card.tex`, `Interrupts` section | `R8` to `R15`, "in eight shadow registers" |
| `vhdl/register_file.vhd` (rule 3) | `R8` to `R15` |
| `emulator/qnice.c` | `R8` to `R15` |

The reference register file is 231 lines with a shadow array, `shadow_en`,
`shadow_spr_en` and `revert_en` ports, and two revert loops — `for regnr in 8 to
12` and `for regnr in 13 to 15`. The emulator matches it exactly:
`NUMBER_OF_SHADOW_REGISTERS` is 8, an interrupt copies `read_register(16 - 8 + i)`
into the shadow array, and `RTI` copies it back.

**This reverses the previous reading of this item, and with it the argument for
the decision below.** Against `dev-V1.61` the table read: slides `R14`/`R15`,
programming card `PC`/`SP`, reference CPU `R13`/`R14`/`R15` (as `SP_org`,
`SR_org`, `PC_org` inside the CPU rather than in the register file), emulator
`R14`/`R15`. On that evidence the slides and the emulator agreed and the note
chose `R14`/`R15`. On `develop` the emulator no longer agrees with the slides:
three of the four sources say `R8`-`R15`, and rule 1 is the only thing still
pointing the other way.

The earlier draft's description of a register file that continuously mirrors the
upper registers into shadow copies was therefore right about `develop` and wrong
only about `dev-V1.61`. **The decision below has not been re-derived on this
evidence** — it is left as it stands, marked, for whoever starts the interrupt
work.

### The interrupt request interface

**REVISED, and this is the largest revision this note has taken.** Everything
under this heading previously specified upstream's `INT_N`/`IGRANT_N` daisy
chain directly on the CPU's pins. It no longer does. The decisions below replace
it; the ones they supersede are listed at the end of the section so that the
argument is not simply deleted.

DECISION: **this CPU does not have to be a pin-compatible drop-in replacement**,
and an adaptation layer around it is accepted. That is not a new concession, it
is the same one already made twice over: the CPU is Harvard where the original is
not, and speaks Wishbone where the original speaks a bespoke bus, and the layer
that reconciles both exists and works — `env1.vhd` in the QNICE-FPGA tree, commit
`cfb0893`, written up in `doc/cpu_replacement.md` there. Interrupts get the same
treatment. What this buys is room to design an interface in the same style as the
rest of this repo rather than one dictated by a 1990s-shaped bus.

DECISION: **the CPU is agnostic of daisy chaining.** Position-is-priority, the
grant pass-through, the wait-your-turn rules — all of it is an *optional*
implementation detail of the surrounding system. Nothing in `src/` knows the
chain exists.

DECISION: **the CPU sees exactly one interrupt-generating device**, in the same
way it sees exactly one memory on each of its other two buses. If several
interrupt-capable devices are connected, some arbitration mechanism must exist;
it is not in the CPU.

DECISION: **the interface is three signals** — `irq_valid_i`, `irq_ready_o`,
`irq_addr_i` — and is exactly an AXI-stream handshake:

1. The device asserts `irq_valid_i` and presents the ISR address on `irq_addr_i`
   in the same clock cycle.
2. It holds both steady until accepted.
3. The CPU asserts `irq_ready_o` for one clock cycle to accept.
4. The device de-asserts `irq_valid_i` after that.

This is the valid/ready discipline every stage boundary in this design already
uses, so it introduces no protocol and no vocabulary of its own. The cycle-level
version — which signal moves on which edge, and which are registered — is the
diagram and its walkthrough in
[src/interrupt/README.md](../src/interrupt/README.md).

There is still no way to abort a request: once a device has asserted
`irq_valid_i` it must hold it until accepted, and the address must still be valid
then. That is inherited from upstream's daisy chain, where a device that had
asked could not be un-asked, and it is the strongest obligation this interface
places on a device. It is also the one most likely to have to change — see
[Withdrawal, and what allowing it would cost](#withdrawal-and-what-allowing-it-would-cost)
below.

#### Withdrawal, and what allowing it would cost

**OPEN, deliberately deferred to T2.** The question is whether a device may
de-assert `irq_valid_i` before it is accepted, the use case being software that
masks an interrupt in the window between the request and the CPU taking it.

**Upstream's own masking mechanism is a device that would violate the hold
rule.** The ISA document has no CPU-side interrupt mask: the status register's
`M` bit ("if set to 1, maskable interrupts are allowed") and its `I` bit are both
*commented out* in `qnice_intro.tex`. Masking is explicitly external — "an
extremely simple (optional) interrupt controller implemented as an external
device which allows to mask interrupts using a simple register and an
`AND`-gate". An `AND` gate on the request line drops the request on whatever
cycle software's write lands, which is exactly what the hold rule forbids. So
this is not a hypothetical relaxation: it is upstream's documented way of
masking, and today it would be non-conforming in front of this CPU.

**Where it breaks if the rule is simply dropped.** Three places, all from one
root — the CPU commits on a registered copy of valid, and redirects before it
accepts:

1. `pending_o` is a one-cycle-stale copy of `irq_valid_i` and the commit term
   reads it, so a device that withdraws during the commit cycle still gets an ISR
   entered.
2. The redirect is *in* the commit cycle. By the time anything could re-check
   valid, `fetch_valid_o` has flushed DECODE and PREPARE and FETCH is refilling
   from `addr_o`. There is nothing left to cancel.
3. `irq_ready_o` is registered off `start_i` and so lands the cycle after — a
   ready pulse into a device that is no longer asserting valid, which is the CPU
   violating its own side of the handshake.

Note what that last one shows about CPU obligation 3 in
[src/interrupt/README.md](../src/interrupt/README.md#the-contract) ("only while
`irq_valid_i` is high"): it holds today *only because* the device is forbidden to
withdraw. The two clauses are load-bearing on each other.

**Two ways to fix it, costing different currencies.** Everything turns on whether
`irq_valid_i` reaches `fetch_valid_o` combinationally.

* **Option A — pay timing, keep the cycle count.** Use `irq_valid_i` directly in
  the commit term instead of `pending_o`. Withdrawal is then honoured at no
  latency cost and needs nothing else. But it puts a signal from outside CPU_MAIN
  into the cone of `fetch_valid_o`, the reset pin of every flip-flop in DECODE
  and PREPARE, at a current WNS of +0.017 ns. T0 measured that fourth term as
  free using *a free-running toggle flip-flop*, deliberately, because a register
  output is what the topology assumed; an entity input is not what was measured.
  Re-measure before believing it, and see
  [The critical path](README.md#the-critical-path) on why logic nowhere near a
  path can still move it.
* **Option B — pay one cycle, keep the topology.** Split the commit from the
  redirect. At the boundary, assert `irq_ready_o` as `inst_done_o and pending_o
  and not int_active and irq_valid_i` — combinational in the pin, but reaching
  only an output port and a register enable, never `fetch_valid_o` — and latch
  `R14`, `next_pc`, the address, `int_active`, and an `accepted` bit. Redirect
  the next cycle off `accepted`, which is a single register bit and therefore a
  *simpler* fourth term than the product used today. The cost is precisely what
  dropping the daisy chain bought back: **`int_wait` returns**, one cycle of it,
  because an instruction in PREPARE could otherwise retire between the saved PC
  and the redirect and `RTI` would replay it. Interrupt entry goes from four
  cycles to five — latency only, no throughput effect.

**One cost falls on either option.** `addr_o` would have to be captured at the
accept rather than free-running. It is a continuous copy of `irq_addr_i` today,
which is safe only because valid cannot withdraw; once it can, an arbiter may
switch devices between two cycles with valid never going low, and a one-cycle
stale address then belongs to the wrong device.

**It does not close the race it is meant to close.** Software's mask write
retires in WRITE, crosses the data Wishbone, updates the device register, and
only then drops the pin — several cycles, at any boundary of which the CPU may
commit. `MOVE 0, @MASK` followed by anything can still take the interrupt either
way. Allowing withdrawal narrows the window by one cycle and stops the CPU
committing to requests it can already see have gone away; it does not give
software "no interrupt after this instruction". Only a CPU-side mask does that,
and the ISA has one commented out, which reads like the question was weighed
upstream and dropped.

**Why it is safe to defer.** The relaxation is *strictly widening*: every device
that satisfies the hold rule satisfies the weaker one unchanged. No device
written against the current contract can be stranded by deciding this later, and
deciding it later means deciding it against a measurement of Option A rather than
an argument about one. **Provisional decision: keep the hold rule for T2, with
Option B the favourite if it is revisited.**

DECISION: the ISR address arrives on a **port of its own**, `irq_addr_i`, not on
the data Wishbone. This decision survives the rewrite and is now easier to
defend, not harder: the address is not the result of any bus transaction at all,
so putting it on `wbd_data_i` would mean a Wishbone protocol violation, a mux
outside the CPU, or modelling the interrupt as a read from a reserved address.
A dedicated port avoids all three and costs nothing this design has to defend.

DECISION: port names are lower case, per CODING_STYLE.md, and active high. The
`_n` suffixes are gone with the pins they described.

DECISION: Make a timing diagram (similar to src/cpu_main/timing.tex) that shows
the relationship between the important signals, and in particular which changes
are registered and which are combinational.

**DONE — see [src/interrupt/README.md](../src/interrupt/README.md).** The diagram
is [src/interrupt/timing.tex](../src/interrupt/timing.tex), rendered by
`make diagrams`, and the module README next to it carries the cycle-by-cycle
walkthrough and the contract as five obligations on the device and five on the
CPU. Everything on the CPU side of the boundary is registered; the one exception,
`start_i`, is named as such. Read that page before writing `interrupt.vhd` — the
diagram is the specification now, since it was drawn ahead of the implementation
rather than off a simulation.

#### What this supersedes

Recorded rather than deleted, because each of these was argued at length above
this line in an earlier draft and someone will otherwise re-derive them.

* **"The grant lasts exactly one cycle and the address is sampled at the end of
  it."** Gone: there is no grant. `irq_ready_o` is an accept, and it carries no
  data phase.
* **"A device must drive `isr_addr_i` combinationally off the grant."** Gone,
  and this is the one that matters most. It was the single place this design was
  *tighter* than upstream's own prose — upstream lets a device take any number of
  cycles between grant and valid data, and the reference CPU's `cs_int_wait_isr`
  spins waiting for exactly that — so a conforming upstream device that
  registered its address output would have been broken here. With the address
  arriving alongside the request, the divergence disappears rather than being
  documented.
* **"The address cannot precede the grant."** Reverses outright. That was true of
  a *shared* address bus, where a device that has not been granted must not drive
  the lines and devices further right are free to request mid-transaction. Point
  to point, there is nobody to collide with, so the address can and does
  accompany the request.
* **"The device need not release the bus combinationally."** Moot; there is no
  shared bus to release.
* **"Commit, then grant, then redirect: two cycles."** Gone. The address is
  already in a register when WRITE decides to take the interrupt, so the redirect
  happens in the commit cycle. With it goes `int_wait`, the back-pressure WRITE
  needed to stop an instruction retiring inside that two-cycle window (T3).
* **Port names `int_n_i`, `igrant_n_o`, `isr_addr_i`.** Replaced by
  `irq_valid_i`, `irq_ready_o`, `irq_addr_i`.

Be clear about where the cost went: **it moved, it did not vanish.** Somebody
still has to run the daisy chain, and in a QNICE-FPGA system that somebody is the
adaptation layer. What the split buys is that the chain's awkward parts — a data
phase that follows its own grant, a capture window one cycle wide, an address bus
several devices can drive — are now outside a design whose timing margin is
measured in hundredths of a nanosecond, and outside the formal proofs. The
layer's obligations are enumerated in
[src/interrupt/README.md](../src/interrupt/README.md#what-the-adaptation-layer-has-to-do).

### Programmer's model

* **Interrupts do not nest.** A request is accepted only when no ISR is already
  running. The reference gates this on `Int_Active` in the `cs_fetch` arm of
  `fsm_output_decode`, before the fetched word is taken as an instruction.
* **`R14` (SR) and `R15` (PC) are saved** into latches invisible to software.
  The reference saves `R13` as well; this design follows the document. See
  [Where the sources disagree](#where-the-sources-disagree).
* **`RTI`** restores them, clears the in-ISR state, and resumes.
* **`INT <dst op>`** is a software interrupt; the destination operand supplies
  the ISR address. The reference accepts all four addressing modes — the
  `Dst_Mode` case inside the `ctrlINT` arm.
* **A rogue `RTI`** — one executed outside an ISR — halts the CPU (the `else` of
  `if Int_Active = '1'` in the `ctrlRTI` arm). So does a **rogue `INT`**, one
  executed inside an ISR (the `else` of `if Int_Active = '0'` in the `ctrlINT`
  arm). The emulator halts on both too, printing a diagnostic that names each as
  "Rogue".

  DECISION: both halt, and both are documented as such. Note the provenance:
  neither the ISA document nor `int-device.md` says anything about either case,
  so this is rule 3 above — the reference implementation as fallback. It is also
  the only defined behaviour on offer anywhere, and it fails loudly, which is
  how this design already treats the rest of this area (`p_unimplemented`).
  Because it is a deliberate choice rather than a documented requirement, say so
  where a reader will find it: in the `write.vhd` header, in
  [test/README.md](../test/README.md) next to the other ways a run can fail, and
  in the two test programs that exercise it.
* Bit 0 of the SR is always 1. This design already does that, in `alu_flags.vhd`
  (`sr_o <= sr_i or X"0001"`). The reference forces it in the saved copy too —
  it mirrors `SR(15 downto 1) & "1"` into `SR_org`, not `SR` verbatim.
* **An ISR must leave every register as it found it.** That is not this design's
  rule, it is upstream's, from `doc/best-practices.md`: "When writing an
  interrupt service routine (ISR), make sure that you do not leave any register
  modified when calling `RTI`. You may use the stack." The same file tells ISR
  authors they may use register banks, and requires the bank selector in the
  upper eight bits of the SR to point at the highest active bank at all times, so
  that an ISR can safely `INCRB` on entry. Both facts matter here: the first
  bounds what saving only `R14`/`R15` can break, and the second is what test
  case 7 exercises.

### `EXC` is out of scope, and that is not a shortcut

The evidence is under
[Where the sources disagree](#where-the-sources-disagree), and it is not the
evidence this section used to give. `EXC` is specified: the programming card says
what it does, the assembler emits it, and the emulator implements it. What it
still lacks is an encoding in the ISA document's control-command table and any
implementation in the reference CPU, whose `cpu_constants.vhd` stops at
`ctrlDECRB`.

It is out of scope here for a simpler reason than "nobody specified it". `EXC`
exchanges a register with one of the eight shadow registers an interrupt fills,
so it is meaningless until those shadow registers exist — it is part of the
saved-state design, not an instruction that can be added beside it. Keep its arm
of `p_unimplemented` armed, along with reserved opcode `0xD`, and drop only the
`RTI` and `INT` arms. If the saved-state decision is ever revisited towards
`R8`-`R15`, `EXC` comes back into scope with it.

## The decision to make first: what state is saved

> **REOPENED — read
> [Where the sources disagree](#where-the-sources-disagree) first.** Everything
> below was decided against `dev-V1.61`, where the reference CPU saved
> `R13`/`R14`/`R15` and the emulator saved `R14`/`R15`. On `develop`, the branch
> this repo follows, the reference register file and the emulator both save
> `R8`-`R15` and the programming card says so too, so the gap is eight registers
> rather than one and the emulator no longer corroborates the slides. The
> argument below is preserved as written because its *cost* reasoning still
> holds — a third restore still needs a second write port and therefore a
> micro-op, and the `R8`-`R15` model still cannot be built as a continuous
> mirror on `dp_ram.vhd`. What no longer holds is the appeal to agreement
> between sources. Re-derive before starting.

Settled, and cheaper than it first looked. The slides say two latches, for `R14`
and `R15`. The reference CPU saves `R13` as well — `SP_org` alongside `SR_org`
and `PC_org`, all three mirrored continuously while `Int_Active = '0'` and all
three reverted in the `ctrlRTI` arm. The gap is one register.

**DECISION: save `R14` and `R15` only.** Rule 1 puts the document first, the
emulator independently agrees with it, and adding `R13` is not free here: `R13`
is an ordinary banked register in a [dp_ram.vhd](../src/sub/dp_ram.vhd)-backed
file, and `RTI` already uses both write ports into that file — the ordinary one
for `R15` and the dedicated SR port (`wr_sr_en_i`) for `R14`. A third restore
needs a second cycle, and therefore a micro-op, turning `RTI` from a single-beat
instruction into a sequenced one. That is a real cost for a divergence the
ground-truth document does not ask for.

**The cost of diverging is close to zero**, which is a change from how this note
first read it. Upstream's own `doc/best-practices.md` already requires an ISR to
"not leave any register modified when calling `RTI`", and offers the stack as the
way to manage that. No conforming upstream ISR can rely on the CPU restoring
anything beyond the two registers the slides name — `R13` included, since an ISR
that balances its own stack leaves `SP` where it found it anyway. Write the
divergence down (T11), but it is a footnote, not a hazard.

For the record, since it shaped the plan: an earlier draft of this note argued
this decision against a register file that continuously mirrors `R8`-`R12` into
shadow copies and reverts them on `RTI`, giving an ISR a private `R8`-`R12` for
free. It concluded that such a model could not be built here — one write port on
`dp_ram.vhd`, and a continuous mirror needs a second writer into the same array,
which that module's header explains cannot be inferred. Both statements remain
true *about this design*: one write port on `dp_ram.vhd`, and a continuous
mirror needs a second writer into the same array. What was wrong was the claim
that the reference has no such register file — it has one on `develop`
(`vhdl/register_file.vhd`, with `shadow_en`/`revert_en` and revert loops over
`R8`-`R12` and `R13`-`R15`), and only `dev-V1.61` lacks it. So the earlier draft
described the reference correctly and this paragraph did not. Nothing in the plan
below turns on the difference, but the argument for the decision does, which is
what the note at the top of this section is about.

## How it fits this pipeline

### Three things already fit

* **The return address already exists, and is already correct.**
  `next_pc` in [write.vhd](../src/cpu_main/write.vhd) computes

  ```vhdl
     next_pc   <= prep_stage_i.addr + 2
                  when (prep_stage_i.src_imm = '1' or prep_stage_i.dst_imm = '1')
                  else prep_stage_i.addr + 1;
  ```

  which is exactly what interrupt entry needs, including for two-word
  instructions. It is not new code on an untested path either: this is the value
  `RSUB` already pushes on the stack.

* **`R14` and `R15` can be restored in the same cycle.**
  [registers.vhd](../src/registers/registers.vhd) has a dedicated SR write port
  (`wr_sr_en_i`/`wr_sr_val_i`) alongside the ordinary one. `RTI` can write `R15`
  through the ordinary port and `R14` through the SR port simultaneously, so it
  needs no micro-op sequencing.

* **`INT` and `RTI` are branches, and branches already work.** DECODE rewrites
  JMP's microcode to carry `REG_WRITE` with `res_reg = R15` (the
  `C_OPCODE_JMP` arm in [decode.vhd](../src/cpu_main/decode.vhd)),
  which routes the target through `res_other`. Both instructions reuse that path
  unchanged, and get the pipeline flush that comes with any write to `R15`.

### Two things constrain the design

* **The interrupt state must live in WRITE.** `cpu_main.vhd` resets DECODE and
  PREPARE with `rst_i or fetch_valid_o`, so every flip-flop in those two stages
  is cleared by every flush — including the flush that interrupt entry itself
  causes. The in-ISR flag and the saved `R14`/`R15` must sit in WRITE, which is
  not on that net, or outside CPU_MAIN entirely.

* **The request pins must not reach WRITE's combinational logic.** With the
  daisy chain gone there is no multi-cycle handshake left to hide, so the case
  for a leaf module is no longer "this FSM is too big for WRITE" — it is two
  states and a pair of registers. It is still worth having: `interrupt.vhd`
  registers `irq_valid_i` and `irq_addr_i` into `pending_o`/`addr_o`, which keeps
  two external pins out of CPU_MAIN, where the timing margin is; it gives the
  interface contract one place to live and one `formal/interrupt.psl` to check
  it; and it matches how every other interface in this design is built, with the
  usual `.psl`/`.sby`/`.gtkw` triplet in `formal/`. That call is recorded as
  reversible in
  [src/interrupt/README.md](../src/interrupt/README.md#open-for-t2) — if T2 finds
  the entity is nothing but wires, fold it into WRITE.

### The timing problem

`fetch_valid_o` has three terms already: a write to `R14`/`R15` (`reg_we_o` and
three address bits), a register bank switch (`inst_done_o`, `prep_stage_i.is_crb`,
and `bank_stale_i`), and a store into the instruction stream (see the "Register
bank switch" note in [write.vhd](../src/cpu_main/write.vhd)). It used to fit a
single 6-input LUT and no longer does. Interrupt entry is a fourth term on a net
that is the reset pin of two entire pipeline stages, and the bank-switch work
spent 0.072 ns of the margin quoted below getting the third one in.

The fourth term is the **commit** itself — `inst_done_o and pending_o and not
int_active` — because the redirect now happens in the commit cycle. That is
exactly the topology T0 measured, so T0's result applies directly rather than as
an upper bound; under the daisy-chain design the term was the interrupt module's
`done_o` alone, one input fewer, and T0 read as a bound. `pending_o` is a
register output, which is the whole reason `irq_valid_i` is registered inside
`interrupt.vhd` rather than used raw.

`fetch_addr_o` gains a mux — `addr_o` on interrupt entry, the existing
register-write path otherwise — but that is a different net from `fetch_valid_o`
and is not the one with the margin problem.

The budget is **+0.093 ns** — see [Utilization](README.md#utilization), measured
at the 7.25 ns constraint. For scale, adding the register-bank flush alone cost
0.098 ns, making it conditional cost a further 0.072 ns, and placement noise
unrelated to any edit has been measured at up to 0.284 ns. This is the single
risk most likely to invalidate the approach, which is why it is measured first
rather than last.

## Test cases

Written as self-checking `.asm` in the existing style: a status word to `0x7FFF`
just before the final `HALT`, with every failed sub-test branching to its own
`HALT`. See [test/README.md](../test/README.md).

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
   the device holds the request until `irq_ready_o` and releases it after.
5. Request a second interrupt from inside an ISR. Checks it is **not** accepted
   until after the `RTI`.
6. Interrupt an instruction that is two words, e.g. `MOVE 0x1234, R0`. Checks
   the `+2` path of `next_pc`. The reference treats this as a case worth handling
   explicitly rather than by inference: for `INT <constant>`, which is itself two
   words (`@R15++` on the destination), the `amIndirPostInc` arm bumps the
   *saved* PC — `fsmPC_org <= PC + 1` — so that `RTI` resumes after the constant
   word rather than on it. That is exactly the semantics `next_pc` already gives
   this design for free.
7. `INT` immediately after `INCRB`, with an ISR that changes the bank. Checks
   the bank-change flush still holds across an interrupt.

Cases 2 and 5 are the ones most likely to actually fail. Case 6 should pass on
day one, for the reason given above; if it does not, `next_pc` is not being used
where it should be.

Not happy path, but both need deciding and testing: rogue `RTI` and rogue `INT`.
The reference halts on both.

### Formal verification

The `.asm` above covers the software half; the properties in
[formal/cpu_main.psl](../formal/cpu_main.psl) cover it a second way, and reach
cases the test program cannot. See the "Software interrupts" section there.

The state an interrupt saves is invisible to software by design, and it is
invisible to the proof too: a `vunit` bound to `cpu_main` cannot see inside the
WRITE instance. So the properties are stated against a shadow model built from
the instruction encoding and the retire pulse alone, which is what makes them a
requirement rather than a transcription — the round trip is checked against a
return address computed from the `INT`'s own encoding, cycles earlier and
independently of anything `write.vhd` latched.

Two things there are worth knowing before changing any of it.

* **Both rogue cases are asserted as "must not redirect", not as "must halt".**
  That is the part of the specified behaviour which holds both today, where they
  retire as no-ops, and after a halt is implemented. It also pins the hazard
  that matters most: `irq_r15` has no reset, so a rogue `RTI` that redirected
  would jump into an uninitialised latch.
* **The nested-`INT` property has to be asserted separately.** It does not
  follow from the round trip: `p_irq` latches the saved pair on entry only, so a
  design that wrongly nested would still return to the outer address correctly
  and the round-trip property would pass. A mutation found this; the note above
  `f_int_no_nest_reg` records it.

The register-bank flush across an `RTI` — case 7 above, in the other direction —
needs no property of its own. `RTI` restores `R14` through the ordinary register
port, which is exactly what `f_flush_on_bank_change` and `f_hold_on_bank_change`
already trigger on, so what that path needed was reachability rather than a new
assertion: `c_rti_bank_change`.

## Task plan

### Phase 0 — de-risk

* **T0. Timing spike. DONE — the fourth term is free.** Measured at commit
  `342ca31`, against the `a9f2c0b` baseline of **+0.135 ns**:

  | Build | WNS | LUTs | FFs | Worst path, in `wr_stage_o` |
  |---|---|---|---|---|
  | baseline | +0.135 ns | 887 | 598 | `alu_src_val[1]` -> `alu_src_val[2]` |
  | four terms | +0.167 ns | 892 | 599 | `r14[5]` -> `alu_src_val[4]` |

  The spike was one free-running toggle flip-flop standing in for the interrupt
  module's registered grant output, with `(inst_done_o and spike_grant)` added
  as a fourth OR term — the exact topology this note predicts. The build passed
  and wrote a bitstream, so timing was met, not merely close.

  Slack went **up** by 0.032 ns. Nothing about a fourth OR term makes a design
  faster, so the right reading is not "it helped" but "its cost is below the
  noise floor": this page records placement noise of up to 0.284 ns from edits
  nowhere near the path, which is an order of magnitude larger. The fourth term
  costs **nothing measurable**.

  Two things worth having on record beyond the headline. `fetch_valid_o` did not
  become critical — both builds end up on the same Status Register loop inside
  PREPARE, at 9 logic levels and roughly 80% routing, which is the path
  [The critical path](README.md#the-critical-path) already describes. And the
  cost in area is +5 LUTs and +1 flip-flop, where the flip-flop is the spike's
  own toggle and so will not appear in the real implementation.

  **Consequence: T3-T6 proceed as planned.** No need to register the grant a
  cycle earlier, and no need to restructure `fetch_valid_o`. Re-measure at T12
  all the same — a real grant term is not a toggle flip-flop, and this margin is
  thin enough that it is worth confirming rather than assuming.

### Phase 1 — infrastructure, no CPU changes

* **T1. Interrupt source for the testbench.** A device that requests an
  interrupt when the program writes a magic address, wired into
  [test/system.vhd](../test/system.vhd). It speaks the three-signal interface
  directly — assert `irq_valid_i` with the ISR address on `irq_addr_i`, hold both
  until `irq_ready_o`, drop `irq_valid_i` the cycle after — so it is a handful of
  registers rather than a daisy-chain participant. Nothing in `test/` needs to
  model the chain; if the chain is ever worth exercising, it belongs in a
  separate adaptation-layer testbench, not in this CPU's. It must be
  **program-triggered, not free-running**: a timer would still be deterministic in simulation, but the
  interrupt would land at a different instruction after any pipeline change,
  churning the golden files on unrelated commits. **Done when** all existing
  tests still pass unchanged.

  DECISION: Add the feature that the interrupt will be triggered a number of
  cycles AFTER the write. The delay could perhaps just be the value written to
  this magic address. This makes is possible to fine tune when an interrupt is
  asserted, and test the edge cases og e.g. asserted while an INT instruction is
  somewhere in the pipeline.

  DECISION: Write the seven test cases mentioned in "Happy path" above as well
  as the edge cases I added, and the rogue RTI and rogue INT. Basically, I want
  all the test cases written up front for careful review.

  DECISION: those programs cannot pass until Phase 2 lands, so they go in a new
  `TESTS_PENDING` variable in the Makefile that `make test` does **not** run.
  Without it every Phase 1 and Phase 2 commit turns CI red, and a red CI that is
  expected to be red stops being a signal. A program moves from `TESTS_PENDING`
  to `TESTS` on the commit that makes it pass, which gives each step below a
  crisp definition of done: name the programs that graduate.

* **T2. `src/interrupt/interrupt.vhd`.** The request-side adapter:
  `irq_valid_i`/`irq_addr_i` in, `irq_ready_o` out, `pending_o`/`addr_o` to
  WRITE, `start_i` back from it. Two states, `IDLE` and `ACCEPTED`. Plus
  `formal/interrupt.{psl,sby,gtkw}`. **The specification is
  [src/interrupt/README.md](../src/interrupt/README.md)**, written at T2b: read
  the port table, the ten-obligation contract, and the walkthrough before writing
  any VHDL, and take the device's five obligations as PSL assumptions and the
  CPU's five as assertions. **Done when** `sby` passes bmc, cover, and prove, and
  the diagram still matches. Two things to decide before writing any of it:
  whether the entity is worth having at all (the last bullet of
  [Open for T2](../src/interrupt/README.md#open-for-t2)), and whether a device
  may withdraw a request before it is accepted
  ([Withdrawal](#withdrawal-and-what-allowing-it-would-cost)) — the second
  changes what the module's registers are for, so it is cheaper answered now than
  after.
* **T2b. Protocol timing diagram. DONE, ahead of T2, and redrawn since.** Drawn
  first rather than last, because the bus protocol was the part of this feature
  the upstream sources disagreed about most, so it is worth pinning down before
  any code commits to a reading of it. It has since been redrawn against the
  three-signal interface that replaced the daisy chain; the version described
  below is the daisy-chain one, kept because the four changes it forced are how
  this plan got its present shape. The diagram is
  [src/interrupt/timing.tex](../src/interrupt/timing.tex) and the prose around it
  is [src/interrupt/README.md](../src/interrupt/README.md); `make diagrams` renders
  the `.png`, and both are committed. The `diagrams` rule is now a pattern rule
  over a `TIMINGS` list, and the shared LaTeX macros moved to `doc/timing.sty`
  (`src/cpu_main/timing.png` re-renders byte-identical after that move).

  It changed three things in this plan, all recorded where they belong: the
  combinational bus release is no longer required, `int_wait` appeared as a new obligation on
  WRITE (T3), and the redirect turns out to happen at the module's `done_o`
  rather than at `inst_done_o` (T6).

  A fourth followed on review of the drawing: the grant was shortened from two
  cycles to one, dropping the wait for `INT_N` to rise and taking the address at
  the end of the granted cycle instead.

  **Then the interface changed**, and the redraw undid two of those four. There
  is no grant, so nothing is shortened and nothing is tighter than upstream; the
  address is registered a cycle *before* the commit rather than two cycles after
  it, so `int_wait` is gone and the redirect is back at `inst_done_o` where the
  one-line version of T6 originally had it. What survives is the reason the
  diagram was drawn early at all: it is still the thing that shows whether a
  signal is registered, and it still found the answer before any VHDL committed
  to one. See
  [The interrupt request interface](#the-interrupt-request-interface).

  **Still to do:** the diagram is a specification, not a recording. Redraw it
  from a GHDL simulation once T2 runs, as `src/cpu_main/timing.tex` is read off
  `test/prog_waveform.asm`, and treat any disagreement as a bug in whichever of
  the two is easier to defend.

### Phase 2 — CPU core

* **T3. Interrupt state.** The in-ISR flag and the saved `R14`/`R15`, in WRITE.
  The commit pulse is `inst_done_o and pending_o and not int_active`.

  The commit must happen **at an instruction boundary**, and that is not a
  stylistic choice: the saved return address is `next_pc` of a *retiring*
  instruction, and mid-instruction there is no such value. A QNICE instruction
  may be partway through a three-micro-op expansion with a memory read
  outstanding and post-increments already applied to `R13` or `R15`, and nothing
  in the pipeline can reconstruct a resumable PC from that. This rule used to be
  written as an obligation on `irq_ready_o` in
  [src/interrupt/README.md](../src/interrupt/README.md), which was the wrong
  place three times over — a device can neither observe nor exploit it,
  `formal/interrupt.psl` cannot state it (that module has no view of
  `inst_done_o`), and as an interface clause it was not even true, since
  `irq_ready_o` is registered off `start_i` and lands the cycle *after* the
  boundary. It is a property of the commit inside WRITE, and it is asserted in
  `cpu_main.psl` (T9).

  `int_wait` is **no longer needed**, and the reason is worth keeping because it
  is the clearest single benefit of the interface change. Under the daisy chain,
  commit and redirect were two cycles apart: the saved PC was already fixed while
  DECODE and PREPARE still held the instructions after it, so if one retired in
  that window `RTI` would replay it, and WRITE had to hold its ready to PREPARE
  low for two cycles to prevent it. Here the address is registered before the
  commit, so commit and redirect are the same cycle and there is no window. If
  T2's implementation reintroduces a gap for any reason, `int_wait` comes back
  with it.
* **T4. `RTI`.** Restore `R15` through the ordinary write port and `R14` through
  the SR port in one cycle; clear the in-ISR flag. The write to `R15` already
  drives the flush. Rogue `RTI` halts.
* **T5. `INT <dst op>`.** Latch `R14` and `next_pc`, set the in-ISR flag,
  redirect through the JMP microcode path. Direct mode is the happy path;
  indirect modes need a memory read first. Rogue `INT` halts.

  DECISION: Make it so that test cases 1, 2, and 3 above (in the happy path) can
  be verified as working by this point in the development process. They graduate
  from `TESTS_PENDING` to `TESTS` on this commit — they need only `INT R0` and
  `RTI`, so they do not depend on T6 or T7.

* **T6. Hardware interrupt entry.** Commit at `inst_done_o`, taking `next_pc` as
  the return address, and redirect in that same cycle to `addr_o`, with
  `irq_ready_o` following one registered cycle later.

  This is where the interface change lands hardest. T2b had split commit and
  redirect two cycles apart, because under the daisy chain the ISR address did
  not exist at the commit point — the grant handshake was what fetched it, and
  the grant could not be issued before the commit. With the address arriving
  alongside the request, the redirect returns to `inst_done_o`, which is where
  the original one-line version of this task had it.

  So the fourth term on `fetch_valid_o` is the commit itself, which is exactly
  the topology T0 measured as free. T0's headroom result therefore applies
  directly rather than as an upper bound — but re-measure at T12 regardless, as
  T0 already says.

  Graduates test cases 4, 5, and 7 from `TESTS_PENDING`.
* **T7. Top-level ports.** `irq_valid_i`, `irq_ready_o`, and `irq_addr_i` on
  [cpu.vhd](../src/cpu.vhd) and `system.vhd`. Active high, no `_n` suffixes; the
  daisy chain, if a system wants one, is the adaptation layer's business.

### Phase 3 — close it out

* **T8. Graduate the last test programs.** Writing them moved to T1; what is
  left here is emptying `TESTS_PENDING` — every program in it must now be in
  `TESTS` and passing, including the two rogue cases. Regenerate the golden
  files and read the diff carefully. **Done when** `TESTS_PENDING` is empty.

* **T9. Formal.** Extend [cpu_main.psl](../formal/cpu_main.psl): no `irq_ready_o`
  while an ISR is active; interrupt entry happens only on `inst_done_o` (moved
  here from the interface contract, where it could not be stated — see T3);
  `RTI` restores both registers; interrupt entry asserts `fetch_valid_o` with
  `fetch_addr_o` equal to the accepted request's address; the saved PC equals
  `next_pc`. Model them on the existing
  `f_flush_on_bank_change`, which states the same kind of obligation.
* **T10. Disarm the trap.** Drop the `RTI` and `INT` arms of `p_unimplemented`,
  keep `EXC` and opcode `0xD`, and update the list in
  [test/README.md](../test/README.md).
* **T11. Documentation.** Fold this note into
  [doc/README.md](README.md), delete its TODO bullet, record the saved-state
  divergence — the reference restores `R13` on `RTI` and this design does not —
  where a reader will find it, and update [CLAUDE.md](../CLAUDE.md). Record the
  interface divergence in the same place: this CPU has no `INT_N`/`IGRANT_N`
  pins, and a QNICE-FPGA system needs an adaptation layer for interrupts as it
  already does for the two memory buses.
* **T12. Re-measure.** `make lint`, `make test`, `make -C formal -k`, then
  `make utilization` against the `a9f2c0b` baseline.

## Risks

* **Timing on `fetch_valid_o`.** T0 exists to find this out on day one, and its
  measured topology is now the one the design actually uses (T6).
* **The adaptation layer is untested here.** Dropping the daisy chain moves it
  out of this repository, which is the point, but it also moves it out of this
  repository's test suite and formal proofs. Nothing in `make test` will ever
  exercise a chain again. The mitigation is that the CPU's side of the contract
  is five obligations wide and each is a PSL assumption (T2), so a layer that
  violates one is violating something written down rather than something
  implied.
* **The saved-state divergence.** Settled: `R14` and `R15` only, one register
  short of the reference. Upstream's own best-practices rule for ISR authors is
  what makes that cheap. Retrofitting extra saved state into a `dp_ram`-backed
  register file later would still be a rewrite, so the decision stays made.
* **Golden-file churn.** T1's determinism choice is what protects against it.
* **Interaction with the HALT gate.** `p_halt_fetched` in `cpu.vhd` gates the
  ICACHE-to-DECODE handshake off when a `HALT` is handed to DECODE, and clears
  that gate on a flush. Interrupt entry is a new flush source, so check it
  cannot un-gate a `HALT` that has already been accepted.

