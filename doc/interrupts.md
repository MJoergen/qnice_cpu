# Interrupts

Design note for a feature that is **not implemented yet**. It records what the
ISA requires, which parts of this pipeline already fit, the one behavioural
question that has to be answered before any code is written, and the order the
work should happen in. Nothing here is measured yet except where it says so.

## What exists today

Nothing decodes `RTI`, `INT` or `EXC`. Without help they would retire as silent
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
repository, on branch **`dev-V1.61`, at commit `aede0ce`**. That branch is the
one to track. An earlier reading of this note was taken from `dev-cpu-pipeline`,
an experimental branch, and two of the three disagreements it recorded turned
out to exist only there.

* `doc/intro/qnice_intro.tex` — the Interrupts slides; the programmer's model.
* `doc/int-device.md` — the daisy-chain bus protocol.
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
`dev-V1.61`. Two of the three items this note carried before the move rested on
text and code that exist only on `dev-cpu-pipeline`: the `EXC` contradiction is
gone entirely, and the saved-state disagreement is real but far narrower than it
looked. A bit-numbering error in the ISA document takes their place as the item
that most needs writing down.

**`EXC` is not a contradiction. It is assembler-only.** Nothing in the ISA
document mentions `EXC` — not the instruction table, not the control-command bit
table. Neither does the programming card, nor the emulator, whose
`control_mnemonics` array stops at `DECRB`. Nor does the reference CPU:
`vhdl/cpu_constants.vhd` defines `ctrlHALT`, `ctrlRTI`, `ctrlINT`, `ctrlINCRB`
and `ctrlDECRB` and stops there, so the encoding falls into the `Ctrl_Cmd` case's
`when others` arm, commented "illegal command: HALT". `EXC` exists in exactly one
place in the whole upstream project: the assembler, which knows the mnemonic and
emits `5` for it.

An earlier draft of this note reported the ISA document as contradicting itself
here, listing `EXC const, dst — Exchange shadow register` in the instruction
table while giving it no encoding. That line is real, but it is not in
`dev-V1.61`; it was added on `dev-cpu-pipeline` by commit `19a1657`, "Added EXC
instruction to qnice_intro". **Implemented choice: unchanged — `EXC` is out of
scope, and its arm of `p_unimplemented` stays armed permanently.** The reasoning
is now shorter and stronger. It no longer leans on the saved-state decision
below: there is simply no source above the assembler that has ever said what
`EXC` does.

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

**Saved state — all four sources disagree, and the ISA document has the
narrowest set.** This is the disagreement that changed most under `dev-V1.61`.

| Source | Saved and restored |
|---|---|
| `qnice_intro.tex`, the Interrupts slide (rule 1) | `R14`, `R15` |
| `programming_card.tex`, `Interrupts` section | `PC` and `SP` — `R15`, `R13`, **not** `R14` |
| `vhdl/qnice_cpu.vhd` (rule 3) | `R13`, `R14`, `R15` |
| `emulator/qnice.c` | `R14`, `R15` |

The reference keeps `SP_org`, `SR_org` and `PC_org` in the CPU itself — the
declarations are commented `(R13)`, `(R14)`, `(R15)` — mirrors all three
continuously while `Int_Active = '0'`, and reverts all three in the `ctrlRTI`
arm. So it saves one register more than the slides do, and the programming card
saves a different set again, omitting the status register that both other
implementations save.

Rule 1 makes the slides ground truth, the emulator independently agrees with
them, and the programming card is a summary that loses to the slides.
**Implemented choice: `R14` and `R15` only** — see
[what state is saved](#the-decision-to-make-first-what-state-is-saved) for what
that costs here, which is far less than it once looked.

An earlier draft of this note recorded this disagreement as slides-say-two versus
`register_file.vhd`-reverts-`R8`-`R15`, describing a register file that
continuously mirrors the upper registers into shadow copies. **No such code
exists in `dev-V1.61`.** `vhdl/register_file.vhd` is 102 lines with no shadow
array, no `revert_en` and no `Int_Active` port at all; `R8`-`R12` are ordinary
registers, and `R13`/`R14`/`R15` are not in the file — they are driven in from
the CPU. The shadow file is `dev-cpu-pipeline`-only, from commit `87f9d4b` "WIP
CPU and Register File: Refactoring R13..R15", and even there the loop body reads
`for regnr in 8 to 12` — five registers, not eight.

### Bus protocol

Two active-low lines: `INT_N` in, `IGRANT_N` out. Devices form a daisy chain in
which position is priority — the closer to the CPU, the higher.

1. A device pulls `INT_N` low to request. It may hold it low indefinitely and
   must tolerate waiting arbitrarily long, because an ISR may already be
   running or a higher-priority device may be ahead of it.
2. When the CPU can service it, it saves `R14` and `R15` and *then* pulls
   `IGRANT_N` low. The ISA document states that ordering explicitly — "it will
   save `R14` and `R15` and then signals the device by pulling `/IGRANT` low" —
   so the save is not merely concurrent with the grant. The device drives the
   address of its ISR onto the bus in that same cycle.
3. The CPU samples the address at the end of that cycle and releases `IGRANT_N`.
4. The device releases the bus and pulls `INT_N` high.

The cycle-level version of those four steps — which signal moves on which edge,
and which are registered — is the T2b diagram and its walkthrough in
[src/interrupt/README.md](../src/interrupt/README.md). The handshake costs two
cycles between the commit and the redirect.

DECISION (revised after T2b): the grant lasts **exactly one cycle**, and the
address is sampled at the end of it. Read the two pins as an inverted AXI-style
handshake — `VALID` is `INT_N` low, `READY` is `IGRANT_N` low — and the transfer
is the one cycle in which both are low. The CPU never waits inside the grant,
because it only grants when a request is already asserted and held.

That is one cycle faster than the first draft of this note, which had the CPU
wait for `INT_N` to go high as the device's data-valid signal, exactly as
`cs_int_wait_isr` in `vhdl/qnice_cpu.vhd` does. It is also **tighter than the
upstream prose**: `int-device.md` and `doc/intro/interrupt_timing.jpg` both put
the data after the grant and let a device take any number of cycles to produce
it. The reference *device* nonetheless satisfies the tighter rule already —
`fsm_output_decode` in `vhdl/timer.vhd` drives `data_out <= reg_int` in the very
cycle it sees `grant_n_in = '0'`, still holding `int_n_out` low, and raises
`int_n_out` only in the following state `s_provide_isr`. A device that *registers*
its address output is conforming upstream and would break here. That divergence,
the timing cost of the now single-cycle capture path, and the one thing it buys
in return (an early release of `INT_N` becomes a detectable violation instead of
an undetectable one) are written up in
[src/interrupt/README.md](../src/interrupt/README.md).

What does **not** work, and was considered: having the device present the address
from the moment it asserts `INT_N`, so that the address lines are literally an
AXI data channel. The address lines are shared by the whole chain, and a
requesting device de-couples only its right neighbour's *grant*, not its request
— so devices further right are free to request during a transaction, and would
drive the bus at the same time as the granted device. The grant is what resolves
who owns the bus, so the data cannot precede it.

DECISION (revised at T2b): the device must hold `isr_addr_i` for as long as
`igrant_n_o` is low, and may release it any cycle at or after the one in which it
sees `igrant_n_o` go high. It does **not** have to release combinationally.

An earlier draft of this note did require a combinational release, on the
assumption that the CPU would use `isr_addr_i` directly. Drawing the diagram
showed it does not: the address is captured into a register at the end of the
granted cycle, so the bus turnaround afterwards cannot be observed. The weaker rule is
also what upstream already satisfies — `fsm_output_decode` in `vhdl/timer.vhd`
holds `data_out` until it sees `grant_n_in` high — so requiring more would have
made a conforming device non-conforming here for no gain. Neither
`int-device.md` nor the slides state any cycle budget in the first place, and the
reference CPU is more relaxed still, spending a whole state between sampling the
address and fetching (`cs_int_jmp_isr`, commented "IGRANT_N goes back to high,
new PC and CpuAddr is being clocked in").

DECISION: the ISR address arrives on a **port of its own**, `isr_addr_i`, not on
the data Wishbone. The daisy-chain data phase is not a Wishbone transaction —
the device drives the bus while `igrant_n_o` is low, outside any CYC/STB cycle —
so reusing `wbd_data_i` would mean a bus protocol violation, or a mux outside
the CPU, or modelling the grant as a read from a reserved address. A dedicated
port avoids all three, and costs nothing this design has to defend: the
instruction and data interfaces are already split Harvard-style, and this CPU is
already not a drop-in replacement for the original.

There is no way to abort a request. Once a device has asked, the CPU will
eventually grant, and the device must have a valid ISR address to supply even if
the interrupt has since been masked in software.

DECISION: Port names are to be lower case (snake case?) following the
CODING_STYLE.md. This means "int_n_i" and "igrant_n_o".

DECISION: Make a timing diagram (similar to src/cpu_main/timing.tex) that shows
the relationship between the important signals (e.g. int_n_i, igrant_n_o,
isr_addr_i).
Particularly important is whether changes are registered (i.e. delayed until
next clock cycle) or combinatorial.  The current design already allows for data
input to be registered.

**DONE — see [src/interrupt/README.md](../src/interrupt/README.md).** The diagram
is [src/interrupt/timing.tex](../src/interrupt/timing.tex), rendered by
`make diagrams`, and the module README next to it carries the cycle-by-cycle
walkthrough and the contract as five obligations on the device and five on the
CPU. Everything on the CPU side of the boundary is registered; the two
exceptions, `start_i` and the device's drive of `isr_addr_i`, are named as such.
Read that page before writing `interrupt.vhd` — the diagram is the specification
now, since it was drawn ahead of the implementation rather than off a simulation.

### Programmer's model

* **Interrupts do not nest.** A request is granted only when no ISR is already
  running. The reference gates this on `Int_Active` in the `cs_fetch` arm of
  `fsm_output_decode`, before the fetched word is taken as an instruction.
* **`R14` (SR) and `R15` (PC) are saved** into latches invisible to software.
  The reference saves `R13` as well; this design follows the document. See
  [Where the sources disagree](#where-the-sources-disagree).
* **`RTI`** restores them, clears the in-ISR state and resumes.
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
[Where the sources disagree](#where-the-sources-disagree): `EXC` appears nowhere
in the ISA document, the programming card, the reference CPU or the emulator —
only in the assembler, which is the one place in the project that knows the
mnemonic. So `EXC` has never been implemented in QNICE hardware, and no document
has ever specified what it should do. Keep its arm of `p_unimplemented` armed,
along with reserved opcode `0xD`, and drop only the `RTI` and `INT` arms.

## The decision to make first: what state is saved

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
true *about this design*. They are just not statements about the reference, which
has no shadow register file at all; that code lives only on the experimental
`dev-cpu-pipeline` branch. Nothing in the plan below turned on the difference,
but the argument for the decision did, so it is restated above on grounds that
survive.

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

* **The grant handshake is multi-cycle**, so it does not belong inline in WRITE.
  It should be a leaf module, `src/interrupt/interrupt.vhd`, presenting a
  valid/ready interface to the CPU and hiding the `INT_N`/`IGRANT_N` protocol
  behind it. That is how every other protocol FSM in this design is built, and
  it gets the usual `.psl`/`.sby`/`.gtkw` triplet in `formal/`.

### The timing problem

`fetch_valid_o` has three terms already: a write to `R14`/`R15` (`reg_we_o` and
three address bits), a register bank switch (`inst_done_o`, `prep_stage_i.is_crb`
and `bank_stale_i`) and a store into the instruction stream (see the "Register
bank switch" note in [write.vhd](../src/cpu_main/write.vhd)). It used to fit a
single 6-input LUT and no longer does. An interrupt grant is a fourth term on a
net that is the reset pin of two entire pipeline stages, and the bank-switch work
spent 0.072 ns of the margin quoted below getting the third one in.

The budget is **+0.093 ns** — see [Utilization](README.md#Utilization), measured
at the 7.25 ns constraint. For scale, adding the register-bank flush alone cost
0.098 ns, making it conditional cost a further 0.072 ns, and placement noise
unrelated to any edit has been measured at up to 0.284 ns. This is the single
risk most likely to invalidate the approach, which is why it is measured first
rather than last.

## Test cases

Written as self-checking `.asm` in the existing style: a status word to `0x1FFF`
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
4. Hardware path: the program writes the trigger address, the device pulls
   `INT_N`. Checks the whole handshake including bus release.
5. Request a second interrupt from inside an ISR. Checks it is **not** granted
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
  [The critical path](README.md#The-critical-path) already describes. And the
  cost in area is +5 LUTs and +1 flip-flop, where the flip-flop is the spike's
  own toggle and so will not appear in the real implementation.

  **Consequence: T3-T6 proceed as planned.** No need to register the grant a
  cycle earlier, and no need to restructure `fetch_valid_o`. Re-measure at T12
  all the same — a real grant term is not a toggle flip-flop, and this margin is
  thin enough that it is worth confirming rather than assuming.

### Phase 1 — infrastructure, no CPU changes

* **T1. Interrupt source for the testbench.** A device that requests an
  interrupt when the program writes a magic address, wired into
  [test/system.vhd](../test/system.vhd). It must be **program-triggered, not
  free-running**: a timer would still be deterministic in simulation, but the
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

* **T2. `src/interrupt/interrupt.vhd`.** The daisy-chain FSM: `int_n_i` in,
  `igrant_n_o` out, `isr_addr_i` sampled, ISR address out to WRITE. Plus
  `formal/interrupt.{psl,sby,gtkw}`. **The specification is
  [src/interrupt/README.md](../src/interrupt/README.md)**, written at T2b: read
  the port table, the ten-obligation contract and the walkthrough before writing
  any VHDL, and take the device's five obligations as PSL assumptions and the
  CPU's five as assertions. **Done when** `sby` passes bmc, cover and prove, and
  the diagram still matches.
* **T2b. Protocol timing diagram. DONE, ahead of T2.** Drawn first rather than
  last, because the bus protocol was the part of this feature the upstream
  sources disagreed about most, so it is worth pinning down before any code
  commits to a reading of it. The diagram is
  [src/interrupt/timing.tex](../src/interrupt/timing.tex) and the prose around it
  is [src/interrupt/README.md](../src/interrupt/README.md); `make diagrams` renders
  the `.png`, and both are committed. The `diagrams` rule is now a pattern rule
  over a `TIMINGS` list, and the shared LaTeX macros moved to `doc/timing.sty`
  (`src/cpu_main/timing.png` re-renders byte-identical after that move).

  It changed three things in this plan, all recorded where they belong: the
  combinational bus release is no longer required (see
  [Bus protocol](#bus-protocol)), `int_wait` appeared as a new obligation on
  WRITE (T3), and the redirect turns out to happen at the module's `done_o`
  rather than at `inst_done_o` (T6).

  A fourth followed on review of the drawing: the grant was shortened from two
  cycles to one, dropping the wait for `INT_N` to rise and taking the address at
  the end of the granted cycle instead. That is a cycle off the interrupt
  response and a contract on devices slightly tighter than upstream's prose —
  both argued in [Bus protocol](#bus-protocol) above.

  **Still to do:** the diagram is a specification, not a recording. Redraw it
  from a GHDL simulation once T2 runs, as `src/cpu_main/timing.tex` is read off
  `test/prog_waveform.asm`, and treat any disagreement as a bug in whichever of
  the two is easier to defend.

### Phase 2 — CPU core

* **T3. Interrupt state.** The in-ISR flag and the saved `R14`/`R15`, in WRITE.
  The commit pulse is `inst_done_o and pending_o and not int_active`.

  Plus `int_wait`, which T2b turned up: between the commit and the redirect the
  saved PC is already fixed, but DECODE and PREPARE still hold the instructions
  that follow it, and if one of them retired in that window `RTI` would replay
  it. So WRITE holds its ready to PREPARE low for those cycles. It is ordinary
  back-pressure, not new machinery, and it is *not* the same mechanism as
  `p_halt_fetched` in `cpu.vhd` — gating the ICACHE feed does not help here,
  because the instructions in question are already past it.
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

* **T6. Hardware grant.** Commit at `inst_done_o`, taking `next_pc` as the return
  address, and redirect two cycles later at the module's `done_o`. T2b split
  those two apart: the earlier one-line version of this task had the redirect
  happening at `inst_done_o` too, which cannot work, because the ISR address does
  not exist yet at the commit point — the grant handshake is what fetches it, and
  the grant may not be issued before the commit.

  So the fourth term on `fetch_valid_o` is `done_o` alone, not
  `inst_done_o and done_o`. That is one input fewer than the topology T0 measured
  as free, so T0's headroom result stands as an upper bound rather than needing a
  re-run — but re-measure at T12 regardless, as T0 already says.

  Graduates test cases 4, 5 and 7 from `TESTS_PENDING`.
* **T7. Top-level ports.** `int_n_i`, `igrant_n_o` and `isr_addr_i` on
  [cpu.vhd](../src/cpu.vhd) and `system.vhd`.

### Phase 3 — close it out

* **T8. Graduate the last test programs.** Writing them moved to T1; what is
  left here is emptying `TESTS_PENDING` — every program in it must now be in
  `TESTS` and passing, including the two rogue cases. Regenerate the golden
  files and read the diff carefully. **Done when** `TESTS_PENDING` is empty.

* **T9. Formal.** Extend [cpu_main.psl](../formal/cpu_main.psl): no grant while
  an ISR is active; `RTI` restores both registers; a grant asserts
  `fetch_valid_o`; the saved PC equals `next_pc`. Model them on the existing
  `f_flush_on_bank_change`, which states the same kind of obligation.
* **T10. Disarm the trap.** Drop the `RTI` and `INT` arms of `p_unimplemented`,
  keep `EXC` and opcode `0xD`, and update the list in
  [test/README.md](../test/README.md).
* **T11. Documentation.** Fold this note into
  [doc/README.md](README.md), delete its TODO bullet, record the saved-state
  divergence — the reference restores `R13` on `RTI` and this design does not —
  where a reader will find it, and update [CLAUDE.md](../CLAUDE.md).
* **T12. Re-measure.** `make lint`, `make test`, `make -C formal -k`, then
  `make utilization` against the `a9f2c0b` baseline.

## Risks

* **Timing on `fetch_valid_o`.** T0 exists to find this out on day one.
* **The saved-state divergence.** Settled: `R14` and `R15` only, one register
  short of the reference. Upstream's own best-practices rule for ISR authors is
  what makes that cheap. Retrofitting extra saved state into a `dp_ram`-backed
  register file later would still be a rewrite, so the decision stays made.
* **Golden-file churn.** T1's determinism choice is what protects against it.
* **Interaction with the HALT gate.** `p_halt_fetched` in `cpu.vhd` gates the
  ICACHE-to-DECODE handshake off when a `HALT` is handed to DECODE, and clears
  that gate on a flush. An interrupt grant is a new flush source, so check it
  cannot un-gate a `HALT` that has already been accepted.

