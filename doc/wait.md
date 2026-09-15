# A WAIT instruction: impact analysis

This is an assessment, not a design that has been implemented. It asks how much would have to
change to add a `WAIT` instruction to this CPU, so that the decision whether to include it can be
taken knowing the cost. Nothing described here exists in the RTL today.

## The proposal

`WAIT` is a new control instruction, **not part of the upstream QNICE ISA**. It behaves like
`HALT` with one difference: the CPU stops when it reaches `WAIT`, but it still reacts to a hardware
interrupt, which wakes it up. Once the service routine returns, execution proceeds as if no `WAIT`
had been encountered, that is at the instruction following it.

## Summary

The change is moderate. The RTL is small, roughly 30-50 lines across six files. Most of the work
is the formal properties, tests, and documentation that accompany any interrupt change in this
repository. The one real risk is timing. And it is not "`HALT` with a flag", for one structural
reason, explained next.

## Why it is not just a copy of HALT

In this CPU, a hardware interrupt is only ever taken **as an instruction retires**:

```vhdl
irq_is_irq_s <= inst_done_o when irq_valid_i = '1' and halt_o = '0' else '0';   -- write.vhd
```

A stopped CPU retires nothing, so no interrupt could ever be taken. `WAIT` therefore needs a
stand-in for that boundary: a new register in WRITE that stays set while the CPU is waiting.
Waking up is then an ordinary hardware interrupt entry. That entry already redirects FETCH, and a
redirect already clears `halt_fetched` in `src/cpu.vhd` (the gate that stops instructions entering
DECODE after a `HALT`). So the resume side comes almost for free.

## RTL changes

| File | Change |
|---|---|
| `src/cpu_constants.vhd` | `C_CTRL_WAIT := 6` (encodes as `0xE180`; control commands 6-31 are free, and 32-63 are `EXC` upstream), add it to `ctrl_str`, and add an `is_wait` field to the three stage records |
| `src/cpu_main/decode.vhd`, `sequencer.vhd`, `prepare.vhd` | Decode `is_wait` and carry it down the records, exactly like `is_rti`. Only needed if `WAIT`'s bit ends up on the `fetch_valid_o` path, which the rogue case below would put it on |
| `src/cpu.vhd` | `p_halt_fetched` also sets on `WAIT`. The clear needs no change, because waking raises `wr2fetch_valid` |
| `src/cpu_main/write.vhd` | The new waiting register (see below), wake-up terms on `fetch_valid_o`, `fetch_addr_o`, and `irq_ready_o`, and `WAIT` added to the list in `p_unimplemented` |

The detail inside `write.vhd` that matters most is **what to save, and when**. On entry today, the
CPU saves `R14` and the return address, computed from the instruction that is retiring
(`irq_r14_next`, `resume_pc`). While the CPU waits, PREPARE's output register holds no valid
instruction, so those values mean nothing at wake-up. The clean fix is to save `irq_r14` and
`irq_r15` **when `WAIT` retires**, and to skip the saves on wake-up.

The waiting register should be cleared on reset, on interrupt entry, and on any `inst_done_o`. The
last of these matters because formal verification of `cpu_main` cannot see the `halt_fetched` gate
in `cpu.vhd`: `ic_valid_i` is left free there, so the model will feed in further instructions after
the `WAIT`, and WRITE has to stay correct when it does.

## Decisions to make

1. **A request already pending when `WAIT` retires.** This falls out of the existing logic: the
   request is taken at that boundary, and `RTI` returns past the `WAIT`. The recommendation is to
   keep that.
2. **Lost wake-ups.** If a request arrives while `WAIT` is still in DECODE or PREPARE, it is taken
   at an earlier instruction's boundary. The resulting flush discards the `WAIT`, `RTI` fetches it
   again, and the CPU then sleeps until the *next* interrupt. QNICE has no interrupt-enable flag,
   so there is no atomic "check, then wait". Programs must wait in a loop that re-checks their
   condition, which is the classic idle-loop problem. This needs documenting, not fixing.
3. **`WAIT` inside a service routine.** Interrupts do not nest, so it would never wake. The
   recommendation is to treat it as rogue and halt, like a rogue `RTI` or `INT`. That is one more
   term on `irq_rogue_s`, and `irq_halted` already exists to stop the pipeline behind it.
4. **`halt_o`.** It should probably stay low while waiting, since the program has not run to
   completion. A separate `wait_o` output is optional. In simulation, a `WAIT` with no interrupt
   source ends at the `G_TIMEOUT` watchdog, not at a halt.

## Timing: the real cost

`fetch_valid_o` closes at **WNS +0.001 ns** at the 7.80 ns constraint (see
[hw/CLAUDE.md](../hw/CLAUDE.md)), and past edits of this size have moved it by 0.1 ns.

If the wake-up is ORed into `inst_done_o` inside `irq_is_irq_s`, it sits behind `halt_o`'s opcode
compare. The better shape is a separate term, `irq_waiting and irq_valid_i`: a flip-flop ANDed with
an input, which should fold into `fetch_valid_o`'s final OR the way `rst_i` does. Even so, the
result cannot be predicted without running `make system.bit`. Budget for a possible fifth
relaxation of the clock constraint.

## Everything around the RTL

- **Formal (`formal/cpu_main.psl`).** The properties assume that a boundary is `inst_done_o`.
  `f_irq_take`, `f_irq_ready_boundary`, and the `p_irq_shadow` model all need restating as
  "retiring, or waiting". New properties are needed for waking up and for the resume address, plus
  a cover. Guarantee 2 in [src/interrupt/README.md](../src/interrupt/README.md) ("only at an
  instruction boundary") changes with them.
- **Tests.**
  - A `test/prog_wait.asm` that arms the Interrupt Generator, executes `WAIT`, and then checks
    that the service routine ran, that execution resumed after the `WAIT`, and that `R14` was
    restored. It should also cover a request that is already pending at the `WAIT`.
  - A rogue program for `WAIT` inside a service routine, alongside
    `test/prog_int_rogue_rti.asm` and `test/prog_int_rogue_int.asm`.
  - Both must pass under `make test_slow`, and both need new golden files.
- **Toolchain.** Upstream's assembler does not know the mnemonic (`control_mnemonics[]` in
  `qasm.c`). Either the tests write `.DW 0xE180`, or the assembler is patched on the `develop`
  branch and the pinned commit in CI is bumped.
- **Crosscheck.** Upstream's emulator prints "Illegal control instruction" for control command 6
  and carries on, so `WAIT` is a no-op there. Upstream's RTL has not been checked. `WAIT` programs
  would need `KNOWN_DIVERGENCE` entries in `test/crosscheck.py`, unless each test busy-loops on a
  flag so that a no-op `WAIT` produces the same final memory.
- **Documentation.** A fourth deliberate divergence in [doc/interrupts.md](interrupts.md), the
  interrupts sections of [doc/README.md](README.md) and
  [src/cpu_main/README.md](../src/cpu_main/README.md), the `p_unimplemented` and divergence
  paragraphs in the top-level `CLAUDE.md`, and possibly the interrupt timing diagram in
  `src/interrupt/timing.tex`.

## Overall

About the size of the rogue-`RTI`/`INT` work, and much smaller than adding hardware interrupts was.
The design is clear. The only open question is whether `fetch_valid_o` will absorb one more term
without relaxing the clock again.
