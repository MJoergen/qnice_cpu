# FETCH stage

The FETCH stage is built from two entities, both instantiated directly in
[src/cpu.vhd](../cpu.vhd):

* `fetch.vhd` — a one-word-at-a-time WISHBONE instruction fetcher.
* `icache.vhd` — a two-word instruction buffer that presents DECODE with an
  instruction and its possible immediate operand in the same cycle.

They used to be wrapped in a `fetch_cache.vhd`. That wrapper is gone; `cpu.vhd`
now wires the two together itself, which is why the redirect/flush signal is
visible at the top level (see [Flush](#flush) below).

```
              wbi_*            fetch2icache_*         icache2decode_*
   WISHBONE <------->  fetch  ---------------->  icache  ------------> DECODE
   (instr)                ^   valid/ready/       ^   valid/ready/
                          |   addr/data          |   addr/data(32)/
                          |                      |   double_o/double_i
                          |                      |
                          +---- wr2fetch_valid --+   (new PC / flush)
                                wr2fetch_addr
```

## fetch.vhd

```
clk_i      : in  std_logic;
rst_i      : in  std_logic;

-- Send read request to WISHBONE
wb_cyc_o   : out std_logic;
wb_stb_o   : out std_logic;
wb_stall_i : in  std_logic;
wb_addr_o  : out std_logic_vector(15 downto 0);

-- Receive read response from WISHBONE
wb_ack_i   : in  std_logic;
wb_data_i  : in  std_logic_vector(15 downto 0);

-- Send instruction to DECODE (i.e. to icache)
dc_valid_o : out std_logic;
dc_ready_i : in  std_logic;
dc_addr_o  : out std_logic_vector(15 downto 0);
dc_data_o  : out std_logic_vector(15 downto 0);

-- Receive a new PC from WRITE (the dc_ prefix here is historical)
dc_valid_i : in  std_logic;
dc_addr_i  : in  std_logic_vector(15 downto 0)
```

It speculatively fetches a linear sequence of instruction words starting at the
address most recently supplied on `dc_valid_i`/`dc_addr_i`. Each WISHBONE read
request reserves one *slot*: allocated when the request is issued (`STB`
asserted), released when the corresponding word is handed to `icache`. At most
`C_MAX_PENDING = 2` slots may be in use, which bounds the occupancy of both
internal FIFOs and is what guarantees neither can overflow. The bus runs in
pipelined mode — `STB` is one cycle per request (held while `STALL`), `CYC` is
held until every accepted request is acknowledged.

Internally it is three of the [elastic-pipeline primitives](../sub):
`two_stage_fifo` holds the issued addresses, `two_stage_buffer` catches the
returning data, and `pipe_concat` joins the two streams into
`dc_addr_o`/`dc_data_o`. All three are reset with `rst_i or dc_valid_i`.

### Redirect

A redirect (`dc_valid_i`) does **not** normally terminate the bus cycle. `CYC`
stays asserted and the first request of the new instruction stream goes out on
the very next clock cycle. Tearing the bus cycle down instead — which is what
this module used to do — costs an extra cycle before `STB` can be reasserted,
and that cycle lands on the critical path of every taken branch, because the
pipeline behind it is empty and waiting.

The price is that requests the slave has already accepted still owe an
acknowledgement, and those acknowledgements must not be paired with an address
from the new stream. `wb_stale` counts them, and `wb_rsp_accept` — the signal
that pushes into the data buffer — is gated so they are discarded on arrival.
That is what turns contract (c) below into contract (d): cancellation by
dropping `CYC` is replaced by discarding a known number of responses, which
works only against a slave that acknowledges **in order**.

Two details are load-bearing:

* The redirect is applied **before** the issue step in `p_wishbone`, not after.
  That ordering is the entire optimisation; it used to be the other way round,
  with the redirect explicitly overriding the issue.
* The issue budget counts `wb_stale` alongside the allocated slots. A stale
  request still occupies a slot on the *bus* even though it no longer occupies
  one here, and without that term a redirect could push the number of
  unacknowledged requests past `C_MAX_PENDING` — which is both an assertion
  (`f_wb_master_req_count_max`) and a constraint on how much any slave has to
  be able to queue.

The bus cycle is still torn down in the one case where it cannot be redirected:
a request already asserted on `STB` that the slave has not yet accepted.
WISHBONE B4 lets the master neither withdraw `STB` nor alter the request while
`STALL` is asserted. A slave that never stalls — the dual-port RAM this CPU is
built around — never reaches that path.

Measured over the nine test programs, this removes one clock cycle from every
redirect: 741 cycles off `test/prog.asm` (−4.7%), and up to −9.1% on the
branch-dense ones. The per-program figures live in `test/*.stats.golden`; the
memory-request counts in those files are unchanged, i.e. the same bus traffic
happens one cycle earlier rather than more of it happening.

### Interface contracts

Also stated in the file header:

* `dc_valid_i` is an unconditional, single-cycle flush with no back-pressure:
  everything already fetched is abandoned, both internal FIFOs are cleared, and
  fetching restarts at `dc_addr_i`.
* WRITE **must** supply a PC before any fetched instruction is meaningful —
  `wb_addr_o` resets to zero, so without one the unit fetches from address 0.
* The WISHBONE slave **must not** assert `ACK` after `CYC` has been deasserted.
  Deasserting `CYC` cancels all outstanding requests; a slave that acked a
  cancelled request would pair stale data with the address of a new request,
  i.e. silent instruction corruption.
* The WISHBONE slave **must** acknowledge requests **in order**. Nothing on the
  bus says which request an `ACK` belongs to, so discarding what an abandoned
  request is owed means discarding the next `wb_stale` acknowledgements. The
  Memory module makes the same assumption for the same reason, see
  [memory/README.md](../memory/README.md).

## icache.vhd

```
generic (G_ADDR_SIZE, G_DATA_SIZE : integer);   -- both 16 in cpu.vhd

clk_i      : in  std_logic;
rst_i      : in  std_logic;   -- reset AND pipeline flush

-- From fetch
s_valid_i  : in  std_logic;
s_ready_o  : out std_logic;
s_addr_i   : in  std_logic_vector(G_ADDR_SIZE - 1 downto 0);
s_data_i   : in  std_logic_vector(G_DATA_SIZE - 1 downto 0);

-- To DECODE
m_valid_o  : out std_logic;
m_ready_i  : in  std_logic;
m_double_o : out std_logic;
m_addr_o   : out std_logic_vector(G_ADDR_SIZE - 1 downto 0);
m_data_o   : out std_logic_vector(2 * G_DATA_SIZE - 1 downto 0);
m_double_i : in  std_logic
```

`m_valid_o`/`m_ready_i` are the usual handshaking signals, `m_addr_o` is the
address of the current instruction, and `m_data_o` contains one or two words, as
indicated by `m_double_o`. In either case `data(15 downto 0)` is the
instruction and `data(31 downto 16)` is the immediate operand if present.

DECODE cannot know whether the second word is an operand until it has decoded
the first, so it reports back — combinatorially, in the same cycle as the
handshake — how many words it consumed: `m_double_i = '0'` for one word,
`'1'` for two. Therefore `m_double_i` must depend combinatorially on the output
signals. `m_double_i = '1'` is only legal when `m_valid_o = '1'` and
`m_double_o = '1'`; consuming two words when only one is offered is a protocol
violation.

Buffer occupancy (`count`) is derived combinatorially from `m_valid_o`/
`m_double_o` rather than kept in a separate register, so it cannot disagree with
what is being offered. Internally, slot 0 is the low half of each vector (older
word) and slot 1 the high half (newer word); the upper half of `m_addr` is never
driven off-chip, but is retained so the slot-1-to-slot-0 shift is a uniform
vector operation and so the formal properties can check the two buffered
addresses really are consecutive.

The words arriving on the input port must be **consecutive in address** — the
"second word is the immediate operand" reading is only meaningful for a gapless,
increasing stream. `fetch` guarantees this between redirects.

## Flush

`icache`'s `rst_i` is not merely a startup reset; it is also the pipeline flush,
and `cpu.vhd` drives it as

```vhdl
icache_rst <= rst_i or wr2fetch_valid;
```

with `wr2fetch_valid` being the same redirect that reaches `fetch.dc_valid_i`
and that resets `fetch`'s own internal FIFOs. This is mandatory, not a
convenience: when `fetch` is redirected it discards its buffers, so any words
still held in `icache` belong to the abandoned instruction stream and must be
discarded in the **same** clock cycle. Omitting it delivers one or two stale
instructions to DECODE after every taken branch.

Consequently `icache` is written for an `rst_i` that pulses during normal
operation:

* `m_valid_o` is gated combinatorially by `rst_i`, so the flush takes effect in
  the same cycle and DECODE never observes a stale word.
* `s_ready_o` is likewise gated, so no input handshake completes during a flush
  cycle — otherwise the module would signal acceptance of a word it is about to
  discard. That is safe with respect to `fetch`, which is discarding it too.
* `m_double` is cleared alongside `m_valid`, so `m_double_o` can never be left
  asserted while `m_valid_o` is low.

## Formal verification

Both entities have their own job, and both are in `DUTS` in
[formal/Makefile](../../formal/Makefile).

### icache.sby

`bmc`, `cover` and `prove` (k-induction), depth 10, elaborated with the small
generics `G_ADDR_SIZE=4`, `G_DATA_SIZE=8`. Self-contained — `icache.vhd` has no
sub-instances. [formal/icache.psl](../../formal/icache.psl) pins down the
combinational `count`, that buffered addresses are consecutive, output stability
under back-pressure for both the single- and double-word cases, the
same-cycle/next-cycle reset behaviour, and a full transition table of the
occupancy for every (`s_valid_i`, `m_ready_i`, `m_double_i`) combination. The
environment assumptions are the interface contracts above: input stability,
consecutive input addresses, and `m_double_i` only when two words are offered.

### fetch.sby

`bmc`, `cover` and `prove` all pass. Unlike `memory.sby`, this job also loads
the `.psl` of every sub-block it instantiates and then runs

```
chformal -assume2assert fetch/* %M
```

which converts each sub-block's *assumptions about its inputs* into *assertions
on `fetch`*. So the job proves not only that `fetch` behaves, but that it drives
`two_stage_fifo`, `two_stage_buffer` and `pipe_concat` legally. That is worth
keeping in mind when editing the sub-block `.psl` files: an assumption written
there becomes an obligation here.

One cover statement is explicitly removed for this job:

```
chformal -cover -remove c:*i_pipe_concat.f_s0_waits*
```

`pipe_concat`'s `f_s0_waits` covers "s0 arrives before s1". Inside `fetch`, `s1`
is the address FIFO (filled when a request is *issued*) and `s0` is the data
buffer (filled when the response *arrives*), so the address is always present
first and that ordering is unreachable by construction. It stays covered by
`pipe_concat.sby` standalone, where both orderings are reachable.

Note that the two jobs verify the two entities separately; nothing currently
proves the *composition* — in particular that `cpu.vhd` really does drive
`icache_rst` with the same redirect `fetch` sees. That wiring is the one thing
that used to be internal to `fetch_cache.vhd` and is now the top level's
responsibility.

#### The shadow model and the redirect fast path

`fetch.psl` maintains shadow state recomputed from the module's **ports only**,
then cross-checks it against the RTL (`f_outstanding_match`). That gives the
properties independence from the implementation and hands k-induction strong
invariants. The redirect fast path moved one line of it that is easy to get
wrong: `f_wb_outstanding` used to be cleared on `dc_valid_i`, because a redirect
always tore the bus cycle down. It no longer does, so the counter is now cleared
only when the design actually cancels — a request stuck in a stall.

The failure mode of getting this wrong is silent rather than loud. The
assumption `f_wb_slave_ack_idle` forbids an `ACK` when `f_wb_outstanding = 0`;
clear the counter on every redirect and the environment can never produce a
stale acknowledgement at all, so the discard logic goes completely unexercised
while every assertion in the file still passes. `f_cover_abort_redirect` and
`f_cover_stale_ack` exist to make that visible: they require a redirect that
leaves an acknowledgement owed, and that acknowledgement then arriving.

Clearing on `wb_cyc_o = '0'` instead looks equivalent and is not — the
registered `CYC` goes low one cycle after the decision, leaving a window where
the counter is non-zero while `CYC` is already low, which
`f_inv_cyc_outstanding` catches. The shadow therefore mirrors the design's own
cancel condition, from ports.

Two invariants carry the induction proof across the change:

* `f_inv_fill` gains a `wb_stale` term. It relates the address FIFO to the data
  buffer plus what is outstanding on the bus, and a stale request is precisely
  one whose address is no longer in the FIFO.
* `f_inv_stale_data_empty` is new: while an acknowledgement is owed to an
  abandoned request, the data buffer must be empty. This is true because the
  slave acknowledges in order and the redirect flushed the buffer — but
  induction begins from an arbitrary state where a stale count and a non-empty
  buffer can coexist, and from there a discarded response lets a buffered one be
  paired with an address from the new stream. That is exactly what
  `f_dc_data_integrity` forbids, and without this invariant it is true but not
  inductive.

### Reset and flush escapes

`fetch` resets its address FIFO, data buffer and `pipe_concat` with
`rst_i or dc_valid_i`, so a PC redirect from WRITE flushes them mid-stream.
Combined with the fact that `one_stage_buffer`/`two_stage_buffer` gate
`m_valid_o` and `s_ready_o` combinationally with `and not rst_i`, this means a
valid or ready signal can legitimately drop *within the cycle* the flush is
asserted. Every "stable until accepted" property along this path therefore needs
an escape on the **consequent** side, not just the trigger side — `abort rst_i`,
or an explicit `dc_valid_i` term:

* `f_data_ready` (fetch.psl) — mirrors the escape `f_addr_ready` already had.
* `f_dc_assert_stable` (fetch.psl) — `abort (rst_i or dc_valid_i)`.
* `f_output_stable`, `f_input0_stable`, `f_input1_stable` (pipe_concat.psl).
* `f_input_stable` (two_stage_buffer.psl) — this one matters most: under
  `assume2assert` it demands that `wb_cyc_o and wb_ack_i` obey the valid/ready
  hold contract, and a WISHBONE ack is a *pulse* that is never re-driven. The
  design copes by guaranteeing the buffer is always ready (`f_data_ready`), so
  the trigger can only fire while reset or a flush holds `s_ready_o` low.

The same reasoning is why `icache.psl`'s stability properties carry an
`rst_i = '0'` term: its `rst_i` is the flush.

Omitting one of these is the trap described in the top-level `CLAUDE.md`, and
BMC finds it immediately.

### A note on stale properties

`fetch.sby` did not elaborate at all for a while: `s_fill_o` on
`two_stage_fifo`/`two_stage_buffer` changed from `std_logic_vector(1 downto 0)`
to `natural range 0 to 2`, and `fetch.psl` kept calling `to_integer()` on it and
comparing it against `"10"`/`"00"`. Because a job that fails to elaborate looks
much like any other red result, the four property bugs above sat behind it
undetected. Worth re-running `make formal` after changing any port type shared
across modules.
