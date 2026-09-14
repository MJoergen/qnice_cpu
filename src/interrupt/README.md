# Interrupt request interface

The CPU's hardware interrupt port: three signals on [cpu.vhd](../cpu.vhd),
`irq_valid_i`, `irq_ready_o`, and `irq_addr_i`. **This directory holds no VHDL.**
The port is implemented inside WRITE, in
[src/cpu_main/write.vhd](../cpu_main/write.vhd); what lives here is this
description and the timing diagram, which is read off a simulation. The design
history, the decisions, and the upstream sources they were weighed against are
in [doc/interrupts.md](../../doc/interrupts.md).

## The CPU does not speak the daisy chain

Upstream QNICE-FPGA connects interrupt-capable devices to the CPU through the
`INT_N`/`IGRANT_N` daisy chain of its `doc/int-device.md`. This CPU does not,
and deliberately: **it is not a pin-compatible drop-in replacement for the
original**, and an adaptation layer around it is an accepted cost, exactly as it
already is for the instruction and data buses. The QNICE-FPGA side of that layer
exists and is described in `doc/cpu_replacement.md` there (commit `cfb0893`),
where `env1.vhd` already splits one memory map into a Harvard pair and speaks
Wishbone to the CPU.

Three design rules follow:

* **The CPU is agnostic of daisy chaining.** Position-is-priority, the grant
  pass-through, and the wait-your-turn rules — none of that appears here. It is
  an optional implementation detail of the surrounding system.
* **The CPU sees exactly one interrupt-generating device**, in the same way it
  sees exactly one memory on each of its other two buses. If several
  interrupt-capable devices are connected, something outside the CPU arbitrates
  between them and presents the winner.
* **The interface is a valid/ready handshake**, three signals wide — the same
  discipline every stage boundary in this design already uses. It is AXI-stream
  with one rule relaxed: a device may withdraw a request (see
  [The handshake](#the-handshake)).

## The diagram

![Interrupt protocol timing](timing.png)

One hardware interrupt taken at the instruction boundary it arrives at, followed
by a second request that arrives while the service routine is still running and
is therefore made to wait. Read off a simulation of
`test/prog_int_waveform.asm`, which is in `TESTS` so that a change invalidating
the diagram fails the golden diff, and rendered from [timing.tex](timing.tex) by
`make diagrams`.

## Walking the diagram

Nothing in the handshake is registered. WRITE looks at `irq_valid_i` and
`irq_addr_i` in the cycle an instruction retires, and `irq_ready_o`,
`fetch_valid_o`, and `fetch_addr_o` all follow combinationally in that same
cycle. The only state is `irq_active` and the saved `irq_r15` (and `irq_r14`, not
drawn), which change on the edge that ends a cycle with a transfer or an `RTI`.

* **t=0** The main program is running through padding at `0010`, one instruction
  retiring per cycle. No request.
* **t=1** The device asserts `irq_valid_i` with `irq_addr_i = 002A`, in the cycle
  `0011` retires. **This is the transfer, the commit, and the redirect, all in
  one cycle**: `irq_ready_o` is high, `fetch_valid_o` sends FETCH to `002A`, and
  `resume_pc` — the address execution would otherwise have continued at, here
  `0012` — is latched into `irq_r15` on the edge that ends the cycle, together
  with `irq_active`. A request that arrives at an instruction boundary costs no
  cycles of its own beyond the redirect.
* **t=2** The device has dropped `irq_valid_i`, and scrambles `irq_addr_i` so
  that a CPU capturing it late would fail. `irq_active` is high. Nothing retires
  for four cycles while the pipeline refills from `002A`, the same penalty a
  taken branch pays.
* **t=6 to t=8** ISR1 retires its first three instructions; the second of them,
  at `002B`, is the write that asks the device for another interrupt.
* **t=9** The device asserts `irq_valid_i` again, with `002F`. `002D` retires,
  but `irq_active` is high, so `irq_ready_o` stays low: interrupts do not nest.
* **t=10** The `RTI` at `002E` retires. `fetch_valid_o` returns to `irq_r15`,
  `0012`, and `irq_active` clears on the edge that ends the cycle. The request is
  refused **during** t=10, because `irq_active` is still high for the whole of
  it.
* **t=11 to t=14** `irq_active` is low and the request is still held, but nothing
  retires while the pipeline refills from `0012`, and a request is only taken at
  a boundary.
* **t=15** `0012`, the first instruction back in the main program, retires, and
  request 2 is taken exactly as request 1 was: accepted, redirected to `002F`,
  and `0013` saved.

Two things follow. t=10 to t=15 are **guarantee 6 of
[the contract](#the-contract)**: request 2 was pending throughout, yet `0012`, the
instruction at the return address, retires before it is taken. And **a device
may withdraw**: a request dropped before the cycle it would be taken in is simply
never seen, because nothing remembers it.

## Ports

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `irq_valid_i` | in | 1 | A device is requesting an interrupt. May be withdrawn at any time before it is accepted. |
| `irq_addr_i` | in | 16 | The service routine's address. Read only in the cycle the request is accepted. |
| `irq_ready_o` | out | 1 | **Combinational.** High for the one cycle in which the request is accepted. |

All three are active high and **synchronous to `clk_i`**. A device in another
clock domain must synchronise on its own side: a 16-bit address cannot be brought
across a domain boundary by a flip-flop chain, and nothing inside the CPU
registers the port.

`irq_addr_i` is a port of its own rather than a read on the data Wishbone; the
reasoning is in
[doc/interrupts.md](../../doc/interrupts.md#the-interrupt-request-interface).

## How WRITE implements it

The interrupt state has to live in WRITE. `cpu_main.vhd` resets DECODE and
PREPARE with `rst_i or fetch_valid_o`, so everything in those two stages is
cleared by every flush — including the one interrupt entry causes. WRITE is not
on that net.

### When a request is taken

At the boundary after an instruction retires (`inst_done_o`), when
`irq_valid_i` is high — unless:

* **a service routine is running** (`irq_active`). Interrupts do not nest. This
  includes the cycle an `RTI` retires in: `irq_active` clears on the edge that
  ends it, so a request present then is taken at the next boundary, after the
  instruction at the return address. That is not an accident of the
  implementation but a requirement, guarantee 6 of
  [the contract](#the-contract).
* **the retiring instruction is a `HALT`** (`irq_is_irq_s`). After a `HALT`
  there is no next boundary; taking the request would restart a stopped CPU.
  `test/prog_int_halt.asm` is the test.
* **it is an `INT`**, which enters a service routine of its own and takes
  priority. The request waits for that routine's `RTI`, and one instruction more.
* **it is a rogue `RTI` or `INT`**, which halts the CPU (`irq_rogue_s`). Once
  halted, WRITE accepts nothing ever again (`irq_halted`).
* **the CPU is in reset.**

Otherwise the request is taken **at the first boundary it is present at**, with
no latency of its own: a request that arrives in the cycle an instruction
retires is taken in that cycle.

### What entry does

All in the one cycle the request is taken (`p_irq_sw`): `irq_ready_o` is high,
and `fetch_valid_o` flushes DECODE and PREPARE and redirects FETCH to
`irq_addr_i`. The retiring instruction's own effects — register writes, memory
writes, and flags — complete as they would have anyway. On the edge that ends the
cycle (`p_irq`), `irq_active` is set, and the state the routine must return to is
saved:

* `irq_r15` gets `resume_pc`: the branch target if the retiring instruction
  writes `R15`, and the address of the next instruction otherwise. A request
  taken as a taken branch retires resumes at the target, not after the branch.
* `irq_r14` gets `irq_r14_next`: `R14` as the retiring instruction leaves it,
  through whichever of the register file's two write ports wins.

Saving the pre-instruction values instead was the first implementation, and
wrong for every instruction that changes either register; Tests 6H, 6I, and 6J
in `test/prog_int_hw.asm` are the tests. An `RTI` restores `R14` through the
ordinary register port and redirects FETCH to `irq_r15` in one cycle, and clears
`irq_active`.

Entry costs **no cycles beyond the redirect**: the refill from the service
routine's address is the same penalty a taken branch pays (four cycles in the
diagram).

## The handshake

1. The device asserts `irq_valid_i` and presents `irq_addr_i`.
2. Until the request is accepted, the device may hold it, change the address, or
   withdraw it, on any cycle. The CPU reads neither signal except in the cycle
   it accepts.
3. The CPU asserts `irq_ready_o` for exactly one cycle, the one in which it takes
   the request. `irq_ready_o` depends combinationally on `irq_valid_i`, which
   AXI permits; the device must therefore not make `irq_valid_i` depend
   combinationally on `irq_ready_o`.
4. The request is consumed by the accept. An `irq_valid_i` still high on the next
   cycle is a **new** request, and will be taken after the `RTI`. A device with
   one request to make drops `irq_valid_i` the cycle after the accept, as
   `test/interrupt.vhd` does.

Rule 2 is where this departs from AXI-stream, which forbids withdrawing a valid.
It costs the CPU nothing — nothing inside it remembers a request — and it is what
upstream's own masking mechanism needs: the ISA has no CPU-side interrupt mask,
and upstream's answer is an external register gating the request line
(`vhdl/interrupt_controller.vhd`), which drops a request on whatever cycle
software's write lands. It does not make masking as prompt as upstream's, which
is a divergence of its own; see below.

**The accept is the commit.** There is no cycle in which the CPU has accepted a
request it has not yet acted on, or acted on one it has not accepted: the accept,
the redirect, and the save of the return state are one cycle. The ISA document's
order — "it will save `R14` and `R15` and then signals the device" — is met
within that cycle.

## The contract

**The device must:**

1. Keep `irq_valid_i` and `irq_addr_i` synchronous to `clk_i`.
2. Present a valid address in every cycle `irq_valid_i` is high, since any of
   them may be the one it is accepted in.
3. Drop `irq_valid_i` after an accept unless it has another request to make.
4. Tolerate waiting arbitrarily long: a service routine may be running, an
   instruction may be stalled on memory, and a halted CPU never accepts.
5. Present one request at a time. Arbitration between several devices happens
   outside the CPU.
6. Not derive `irq_valid_i` combinationally from `irq_ready_o`.

There is no obligation to hold a request.

**The CPU guarantees**, each asserted in
[formal/cpu_main.psl](../../formal/cpu_main.psl) against a shadow model built
from the retire pulse, the request pin, and the instruction encoding:

1. `irq_ready_o` only while `irq_valid_i` is high (`f_irq_ready_requested`).
2. Only at an instruction boundary, and never in reset (`f_irq_ready_boundary`).
3. Never while a service routine is running (`f_irq_ready_not_nested`), never at
   a `HALT` or `INT` (`f_irq_ready_not_ctrl`), and never after a rogue
   instruction has halted the CPU (`f_halted_quiet`).
4. Otherwise, the request is taken at the first boundary it is present at, and
   FETCH is redirected to that cycle's `irq_addr_i` (`f_irq_entry`).
5. The `RTI` returns to the address execution would otherwise have continued at,
   and restores `R14` as the interrupted instruction left it (`f_rti_return`,
   `f_rti_restore_r14`).
6. **The interrupted program makes progress.** A request is never taken at an
   `RTI` (`f_irq_progress`), so after every service routine the instruction at
   the return address retires before another request is accepted — even one that
   was pending throughout. By 4 it is then taken at that very boundary
   (`c_irq_after_rti` shows it). A device that requests again as soon as it is
   serviced therefore slows the interrupted program to one instruction per
   service routine, but cannot starve it. **Upstream's CPU does not do this**; see
   [Where this diverges from upstream](#where-this-diverges-from-upstream).
   `test/prog_int_progress.asm` is the test.

`irq_ready_o` is one cycle wide as a consequence of 3: the cycle after an accept,
`irq_active` is set.

The request port is left **entirely unconstrained** in that proof, so the CPU's
guarantees rest on none of the device's obligations. The obligations exist for
the device's own sake: a device that breaks 2 gets a wrong service routine, and
one that breaks 3 gets serviced twice. `formal/interrupt.psl`, despite its name,
verifies the test device `test/interrupt.vhd`, not the CPU.

## Timing

`irq_valid_i` reaches `fetch_valid_o` combinationally, and `fetch_valid_o` is the
reset of every flip-flop in DECODE and PREPARE — the net in this design with the
least margin to spare. `irq_ready_o` leaves the CPU late in the cycle, since it is
combinational in the retire decision.

**It has been measured.** `test/system.vhd` synthesises the Interrupt
Generator as well, as a listen-only tap on the data bus, so that `irq_valid_i` is
driven by a register in the bitstream just as a device would drive it. The
request path is not critical: its worst path, from the generator's
`irq_valid_o` register, has +1.627 ns of slack at the 7.80 ns constraint. What
the port did cost was indirect. The interrupt logic that had been folding away is
merged into WRITE's existing flush and operand cones, that moved the placement of
the routing-dominated paths this design is limited by, and the build failed at
7.70 ns until the constraint was relaxed; see
[doc/README.md](../../doc/README.md#utilization). A system whose device drives
the port from logic deeper than one register may still need the request
registered in the adaptation layer, at the cost of one cycle of latency —
provided that register is cleared by `irq_ready_o`, or a request would survive
its own accept and be taken a second time.

## Where this diverges from upstream

* **No `INT_N`/`IGRANT_N` pins.** An adaptation layer is needed; see below.
* **`R14` and `R15` are saved, not `R8`-`R15`.** Upstream's register file and
  emulator on `develop` save eight shadow registers, and `EXC` exchanges them;
  this CPU follows the ISA document's two latches, and has no `EXC`. See
  [doc/interrupts.md](../../doc/interrupts.md#the-decision-to-make-first-what-state-is-saved).
* **The interrupted program makes progress.** Upstream's `RTI` goes straight to
  `cs_fetch`, which tests for a pending interrupt *before* it latches the next
  instruction, so a request pending at the `RTI` is taken with nothing of the
  interrupted program run, and back-to-back requests can starve it. This CPU runs
  the instruction at the return address first (guarantee 6).
  `test/prog_int_progress.asm` is a known divergence against upstream's RTL for
  exactly this reason. **A request pending at a `HALT`** is the special case:
  upstream takes it and never executes the `HALT`, this CPU executes the `HALT`,
  and `test/prog_int_halt.asm` diverges the same way.
* **Masking lands later.** Upstream's unpipelined CPU cannot be interrupted after
  the instruction that writes its mask register. This CPU retires that
  instruction before the write reaches the bus, so the boundary after it is
  always open, and more are when the bus is slow or the mask reaches
  `irq_valid_i` through a register. Software can read the mask register back to
  close the window from the read-back on. See
  [doc/interrupts.md](../../doc/interrupts.md#masking-and-why-it-lands-later-than-upstream).
* **A rogue `RTI` or `INT` halts**, which is what upstream does too, but neither
  ISA document specifies it.

## What the adaptation layer has to do

Outside the CPU, and outside this repository. A QNICE-FPGA system's interrupt
sources — the timers and the VGA scanline interrupt, each behind upstream's
`vhdl/daisy_chain.vhd`, with `vhdl/interrupt_controller.vhd` in front of the
chain — speak upstream's `INT_N`/`IGRANT_N` protocol, `doc/int-device.md`, and
expect the CPU at the left end of the chain. The layer takes that place. Towards
the chain it behaves as upstream's CPU does; towards this CPU it is the single
device of [the handshake](#the-handshake).

### The sequence

One request, from the chain to the CPU:

1. **Request.** The chain pulls `INT_N` low. The layer does not pass this on:
   there is no address yet, and this port wants one in every cycle the request
   is up.
2. **Take the data bus.** In QNICE-FPGA the granted device drives its service
   routine's address onto the shared read-data bus, and `vhdl/mmio_mux.vhd`
   gates every other slave's enable with `IGRANT_N` high (`no_igrant_active`),
   RAM and ROM included. Upstream's CPU grants only while it is not using that
   bus. This CPU keeps executing while the layer grants, so the layer has to
   keep the data Wishbone off the bus itself: stall new requests, and wait for
   the outstanding ones to be acknowledged, before it grants.
3. **Grant.** Pull `IGRANT_N` low. The chain passes the grant through to the
   requesting device, which drives its address combinationally while its grant
   is low.
4. **Capture.** When the device releases `INT_N` — `daisy_chain.vhd` does so
   the cycle after its grant arrives — its address is valid: capture it from the
   data bus into a register.
5. **Release.** Pull `IGRANT_N` high. The device stops driving the bus
   combinationally, which `doc/int-device.md` requires, and the layer releases
   the Wishbone stall.
6. **Present.** Assert `irq_valid_i` with the captured address on `irq_addr_i`
   until `irq_ready_o`, then drop `irq_valid_i`. Do not grant again until the
   captured request has been accepted: the layer holds one request at a time,
   and the chain queues the rest.

### What follows from it

* **The device is acknowledged before the CPU commits.** From the device's side
  the interrupt was serviced at step 5, possibly long before a service routine
  runs, since this CPU still waits for an instruction boundary and for any
  running service routine to return. A device that treats the grant as "being
  serviced now" sees that latency.
* **A captured request must not be lost.** The chain has no way to abort a
  granted request (`doc/int-device.md`, "Aborting an on-going interrupt
  request"), so the layer owes the CPU that request. It may *withdraw*
  `irq_valid_i` — that is what this port allows — but it must present the same
  request again later, not discard it.
* **Masking belongs after the capture.** If `interrupt_controller.vhd` gates only
  the chain's `INT_N`, a request captured just before software masked
  interrupts still reaches the CPU after the mask. Gating `irq_valid_i` with the
  mask as well turns that into a withdrawal, and the captured request waits for
  the mask to clear. Even then masking lands later than on upstream's CPU; see
  [doc/interrupts.md](../../doc/interrupts.md#masking-and-why-it-lands-later-than-upstream).
* **Latency moves into the layer.** Steps 2 to 5 take cycles upstream's CPU
  spends in its own states `cs_int_wait_isr` and `cs_int_jmp_isr`. They are
  paid before the request reaches this CPU, and the stall in step 2 also
  delays whatever the program is doing on the data bus.
* **Arbitration** is the chain's business if the system is a chain. A system of
  independent devices needs an arbiter in the layer instead.

None of this has been built or simulated; it is derived from `doc/int-device.md`,
`daisy_chain.vhd`, and `mmio_mux.vhd` on upstream's `develop`.

### The same translation, the other way round, in `test/tb_upstream.vhd`

`test/tb_upstream.vhd` contains an adapter that does this translation in the
opposite direction, and it is the closest thing in this repository to the layer
above. It is not that layer: there the **device** speaks this port — it is
`test/interrupt.vhd` — and the **CPU** speaks the chain, since it is upstream's
own. The layer a QNICE-FPGA system needs has the chain on its device side and
this port on its CPU side.

It is worth reading all the same, because the two share their hard parts. The
adapter is the process `p_isr` and three assignments around it, under the
comment "Adapter: the three-signal request port onto INT_N/IGRANT_N":

* `cpu_int_n <= not irq_valid` — a request on the port is `INT_N`.
* `irq_ready` is high in the first cycle of the grant only (`isr_held`) — the
  grant is the one-cycle accept, the mapping step 6 above inverts.
* `isr_addr` captures `irq_addr` at that accept and is driven onto the data bus
  while the grant is low, released combinationally when it rises. This is the
  capture of step 4, needed for the same reason: the two protocols want the
  address at different moments, and `test/interrupt.vhd` scrambles its address
  the cycle after an accept precisely so that a missing capture fails.
* Every other slave's enable is gated with `IGRANT_N` high, as step 2 requires.

What it does not show is step 2's hard half. Upstream's CPU decides when to
grant and is off the bus while it does, so `tb_upstream.vhd` never has to stall a
bus master that keeps running. The layer in front of this CPU does.

## Tested against upstream's CPU, and why not against the emulator

**Every hardware interrupt program in this repository has also run on upstream's
own CPU, with the same Interrupt Generator, and the only two that differ do so
for one deliberate reason.**
`make crosscheck_rtl` runs each program in `TESTS` on upstream's
`vhdl/qnice_cpu.vhd` through `test/tb_upstream.vhd`, which instantiates
`test/interrupt.vhd` — the same file `test/system.vhd` uses, not a second model
of it — behind the adapter above. It compares the final memory and registers
with this CPU's, word for word.

| Program | Against upstream's CPU |
|---|---|
| `prog_int_hw.asm` | identical |
| `prog_int_waveform.asm` | identical |
| `prog_int_progress.asm` | **differs**: upstream takes a request pending at an `RTI` before any instruction at the return address runs, this CPU runs one first; see [Where this diverges from upstream](#where-this-diverges-from-upstream) |
| `prog_int_halt.asm` | **differs**, the special case of the above: upstream takes a request pending at a `HALT`, this CPU halts |
| `prog_int_sw.asm`, `prog_int_rogue_rti.asm`, `prog_int_rogue_int.asm` | identical |

Two details keep that honest. The programs check themselves, so "identical"
means both CPUs passed every check, not only that they ended in the same state.
And `prog_int_hw.asm` erases two results before it passes, in its `CLEANUP`
block: what an ISR last logged, and the register `R7` that its ISRs write in
whichever bank was current. Both record *where* an interrupt landed. Upstream's
CPU is a multi-cycle FSM and this one a pipeline, so the same countdown of
clock cycles lands on different instructions, and that is not an error. The
generator's own assertions — accept for exactly one cycle, and only while
requested — watch upstream's CPU through the adapter on every program, too.

**The same test cannot be run against upstream's C emulator**, which `make
crosscheck` otherwise compares every program against. The emulator has no device
at `0xBF00`, where that address is plain RAM, so the countdown never fires and all
four Interrupt Generator programs are `KNOWN_DIVERGENCE`s in
`test/crosscheck.py`. Adding one would not give the same test:

* **There is no file to share.** The value of the RTL comparison is that the
  device is literally the same VHDL. A device in the emulator would be a second
  implementation in C, and a difference could then be a difference between two
  interrupt generators.
* **There is no clock.** The emulator executes whole instructions, and
  `test/interrupt.vhd` counts idle clock cycles, which it has no equivalent of.
* **Its own interrupt sources are not reproducible.** The emulator's timers,
  `emulator/timer.c`, run on host threads with wall-clock intervals, so the
  instruction an interrupt lands on changes from run to run.

The emulator does check the parts that need no device: `INT`, `RTI`, and the
rogue halts all compare against it.

<a id="open-for-t2"></a>
## What became of the planned module

Task T2 of doc/interrupts.md planned `src/interrupt/interrupt.vhd`: a registered
leaf module between the pins and WRITE, with two states (`IDLE` and `ACCEPTED`),
a registered `pending_o` and `addr_o` for WRITE, a `start_i` commit pulse back
from it, and a registered `irq_ready_o` one cycle after the commit. Its purpose
was to keep the two external pins out of CPU_MAIN's combinational logic, and the
first version of this page was its specification, drawn before any VHDL existed.

It was never built. Hardware entry went straight into WRITE, reading the pins,
which is "Option A" of
[doc/interrupts.md](../../doc/interrupts.md#withdrawal-and-what-allowing-it-would-cost),
and the questions the specification left open were settled by that instead:

* **Withdrawal** is allowed, because nothing registers a request.
* **The accept** is combinational and in the commit cycle, not a registered cycle
  after it, so the CPU never pulses `irq_ready_o` into a device that has already
  let go.
* **Reset** holds `irq_ready_o` low. That was not so at first: the formal
  property `f_irq_ready_boundary` found a CPU in reset accepting a request.
* **Whether the entity was worth having**: no. It would have been two
  registers, and the price of leaving it out is the timing path above, which
  turned out not to be critical.

The specification as it stood is in the git history of this file.
