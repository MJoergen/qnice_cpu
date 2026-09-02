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
  the module which response buffer (if any) the next ack should be routed to.
* **`i_one_stage_buffer_wb`** stages the actual Wishbone request — `we`, `dat`, and `addr` packed
  into a single 33-bit word — until the slave accepts it (`wb_stall_i='0'`).
* **`i_two_stage_buffer_src`** / **`i_two_stage_buffer_dst`** (depth 2 each) buffer SRC/DST read
  responses back to PREPARE, fed by `wb_data_i` whenever `wb_ack_i` arrives and the FIFO head
  identifies the completed request as a SRC/DST read respectively.

Since the depth-2 FIFO is the only thing gating new request acceptance for outstanding-request
counting, and the module additionally never accepts a *new* request while a SRC/DST response is
sitting unconsumed (`mreq_accept`, below), at most two requests — and hence at most two SRC/DST
responses — are ever outstanding at once. This is what keeps the depth-2 response buffers from
overflowing; see `f_tsb_src_in_overflow` / `f_tsb_dst_in_overflow` / `f_tsf_req_in_overflow` in
`formal/memory.psl`.

**Back-pressure (`mreq_accept`)**: a new request is accepted except when a previously-completed
SRC or DST response is already stored in the corresponding response buffer (`tsb_*_fill /= 0`) —
this is what bounds outstanding responses to what the depth-2 buffers can hold. Note the condition
is deliberately written against that **registered** occupancy and nothing else. The more precise
forms — `m*_valid_o` (which cuts through combinationally from `wb_ack_i`) and a
`m*_ready_i='0'` "…and not being consumed this cycle" refinement (which reaches back to `wb_ack_i`
through PREPARE's `wait_for_mem_dst`) — both put the response path in front of the request path,
and both are combinational *loops* against a slave that acks in the cycle it accepts. Neither buys
anything: removing them left every test program's cycle count bit-identical and made the CPU
smaller. See the comment at `mreq_accept` in `memory.vhd`, and doc/README.md's Optimizations
section for the zero-latency experiment that found this.
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

## Formal verification

`formal/memory.psl` checks, against the module standalone (built up from the real `src/sub/`
components, not stubs):

* **Internal safety**: the three buffers above are never pushed while full (`f_tsb_src_in_overflow`,
  `f_tsb_dst_in_overflow`, `f_tsf_req_in_overflow`).
* **Wishbone master protocol**: `wb_cyc_o`/`wb_stb_o` are cleared under reset
  (`f_wb_master_reset`), `wb_stb_o` never asserts while `wb_cyc_o` is low (`f_wb_master_stb_low`), a
  stalled request's `stb`/`addr`/`we`/`dat` stay stable until accepted or reset
  (`f_wb_master_stable`), and at most two Wishbone requests are ever outstanding at once
  (`f_wb_master_request`).
* **Assumptions about the environment** (the proof is only as strong as these): the Wishbone slave
  acks in issue order with at least one cycle of latency and never acks with nothing outstanding
  (`f_wb_slave_ack_idle`), and stalls/response delays are bounded to 3 cycles as an artificial but
  reasonable modeling limit (`f_wb_slave_stall_delay_max`, `f_wb_slave_ack_delay_max`); WRITE only
  ever presents a one-hot `mreq_op_i` (`f_mreq_op`) and holds a pending request's valid/op/addr/data
  stable until accepted (`f_mreq_stable`) — this last one is also documented directly in
  `memory.vhd`'s header, since it's a real contract the RTL leans on.
* **Cover statements** demonstrate reachability of interleaved SRC/DST bursts
  (`f_cover_burst2`) and of all three request types issuing back-to-back (`f_cover_burst`).

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

