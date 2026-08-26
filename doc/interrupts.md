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
repository: `doc/int-device.md` for the bus protocol,
`doc/intro/qnice_intro.tex` (the Interrupts slides) for the programmer's model,
and `vhdl/qnice_cpu.vhd` plus `vhdl/register_file.vhd` for what the reference
CPU actually does, which is not in every respect what the slides say.

DECISION: When external evidence is contradicting, use the following priority:
1. Ground truth is ISA (documented in doc/intro/qnice_intro.tex)
2. For questions not answered in the ISA document, the definitive source is then
   doc/int-device.md.
3. If there are any discrepencies between any of these external sources, then
   list them clearly, and document the implemented choice.

### Bus protocol

Two active-low lines: `INT_N` in, `IGRANT_N` out. Devices form a daisy chain in
which position is priority — the closer to the CPU, the higher.

1. A device pulls `INT_N` low to request. It may hold it low indefinitely and
   must tolerate waiting arbitrarily long, because an ISR may already be
   running or a higher-priority device may be ahead of it.
2. When the CPU can service it, the CPU pulls `IGRANT_N` low. The device then
   drives the address of its ISR onto the data bus.
3. The device pulls `INT_N` high once that address is valid.
4. The CPU samples the address and releases `IGRANT_N`. The device must release
   the bus **combinationally** — the CPU starts fetching on the next cycle.

There is no way to abort a request. Once a device has asked, the CPU will
eventually grant, and the device must have a valid ISR address to supply even if
the interrupt has since been masked in software.

DECISION: Port names are to be lower case (snake case?) following the
CODING_STYLE.md. This means "int_n_i" and "igrant_n_o".

DECISION: Make a timing diagram (similar to src/cpu_main/timing.tex) that shows
the relationship between the important signals (e.g. int_n_i, igrant_n_o, wbd_data_i).
Particularly important is whether changes are registered (i.e. delayed until
next clock cycle) or combinatorial.  The current design already allows for data
input to be registered.

### Programmer's model

* **Interrupts do not nest.** A request is granted only when no ISR is already
  running. The reference gates this on `Int_Active` at instruction fetch
  (`qnice_cpu.vhd:476`).
* **`R14` (SR) and `R15` (PC) are saved** into latches invisible to software.
* **`RTI`** restores them, clears the in-ISR state and resumes.
* **`INT <dst op>`** is a software interrupt; the destination operand supplies
  the ISR address. The reference accepts all four addressing modes
  (`qnice_cpu.vhd:561`-`582`).
* **A rogue `RTI`** — one executed outside an ISR — halts the CPU
  (`qnice_cpu.vhd:550`). So does a **rogue `INT`**, one executed inside an ISR
  (`qnice_cpu.vhd:586`).
* Bit 0 of the SR is always 1. This design already does that, in `alu_flags.vhd`
  (`sr_o <= sr_i or X"0001"`).

### `EXC` is out of scope, and that is not a shortcut

Upstream `vhdl/cpu_constants.vhd` defines `ctrlHALT`, `ctrlRTI`, `ctrlINT`,
`ctrlINCRB` and `ctrlDECRB` and stops there. There is no `ctrlEXC` and no case
arm for it; it falls into `when others => HALT`. Only the *assembler* knows the
mnemonic, at `assembler/qasm.c:41`, and emits `5` for it.

So `EXC` has never been implemented in QNICE hardware. Keep its arm of
`p_unimplemented` armed, along with reserved opcode `0xD`, and drop only the
`RTI` and `INT` arms.

## The decision to make first: what state is saved

The slides say two latches, for `R14` and `R15`. **The reference implementation
does more than that.** `register_file.vhd` continuously mirrors `R8`-`R15` into
shadow copies whenever `Int_Active = '0'`, and `RTI` reverts all of them —
see the loop at `register_file.vhd:199`, commented "revert R8 .. R15". Shadowing
stops while an ISR runs, so the shadows freeze at their pre-interrupt values and
no explicit save step is needed. An ISR gets a private `R8`-`R12` for free.

That model does not fit here:

* The register file is backed by [dp_ram.vhd](../src/sub/dp_ram.vhd), which has
  **one write port**. Reverting five registers is not a single-cycle operation
  on a RAM.
* A continuous mirror needs a second writer into the same array, which is
  precisely what that module's header explains cannot be inferred.

**Recommendation: save `R14` and `R15` only**, and write the divergence down.
That matches the published programmer's model, and this CPU is already not a
drop-in replacement for the original. The cost is that an ISR must preserve
`R8`-`R12` itself — ordinary practice elsewhere, and the register bank
(`INCRB`) already offers a cheaper answer for code that wants private
registers.

The cost is real, though: upstream software that assumes a private `R8`-`R12`
inside an ISR would break. Decide this before starting, because retrofitting
shadow registers into a `dp_ram`-backed file later is a rewrite, not a patch.

DECISION: I follow your advice; only R14 and R15 are saved.

## How it fits this pipeline

### Three things already fit

* **The return address already exists, and is already correct.**
  `write.vhd:391` computes

  ```vhdl
     next_pc <= prep_stage_i.addr + 2 when (src_imm = '1' or dst_imm = '1') else
                prep_stage_i.addr + 1;
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
  JMP's microcode to carry `REG_WRITE` with `res_reg = R15` (`decode.vhd:181`),
  which routes the target through `res_other`. Both instructions reuse that path
  unchanged, and get the pipeline flush that comes with any write to `R15`.

### Two things constrain the design

* **The interrupt state must live in WRITE.** `cpu_main.vhd` resets DECODE and
  PREPARE with `rst_i or fetch_valid_o`, so every flip-flop in those two stages
  is cleared by every flush — including the flush that interrupt entry itself
  causes. The in-ISR flag and the saved `R14`/`R15` must sit in WRITE, which is
  not on that net, or outside `cpu_main` entirely.

* **The grant handshake is multi-cycle**, so it does not belong inline in WRITE.
  It should be a leaf module, `src/interrupt/interrupt.vhd`, presenting a
  valid/ready interface to the CPU and hiding the `INT_N`/`IGRANT_N` protocol
  behind it. That is how every other protocol FSM in this design is built, and
  it gets the usual `.psl`/`.sby`/`.gtkw` triplet in `formal/`.

### The timing problem

`fetch_valid_o` currently fits a **single 6-input LUT**: `reg_we_o`, three
address bits, `inst_done_o` and `is_crb` (see the note above `is_crb` in
[write.vhd](../src/cpu_main/write.vhd)). An interrupt grant is a fourth term,
which pushes it to two levels of logic on a net that is the reset pin of two
entire pipeline stages.

The budget is **+0.135 ns** — see [Utilization](README.md#Utilization), measured
at commit `a9f2c0b`. For scale, adding the register-bank flush alone cost
0.098 ns, and placement noise unrelated to any edit has been measured at up to
0.284 ns. This is the single risk most likely to invalidate the approach, which
is why it is measured first rather than last.

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
   the `+2` path of `next_pc`.
7. `INT` immediately after `INCRB`, with an ISR that changes the bank. Checks
   the bank-change flush still holds across an interrupt.

Cases 2 and 5 are the ones most likely to actually fail. Case 6 should pass on
day one, for the reason given above; if it does not, `next_pc` is not being used
where it should be.

Not happy path, but both need deciding and testing: rogue `RTI` and rogue `INT`.
The reference halts on both.

## Task plan

### Phase 0 — de-risk

* **T0. Timing spike.** Add a throwaway fourth term to `fetch_valid_o`, run
  `make system.bit`, record the WNS, discard the change. If it comes back
  negative the answer is to restructure — for instance by registering the grant
  a cycle earlier so it arrives as one pre-computed bit — and it is far cheaper
  to learn that now than after the ISA work is done. **Done when** a measured
  WNS for a four-term `fetch_valid_o` exists.

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

* **T2. `src/interrupt/interrupt.vhd`.** The daisy-chain FSM: request in,
  `IGRANT_N` out, ISR address out over valid/ready. Plus
  `formal/interrupt.{psl,sby,gtkw}`. **Done when** `sby` passes bmc, cover and
  prove.

### Phase 2 — CPU core

* **T3. Interrupt state.** The in-ISR flag and the saved `R14`/`R15`, in WRITE.
  Grant gated on `inst_done_o and not int_active`.
* **T4. `RTI`.** Restore `R15` through the ordinary write port and `R14` through
  the SR port in one cycle; clear the in-ISR flag. The write to `R15` already
  drives the flush. Rogue `RTI` halts.
* **T5. `INT <dst op>`.** Latch `R14` and `next_pc`, set the in-ISR flag,
  redirect through the JMP microcode path. Direct mode is the happy path;
  indirect modes need a memory read first. Rogue `INT` halts.

  DECISION: Make it so that test cases 1, 2, and 3 above (in the happy path) can
  be verified as working by this point in the development process.

* **T6. Hardware grant.** Consume T2's output at `inst_done_o`, take `next_pc`
  as the return address, add the fourth term to `fetch_valid_o`.
* **T7. Top-level ports.** `int_n_i` and `igrant_n_o` on
  [cpu.vhd](../src/cpu.vhd) and `system.vhd`.

### Phase 3 — close it out

* **T8. Test programs.** The seven cases above plus the two rogue cases.
  Regenerate the golden files and read the diff carefully.

  DECISION: This is moved to T1 above.

* **T9. Formal.** Extend [cpu_main.psl](../formal/cpu_main.psl): no grant while
  an ISR is active; `RTI` restores both registers; a grant asserts
  `fetch_valid_o`; the saved PC equals `next_pc`. Model them on the existing
  `f_flush_on_bank_change`, which states the same kind of obligation.
* **T10. Disarm the trap.** Drop the `RTI` and `INT` arms of `p_unimplemented`,
  keep `EXC` and opcode `0xD`, and update the list in
  [test/README.md](../test/README.md).
* **T11. Documentation.** Fold this note into
  [doc/README.md](README.md), delete its TODO bullet, record the `R8`-`R12`
  divergence where a reader will find it, and update
  [CLAUDE.md](../CLAUDE.md).
* **T12. Re-measure.** `make lint`, `make test`, `make -C formal -k`, then
  `make utilization` against the `a9f2c0b` baseline.

## Risks

* **Timing on `fetch_valid_o`.** T0 exists to find this out on day one.
* **The `R8`-`R12` divergence.** Decide before T3. Retrofitting shadow
  registers into a `dp_ram`-backed register file later is a rewrite.
* **Golden-file churn.** T1's determinism choice is what protects against it.
* **Interaction with the HALT gate.** `p_halt_fetched` in `cpu.vhd` gates the
  Icache-to-DECODE handshake off when a `HALT` is handed to DECODE, and clears
  that gate on a flush. An interrupt grant is a new flush source, so check it
  cannot un-gate a `HALT` that has already been accepted.

