# Interrupt daisy-chain interface

This directory will hold `interrupt.vhd`, the leaf module that hides the QNICE
`INT_N`/`IGRANT_N` daisy-chain protocol behind a plain handshake to WRITE.

**Status: specification, not description.** The module does not exist yet — this
is task T2 of [doc/interrupts.md](../../doc/interrupts.md), and the diagram below
is task T2b, drawn ahead of it because the bus protocol was the part of the
feature the upstream sources disagreed about most. Everything here is what T2 has
to implement, and what `formal/interrupt.psl` has to check. Redraw the diagram
against a real GHDL simulation once the module runs, exactly as
[src/cpu_main/timing.tex](../cpu_main/timing.tex) is read off
`test/prog_waveform.asm`.

## The diagram

![Interrupt protocol timing](timing.png)

One hardware interrupt taken to completion, followed by a second request that
arrives while the ISR is still running and is therefore made to wait. Rendered
from [timing.tex](timing.tex) by `make timing`.

## Ports

| Port | Dir | Kind | Meaning |
|---|---|---|---|
| `int_n_i` | in | pin, active low | A device is requesting an interrupt. |
| `igrant_n_o` | out | pin, active low, **registered** | Committed; the device may drive the bus. |
| `isr_addr_i` | in | pins, 16 bit | The ISR address. Valid only while `igrant_n_o` is low. |
| `pending_o` | out | **registered** | A request is waiting and the module is idle. |
| `start_i` | in | combinational | One-cycle commit pulse from WRITE. |
| `done_o` | out | **registered**, one cycle | `addr_o` now holds a captured ISR address. |
| `addr_o` | out | **registered**, held | The captured ISR address. |

`isr_addr_i` is a port of its own rather than the data Wishbone; the reasoning is
in [doc/interrupts.md](../../doc/interrupts.md#bus-protocol).

`int_n_i` and `isr_addr_i` are assumed **synchronous to `clk_i`** — the daisy
chain is a synchronous bus and every device on it shares the CPU clock. A device
in another clock domain must synchronise on its own side, because a 16-bit
address cannot be brought across a domain boundary by a flip-flop chain. The
single flip-flop behind `pending_o` is there to keep an external pin out of
WRITE's combinational logic, not as a CDC synchroniser.

## Walking the diagram

* **t=1** A device pulls `int_n_i` low. The CPU is mid-instruction, and nothing
  happens yet. A device may hold this low indefinitely; it must tolerate waiting
  arbitrarily long.
* **t=2** `pending_o` rises, one cycle later, because it is registered.
* **t=3** `inst_done_o` and `pending_o` are both high and `int_active` is low, so
  WRITE pulses `start_i`. **This is the commit point**: on this edge WRITE
  latches `R14` and `next_pc`, sets `int_active`, and raises `int_wait`. Once
  committed, the CPU cannot back out — there is no way to abort a request.
* **t=4** `igrant_n_o` goes low. The device drives `isr_addr_i` combinationally
  in the same cycle, and — following `vhdl/timer.vhd` upstream — still holds
  `int_n_i` low for this one cycle.
* **t=5** The device raises `int_n_i` to say the address is valid. The module
  captures `isr_addr_i` on the edge at the end of this cycle, while `igrant_n_o`
  is still low.
* **t=6** `igrant_n_o` returns high, `done_o` pulses, `addr_o` holds the address.
  WRITE asserts `fetch_valid_o` in this same cycle, redirecting FETCH to the ISR,
  and drops `int_wait`. The device sees the grant released and stops driving the
  bus — but the CPU already has the address in a register and no longer cares
  (see [What is deliberately not required](#what-is-deliberately-not-required)).
* **t=7** The first ISR instruction is on its way. Total cost from commit to
  redirect: **three cycles**, on top of the redirect penalty a taken branch pays
  anyway.
* **t=8** A device requests again, inside the ISR. `pending_o` rises at t=9, but
  `int_active` is high, so `start_i` never does — visibly so at t=9, where an ISR
  instruction retires with a request pending and no grant follows.
* **t=11** `RTI` retires. `int_active` clears on this edge and `fetch_valid_o`
  redirects FETCH to the restored PC. `start_i` stays low **during** t=11,
  because `int_active` is still high for the whole of that cycle.
* **t=12** `int_active` is low and the request is still pending, but
  `inst_done_o` is low — the instruction at the return address is still in
  flight. The second grant follows at the next instruction boundary.

## The contract

**The device must:**

1. Pull `int_n_i` low to request, and hold it low until granted.
2. Drive `isr_addr_i` from the first cycle in which it observes `igrant_n_o` low,
   and hold it stable for as long as `igrant_n_o` stays low.
3. Not raise `int_n_i` before `isr_addr_i` is valid. `int_n_i` high while
   `igrant_n_o` is low **is** the statement "the address on the bus is good".
4. Release the bus once it observes `igrant_n_o` high again. Any cycle at or
   after that will do.
5. Never interfere with a transaction already in progress further down the
   chain — the pass-through and wait-your-turn rules of
   [`doc/int-device.md`](https://github.com/sy2002/QNICE-FPGA/blob/dev-V1.61/doc/int-device.md)
   upstream, which this CPU does not police.

**The CPU must:**

1. Assert `igrant_n_o` only after committing — `R14` and `R15` saved,
   `int_active` set. The ISA document specifies this ordering explicitly, and it
   is what makes a grant mean "you are being serviced now" rather than "you may
   be serviced eventually".
2. Assert `igrant_n_o` only at an instruction boundary with no ISR active.
3. Sample `isr_addr_i` on the first edge at which `igrant_n_o` is low and
   `int_n_i` is high.
4. Release `igrant_n_o` in the cycle after that sample, and redirect FETCH in the
   same cycle.
5. Retire nothing between the commit and the redirect — see `int_wait` below.

## Three things the diagram settles

**The grant follows the commit; it does not precede it.** The alternative — let
the module run the handshake as soon as `int_n_i` goes low and buffer the address
for WRITE to collect later — would produce the address a cycle or two sooner, and
is wrong. A grant is observable: it tells the requesting device it is being
serviced, and it releases the daisy chain to the next device. Issuing one while
an ISR is still running, or while the CPU has not yet decided to take the
interrupt, breaks the no-nesting rule at the bus level however the CPU behaves
internally. The cost of doing it correctly is the three-cycle stall at t=4..t=6.

**`int_wait` is not optional.** Between the commit at t=3 and the redirect at
t=6, the saved PC is already fixed but DECODE and PREPARE still hold the
instructions that follow it. If one of them retired in that window it would
change architectural state *after* the return address, and `RTI` would replay it.
So WRITE holds its ready to PREPARE low for those three cycles. This is ordinary
back-pressure — the same stall a memory access already applies — not new
machinery. It is a different mechanism from `p_halt_fetched` in `cpu.vhd`, which
gates the Icache-to-DECODE handshake instead; gating the feed is not enough here,
because the instructions in question have already been fetched.

**One instruction always runs between two ISRs.** `start_i` is gated on
`int_active`, which is still high during the cycle `RTI` retires, so the earliest
a second interrupt can be granted is the next instruction boundary after the
return. That guarantees forward progress: a device holding `int_n_i` low forever
cannot livelock the CPU into re-entering the ISR without executing anything at
the return address. It is a consequence of the gating rather than a separate
mechanism, but it is a property worth stating and worth a PSL cover.

## What is deliberately not required

The device does **not** have to release the bus combinationally. An earlier draft
of [doc/interrupts.md](../../doc/interrupts.md) required that, on the assumption
that the CPU would use `isr_addr_i` directly. It does not: the address is
captured into `addr_o` on the edge ending t=5, so by the time `igrant_n_o` goes
high at t=6 the bus can take as long as it likes to turn around. The weaker rule
— hold while granted, release any time after the grant drops — is what
`vhdl/timer.vhd` upstream already satisfies, and adding a constraint upstream
does not impose would have made conforming devices non-conforming here for no
gain.

## Open for T2

* Reset behaviour. `rst_i` must return the FSM to `IDLE` with `igrant_n_o` high.
  Whether a reset asserted mid-grant needs to do anything for the device beyond
  releasing the grant is an open question — the daisy chain has no reset line.
* Whether `pending_o` should distinguish "requesting" from "requesting and
  grantable"; the diagram assumes the former and lets WRITE apply `int_active`.
* `formal/interrupt.{psl,sby,gtkw}`: the contract above is written as five and
  five obligations precisely so that each becomes an assumption or an assertion.
  The device's five are assumptions, the CPU's five are assertions, and the three
  properties in the section above that are covers.
