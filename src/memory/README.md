# MEMORY module

## Interfaces
The top-level interface of the MEMORY module is as follows:
```
-- From WRITE
mreq_valid_i : in  std_logic;
mreq_ready_o : out std_logic;
mreq_op_i    : in  std_logic_vector(2 downto 0);
mreq_addr_i  : in  std_logic_vector(15 downto 0);
mreq_data_i  : in  std_logic_vector(15 downto 0);

-- To PREPARE
msrc_valid_o : out std_logic;
msrc_ready_i : in  std_logic;
msrc_data_o  : out std_logic_vector(15 downto 0);

mdst_valid_o : out std_logic;
mdst_ready_i : in  std_logic;
mdst_data_o  : out std_logic_vector(15 downto 0);

-- Memory
wb_cyc_o     : out std_logic;
wb_stb_o     : out std_logic;
wb_stall_i   : in  std_logic;
wb_addr_o    : out std_logic_vector(15 downto 0);
wb_we_o      : out std_logic;
wb_dat_o     : out std_logic_vector(15 downto 0);
wb_ack_i     : in  std_logic;
wb_data_i    : in  std_logic_vector(15 downto 0)
```


## Implementation

This module multiplexes one request channel (from the WRITE stage) and two readback channels
(SRC/DST, back to the PREPARE stage) onto a single Wishbone Master interface, using three
[`src/sub/`](../sub) elastic-pipeline primitives:

* **`i_two_stage_fifo_mem`** (depth 2) tracks the one-hot op-type (`mreq_op_i`: READ_SRC / READ_DST
  / WRITE) of each *outstanding* (issued-but-not-yet-acked) request, in issue order. It is pushed
  whenever a request is accepted and popped whenever `wb_ack_i` arrives, so its head always tells
  the module which response buffer (if any) the next ack should be routed to. Its output is
  *registered*, which is why an ack arriving in the same cycle as the request needs a path around
  it — see [Zero-latency ACKs](#Zero-latency-ACKs) below.
* **`i_one_stage_buffer_wb`** stages the actual Wishbone request — `we`, `dat`, and `addr` packed
  into a single 33-bit word — until the slave accepts it (`wb_stall_i='0'`).
* **`i_two_stage_buffer_src`** / **`i_two_stage_buffer_dst`** (depth 2 each) buffer SRC/DST read
  responses back to PREPARE, fed by `wb_data_i` whenever `wb_ack_i` arrives and the recovered
  op-type (`wb_ack_op` — the FIFO head, or `mreq_op_i` on a zero-latency ack) identifies the
  completed request as a SRC/DST read respectively.

Since the depth-2 FIFO is the only thing gating new request acceptance for outstanding-request
counting, and the module additionally never accepts a *new* request while a SRC/DST response is
sitting stored and unconsumed (`mreq_accept`, below), at most two requests — and hence at most two SRC/DST
responses — are ever outstanding at once. This is what keeps the depth-2 response buffers from
overflowing; see `f_tsb_src_in_overflow` / `f_tsb_dst_in_overflow` / `f_tsf_req_in_overflow` in
`formal/memory.psl`.

Stated per channel, the quantity that actually has to stay bounded is *total outstanding SRC (resp.
DST) work*: entries still unacked in the FIFO, plus responses already delivered but not yet consumed
by PREPARE. That total never exceeds 2 (`f_src_total_max` / `f_dst_total_max`). Each accept adds
one, each ack moves one from the first term to the second, and each consume removes one — and an
accept is only allowed either when the buffer is empty (so the total is just the FIFO count, capped
at 2 by its depth) or when a word is being consumed on the same edge (which leaves the total
unchanged). It is this argument, not the instantaneous `m*_valid_o`, that `mreq_accept` has to
preserve.

**Back-pressure (`mreq_accept`)**: a new request is accepted except when a previously-completed
SRC or DST response is already *stored* in its buffer and not being consumed by PREPARE this cycle
(`tsb_*_fill /= 0` and `m*_ready_i='0'`) — this is what bounds outstanding responses to what the
depth-2 buffers can hold. Note it reads the buffers' registered occupancy rather than
`msrc_valid_o`/`mdst_valid_o`: those cut through combinationally from `wb_ack_i`, and `mreq_accept`
feeds `wb_stb_o`, so against a slave whose ack is a combinational function of STB the obvious
version is a combinational loop. The registered form is very slightly more permissive — in the one
cycle a response cuts through unconsumed, `fill` is still 0 and a further request is accepted — and
that is safe, because the invariant it has to preserve is the per-channel total below, not the
buffer's instantaneous occupancy.
`mreq_ready_o` is the AND of this accept condition and the WB-request buffer's own readiness
(`mreq_ready`); `mreq_valid` (fed into `i_one_stage_buffer_wb`) is gated by the same accept
condition. A consequence worth knowing before touching this logic: `mreq_valid` can legitimately
drop for a cycle even while WRITE holds `mreq_valid_i` asserted throughout (see the long comment
at `mreq_valid <= mreq_valid_i and mreq_accept;` in `memory.vhd`) — formally confirmed reachable,
but proven harmless, because `mreq_ready_o` never lies to WRITE and the buffer's `s_data_i` is
wired directly to the (separately-guaranteed-stable) `mreq_op_i`/`mreq_addr_i`/`mreq_data_i`.

**`wb_cyc_o`** stays asserted as long as either the request buffer holds an unconsumed request
(`wb_stb_o='1'`) or the FIFO reports an outstanding (unacked) request (`tsf_req_out_valid='1'`), so
it correctly spans a whole pipelined multi-request transaction, not just a single request/ack pair.

### Zero-latency ACKs

The slave may answer a request in the very cycle it accepts it. Nothing in this repo does — the
testbench slave `test/wb_dp_mem.vhd` registers its ack, and it has to, being backed by `dp_ram`
whose read port is registered — but a combinational peripheral on `wbd_*` would, and the module
supports it.

The problem it creates is that `i_two_stage_fifo_mem`'s output is registered: the entry pushed for
that request is not visible on `tsf_req_out_data` until the *next* cycle, so at the moment of the
ack the module has no type to route the response by. Left unhandled it fails twice over — the
response is dropped (PREPARE then waits forever on `msrc_valid_o`), and the un-popped entry shifts
every later ack one request out of step, silently misrouting SRC data to DST and back.

`wb_ack_zero_lat` is the path around it. An **empty FIFO at the moment of an ack is the signature of
the case**: with nothing outstanding, an ack can only belong to a request being issued right now.
Two things follow, and both are asserted rather than assumed:

* That request is cutting straight through `i_one_stage_buffer_wb`, so its op-type is simply
  `mreq_op_i`. It cannot instead be a request staged in an earlier cycle, because the request buffer
  and the FIFO are pushed by the identical condition (`mreq_ready_o`) and a FIFO entry is popped only
  by its own ack — so a staged request always still has a FIFO entry. `wb_req_afull` exists purely to
  expose that cross-signal invariant to formal (`f_wb_req_buf_empty`, `f_zero_lat_ack_is_pushed`).
* The push is *suppressed* in that cycle rather than pushed and immediately popped, since a
  registered-output FIFO cannot do the latter.

**`wb_ack_zero_lat` deliberately does not test `wb_stb_o and not wb_stall_i`**, even though that
reads as the more obviously correct condition. It is redundant — `f_zero_lat_ack_is_issue` states
exactly that it is implied — and it is expensive. `wb_stb_o` traces back through `mreq_valid_i` to
the Sequencer and DECODE's registered microcodes, so including it splices the whole request-issue
path onto the front of `msrc_valid_o`/`mdst_valid_o`, which PREPARE consumes combinationally, and
the join carries on into `fetch_valid_o` and the Icache's reset pin. Measured on the shipping build:
**WNS +0.135 ns → −2.172 ns**, 11 logic levels, on a path this module is otherwise nowhere near.
As written, every operand of the bypass (`wb_ack_i`, `tsf_req_out_valid`, and `mreq_op_i`, which is
PREPARE's registered `wr_stage_o`) comes straight off a flip-flop.

## Formal verification

`formal/memory.psl` checks, against the module standalone (built up from the real `src/sub/`
components, not stubs):

* **Internal safety**: the three buffers above are never pushed while full (`f_tsb_src_in_overflow`,
  `f_tsb_dst_in_overflow`, `f_tsf_req_in_overflow`), and — the stronger form, needed now that a
  zero-latency ack deliberately accepts a request *without* pushing it — the FIFO is ready on every
  cycle a request is accepted at all, gate or no gate (`f_tsf_req_accept_ready`).
* **The zero-latency-ack bypass**: an empty FIFO implies an empty request buffer
  (`f_wb_req_buf_empty`), a zero-latency ack always coincides with the acceptance of the very
  request it answers (`f_zero_lat_ack_is_pushed`), and it always coincides with that request being
  handed to the slave (`f_zero_lat_ack_is_issue`) — the last of these is what lets `wb_ack_zero_lat`
  omit the `wb_stb_o` term that costs the design its timing margin.
* **Wishbone master protocol**: `wb_cyc_o`/`wb_stb_o` are cleared under reset
  (`f_wb_master_reset`), `wb_stb_o` never asserts while `wb_cyc_o` is low (`f_wb_master_stb_low`), a
  stalled request's `stb`/`addr`/`we`/`dat` stay stable until accepted or reset
  (`f_wb_master_stable`), and at most two Wishbone requests are ever outstanding at once
  (`f_wb_master_request`).
* **Assumptions about the environment** (the proof is only as strong as these): the Wishbone slave
  acks in issue order and never acks with nothing outstanding *and nothing being accepted this
  cycle* (`f_wb_slave_ack_idle` — that second clause is what admits a zero-latency ack; dropping it
  restores the old "at least one cycle of latency" contract and makes every zero-latency cover
  below unreachable, which is the quickest way to tell the two apart), and stalls/response delays
  are bounded to 3 cycles as an artificial but
  reasonable modeling limit (`f_wb_slave_stall_delay_max`, `f_wb_slave_ack_delay_max`); WRITE only
  ever presents a one-hot `mreq_op_i` (`f_mreq_op`) and holds a pending request's valid/op/addr/data
  stable until accepted (`f_mreq_stable`) — this last one is also documented directly in
  `memory.vhd`'s header, since it's a real contract the RTL leans on.
* **Cover statements** demonstrate reachability of interleaved SRC/DST bursts
  (`f_cover_burst2`) and of all three request types issuing back-to-back (`f_cover_burst`), plus
  the zero-latency path: a bypassed SRC and DST ack (`f_cover_zero_lat_src` /
  `f_cover_zero_lat_dst`), a bypassed response that has to be stored before PREPARE takes it
  (`f_cover_zero_lat_out`), and a bypassed ack followed later by an ordinary FIFO-matched one
  (`f_cover_zero_lat_mixed`).

**The covers, not the asserts, are what hold the bypass in place.** Verified by mutation: forcing
`wb_ack_zero_lat` to `'0'` — i.e. reverting to the pre-zero-latency behaviour — leaves `bmc`
**passing**, because silently dropping a read response violates no safety property here; only
`cover` goes red. This is the same trap as `f_cover_stale_ack` in
[fetch/README.md](../fetch/README.md#Redirect). Removing the push suppression instead
(`tsf_req_in_valid` ungated) *is* caught by `bmc`, on `f_src_total_max`.

One wrinkle worth knowing when reading a failing `cover` run: a cover statement that the mutation
makes *structurally* impossible can be optimised away before SymbiYosys sees it, and then appears
in neither the reached nor the unreached list rather than being reported as unreached. In the
mutation above only `f_cover_zero_lat_dst` and `f_cover_zero_lat_mixed` were listed; the other two
had vanished. The task still fails, so the net holds — but "the reached list names the cover I care
about" is the check to make, not "the run passed".

**Current status**: `bmc` (depth 10) and `cover` (depth 10) both pass — run with
`sby --yosys "yosys -m ghdl" -f memory.sby`. There is still **no `prove` (k-induction) task** in
`memory.sby`; it was removed in favor of `bmc` in commit `db1e2a8` ("BMC passes. PROVE does not.").

K-induction is now **partially closed**, though. The three buffer/FIFO overflow-safety properties
that blocked the original attempt (`f_tsb_src_in_overflow`, `f_tsb_dst_in_overflow`,
`f_tsf_req_in_overflow`) do prove inductively, using the `p_shadow_fifo_content` block under
"ADDITIONAL ASSERTS NEEDED FOR K-INDUCTION" in `formal/memory.psl`. That block mirrors
`i_two_stage_fifo_mem`'s own transition rules from this entity's ports, because GHDL's
synth-for-formal flow cannot read a sub-instance's internal registers directly (VHDL-2008 external
names are unsupported there — confirmed by testing). It is self-correcting rather than a
push/pop counter, which is why an adversarial induction seed cannot make it diverge forever.

**One property remains open under induction**: `f_wb_master_request` (at most two outstanding
Wishbone requests). The obstacle is documented in full in a comment directly above it in
`formal/memory.psl` — briefly, `i_one_stage_buffer_wb` (depth 1) can accept a new request in the
same cycle it hands an old one to the slave, so more than one FIFO push can be unreflected in the
count at once, and a single `wb_stb_o` bit cannot represent that. Closing it needs a per-item view
of that gap, plausibly reusing the same shadow technique. Until then that one property is verified
only to the bounded depth, not for all time.

