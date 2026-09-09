# MEMORY

Guidance for Claude Code when working in `src/memory/`. Claude Code loads this file on demand,
when it touches a file in this directory; the repository-wide rules stay in the top-level
[CLAUDE.md](../../CLAUDE.md). Full design writeup: [README.md](README.md).

## MEMORY module (`src/memory/memory.vhd`)

Multiplexes one request channel (from WRITE) and two read-response channels (SRC/DST, back to
PREPARE) onto a single Wishbone Master interface. Full design writeup, including the back-pressure
argument and the formal property list, is in [src/memory/README.md](README.md); the
key thing worth knowing up front:

**Wishbone ACKs carry no identifying information** — a bare pulse, not tagged with which request
or what type. This module recovers that itself via `i_two_stage_fifo_mem`, a depth-2 FIFO that
records each accepted-but-unacked request's op-type in issue order; each `wb_ack_i` is matched to
the *oldest* outstanding request (the FIFO's head) and that entry is popped to decide whether to
route `wb_data_i` to the SRC buffer, the DST buffer, or nowhere (a WRITE ack). This is correct, but
depends entirely on the Wishbone slave acking in issue order (stated in the module's header), and
would silently misattribute data against one that completed requests out of order. In a bitstream
`wbd_*` still reaches a single memory, so that holds trivially; in simulation it does not, because
`test/system.vhd` splits the bus at `0x8000`, RAM below and the simulation-only EAE above. There the
requirement is met **structurally**, by `test/wb_mux.vhd`, which releases responses in issue order
whatever the slaves' latencies are. See
[The data bus multiplexer](../../test/CLAUDE.md#the-data-bus-multiplexer). It also requires
at least one cycle of ACK latency: a slave that acks in the cycle it accepts the request leaves the
FIFO's registered output with nothing to route by.

**`mreq_accept` reads registered state only** — the response buffers' `tsb_*_fill`, never
`msrc_valid_o`/`mdst_valid_o` (which cut through combinationally from `wb_ack_i`) and never
`msrc_ready_i`/`mdst_ready_i` (which reach back to `wb_ack_i` through PREPARE's `wait_for_mem_dst`,
i.e. outside this file, which is why reading `memory.vhd` alone cannot tell you). Both of the more
precise forms put the response path in front of the request path — `mreq_accept` feeds `wb_stb_o` —
and both are free to drop: every test program's cycle count is bit-identical without them, and the
CPU is smaller and 0.18 ns faster. This came out of the zero-latency-slave experiment, where they
are outright combinational loops; see doc/README.md's Optimizations section for why that experiment
was rejected.

Formal status (`formal/memory.psl`): `bmc`/`cover` (depth 10) pass. K-induction (`prove`, not
currently in `formal/memory.sby`'s task list) is **partially closed**: the three buffer/FIFO
overflow-safety properties that blocked the original attempt now prove inductively, via a
self-correcting shadow register that mirrors the type-tracking FIFO's internal transition rules
(needed because GHDL's synth-for-formal flow can't read a sub-instance's internal registers
directly — confirmed by testing external names). One property, `f_wb_master_request` (≤2
outstanding Wishbone requests), remains open under induction — true up to the checked BMC depth,
with the specific remaining obstacle documented in a comment right above it in `memory.psl`.
