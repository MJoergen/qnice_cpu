# Interrupt request interface

This directory will hold `interrupt.vhd`, the leaf module that turns the CPU's
interrupt request port into the commit handshake WRITE needs.

**Status: specification, not description.** The module does not exist yet — this
is task T2 of [doc/interrupts.md](../../doc/interrupts.md), and the diagram below
is task T2b. Everything here is what T2 has to implement, and what
`formal/interrupt.psl` has to check. Redraw the diagram against a real GHDL
simulation once the module runs, exactly as
[src/cpu_main/timing.tex](../cpu_main/timing.tex) is read off
`test/prog_waveform.asm`.

## The CPU does not speak the daisy chain

This page used to specify the QNICE `INT_N`/`IGRANT_N` daisy-chain protocol
directly on the CPU's pins. It no longer does, and the change is deliberate:
**this CPU is not a pin-compatible drop-in replacement for the original**, and an
adaptation layer around it is an accepted cost, exactly as it already is for the
instruction and data buses. The QNICE-FPGA side of that layer exists and is
described in `doc/cpu_replacement.md` there (commit `cfb0893`), where `env1.vhd`
already splits one memory map into a Harvard pair and speaks Wishbone to the CPU.

Three consequences, all of them design rules for what goes *inside* this
directory:

* **The CPU is agnostic of daisy chaining.** Position-is-priority, the grant
  pass-through, the wait-your-turn rules of upstream's `doc/int-device.md` — none
  of that appears here. It is an optional implementation detail of the
  surrounding system.
* **The CPU sees exactly one interrupt-generating device**, in the same way it
  sees exactly one memory on each of its other two buses. If several
  interrupt-capable devices are connected, something outside the CPU arbitrates
  between them and presents the winner.
* **The interface is an AXI-stream**, three signals wide: `irq_valid_i`,
  `irq_ready_o`, `irq_addr_i`. That is the same valid/ready discipline every
  stage boundary in this design already uses, so it needs no protocol of its own
  and no vocabulary of its own.

What this bought, measured against the daisy-chain specification it replaces: the
entire "tighter than upstream" divergence disappears (there is no grant, so
nothing has to be driven combinationally off one), the bus-turnaround rules
disappear (the address lines are point-to-point, not shared), `int_wait`
disappears, and interrupt entry costs the CPU **zero cycles** on top of the
redirect penalty a taken branch already pays, rather than two.

## The diagram

![Interrupt protocol timing](timing.png)

One hardware interrupt taken to completion, followed by a second request that
arrives while the ISR is still running and is therefore made to wait. Rendered
from [timing.tex](timing.tex) by `make diagrams`.

## Ports

| Port | Dir | Kind | Meaning |
|---|---|---|---|
| `irq_valid_i` | in | pin | A device is requesting an interrupt. Held until accepted. |
| `irq_addr_i` | in | pins, 16 bit | The ISR address. Valid whenever `irq_valid_i` is high. |
| `irq_ready_o` | out | pin, **registered**, one cycle | The request has been accepted. |
| `pending_o` | out | **registered** | A request is waiting and the module is idle. |
| `addr_o` | out | **registered**, held | The pending request's ISR address. |
| `start_i` | in | combinational | One-cycle commit pulse from WRITE. |

`irq_addr_i` is a port of its own rather than the data Wishbone; the reasoning is
in [doc/interrupts.md](../../doc/interrupts.md#the-interrupt-request-interface).

There is no `done_o`. The daisy-chain version had one, because the ISR address
did not exist until the grant handshake had fetched it and WRITE therefore could
not redirect at the commit point. Here the address arrives with the request, so
`addr_o` is already valid when WRITE decides to take the interrupt and the
redirect happens in the commit cycle itself.

`irq_valid_i` and `irq_addr_i` are assumed **synchronous to `clk_i`**. A device in
another clock domain must synchronise on its own side, because a 16-bit address
cannot be brought across a domain boundary by a flip-flop chain. The single
flip-flop behind `pending_o` is there to keep an external pin out of WRITE's
combinational logic, not as a CDC synchroniser — see
[The timing problem](../../doc/interrupts.md#the-timing-problem).

## Walking the diagram

* **t=1** A device asserts `irq_valid_i` and drives `irq_addr_i` in the same
  cycle. The CPU is mid-instruction, and nothing happens yet. A device may hold
  the request indefinitely; it must tolerate waiting arbitrarily long.
* **t=2** `pending_o` rises and `addr_o` holds the address, both one cycle later
  because both are registered.
* **t=3** `inst_done_o` and `pending_o` are both high and `int_active` is low, so
  WRITE pulses `start_i`. **This is the commit point, and it is also the
  redirect**: on this edge WRITE latches `R14` and `next_pc` and sets
  `int_active`, and in this same cycle it asserts `fetch_valid_o` with
  `fetch_addr_o` driven from `addr_o`. Once committed, the CPU cannot back out —
  there is no way to abort a request.
* **t=4** **The transfer.** `irq_ready_o` goes high for exactly one cycle,
  `irq_valid_i` still high. The accept is what *releases* the device; it is not
  what delivers the address, which the CPU registered at t=2 and consumed at t=3.
* **t=5** The device de-asserts `irq_valid_i` and stops driving `irq_addr_i`. The
  module leaves `ACCEPTED` on the edge that ends this cycle.
* **t=7** A device requests again, inside the ISR. `pending_o` rises at t=8, but
  `int_active` is high, so `start_i` never does — visibly so at t=8, where an ISR
  instruction retires with a request pending and no accept follows.
* **t=10** `RTI` retires. `int_active` clears on this edge and `fetch_valid_o`
  redirects FETCH to the restored PC. `start_i` stays low **during** t=10,
  because `int_active` is still high for the whole of that cycle.
* **t=11** `int_active` is low and the request is still pending, but
  `inst_done_o` is low — the instruction at the return address is still in
  flight. The second interrupt is accepted at the next instruction boundary.

## The handshake

`irq_valid_i`/`irq_ready_o` is an ordinary AXI-stream handshake, with
`irq_addr_i` as the payload:

1. The device asserts `irq_valid_i` and presents `irq_addr_i` in the same cycle.
2. It holds both steady until accepted. Valid never withdraws.
3. The CPU asserts `irq_ready_o` for one cycle to accept.
4. The device de-asserts `irq_valid_i` in the cycle after that.

Rule 4 is one notch stricter than AXI-stream, which would allow a device to hold
`irq_valid_i` high for a back-to-back transfer. Nothing is lost by it: the CPU
cannot accept a second interrupt until the current ISR has executed `RTI` *and*
one more instruction has retired (see below), so a back-to-back transfer is
unreachable in the first place. What it buys is that "a fresh request" is
unambiguous — the module returns to `IDLE` only after seeing `irq_valid_i` low,
so a device's trailing valid can never be mistaken for a new request, and
`pending_o` needs no other guard.

Unlike the daisy chain, **the data is valid whenever `VALID` is**. That is the
whole of what the adaptation layer absorbs: on a shared chain a device cannot
drive the address lines until a grant has said whose turn it is, so the data had
to follow the grant, and the CPU had to capture it in the single cycle the grant
was low. Point to point, with one device in front of the CPU, none of that
applies.

## Two things the diagram settles

**The accept follows the commit; it does not precede it.** The alternative — let
the module raise `irq_ready_o` as soon as `irq_valid_i` goes high and buffer the
address for WRITE to collect later — is wrong, and stays wrong even though the
address no longer has to be fetched. An accept is observable: it tells the
requesting device it is being serviced, and it is the device's cue to drop the
request and, in a daisy-chained system, the adaptation layer's cue to release the
chain to the next device. Accepting while an ISR is still running, or before the
CPU has decided to take the interrupt, says something untrue at the interface
however the CPU behaves internally. The ISA document specifies this ordering for
the daisy chain explicitly — "it will save `R14` and `R15` and then signals the
device" — and it is worth keeping. Unlike the daisy-chain version, **it now costs
nothing**: the accept trails the commit by one registered cycle and the CPU has
already redirected by then.

**One instruction always runs between two ISRs.** `start_i` is gated on
`int_active`, which is still high during the cycle `RTI` retires, so the earliest
a second interrupt can be accepted is the next instruction boundary after the
return. That guarantees forward progress: a device holding `irq_valid_i` high
forever cannot livelock the CPU into re-entering the ISR without executing
anything at the return address. It is a consequence of the gating rather than a
separate mechanism, but it is a property worth stating and worth a PSL cover.

## The contract

**The device must:**

1. Assert `irq_valid_i` and drive `irq_addr_i` in the same cycle.
2. Hold both steady until accepted — the cycle in which `irq_ready_o` is high.
   There is no way to abort a request: once asserted, the CPU will eventually
   accept it, and the address must still be valid then even if the interrupt has
   since been masked in software.
3. De-assert `irq_valid_i` in the cycle after the accept, and keep it low until
   it has a new request to make. A device that never releases it never gets a
   second interrupt.
4. Tolerate waiting arbitrarily long. An ISR may already be running, or the CPU
   may be mid-instruction.
5. Present exactly one request at a time. Arbitration between several
   interrupt-capable devices happens outside the CPU.

**The CPU must:**

1. Assert `irq_ready_o` only after committing — `R14` and `R15` saved,
   `int_active` set. This is what makes an accept mean "you are being serviced
   now" rather than "you may be serviced eventually".
2. Assert `irq_ready_o` only at an instruction boundary with no ISR active.
3. Hold `irq_ready_o` high for **exactly one cycle**, and only while
   `irq_valid_i` is high. The CPU never accepts speculatively.
4. Redirect FETCH to the address of the accepted request, and to no other.
5. Retire nothing between the saved return address and the redirect. This is free
   here — they are the same cycle — where the daisy-chain version needed an
   explicit `int_wait` stall to get it.

## What the adaptation layer has to do

Outside the CPU, and outside this repository. Recorded here only so that the
obligations above can be read as a whole. To front a QNICE daisy chain with this
interface, the layer must:

* drive `INT_N`/`IGRANT_N` and run the grant handshake against the chain,
  including the pass-through and priority rules;
* hold `irq_valid_i` and `irq_addr_i` steady across however many cycles that
  takes, which is the reason the CPU's side of the contract is a *held* request
  rather than a pulse;
* map the CPU's one-cycle `irq_ready_o` onto whatever the chain needs, which for
  the reference device means a `/IGRANT` low long enough for it to drive its ISR
  address, followed by capturing that address into `irq_addr_i`;
* arbitrate, if the system is not a chain but several independent devices.

None of that is this CPU's problem, and none of it can make this CPU wrong: the
layer either satisfies the five device obligations above or it does not.

## Open for T2

* Reset behaviour. `rst_i` must return the FSM to `IDLE` with `irq_ready_o` low.
  A reset asserted between the commit and the accept leaves a device still
  requesting, which is harmless — it will simply be accepted again after reset,
  and the CPU is starting from `PC = 0` anyway.
* `pending_o` must be qualified with "and the module is idle", not just
  "`irq_valid_i` is high": `pending_r <= '1' when irq_valid_i = '1' and state =
  IDLE and start_i = '0' else '0'`. The `start_i` term is what keeps `pending_o`
  from staying high through the commit; the `state` term is what stops the
  accepted device's trailing `irq_valid_i` from raising a phantom `pending_o`
  after the transfer. `int_active` would mask that phantom inside WRITE, but a
  formal property phrased on `pending_o` alone would trip over it.
* Whether `pending_o` should distinguish "requesting" from "requesting and
  acceptable"; the diagram assumes the former and lets WRITE apply `int_active`.
* Whether the module is worth its own entity at all, now that it is two states
  and a pair of registers rather than a protocol FSM. **Provisional decision:
  yes.** It keeps two external pins out of CPU_MAIN, which is where the timing
  margin is; it gives the contract above one place to live and one
  `formal/interrupt.psl` to be checked in; and it matches how every other
  interface in this design is built. But it is a cheap decision to reverse, and
  whoever writes T2 should reverse it if the entity turns out to be nothing but
  wires.
* `formal/interrupt.{psl,sby,gtkw}`: the contract above is written as five and
  five obligations precisely so that each becomes an assumption or an assertion.
  The device's five are assumptions, the CPU's five are assertions, and the two
  properties in the section above are covers.
