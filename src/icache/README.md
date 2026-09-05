# ICACHE

A two-word instruction buffer that presents DECODE with an instruction and its
possible immediate operand in the same cycle. It sits between FETCH and DECODE,
and `icache.vhd` is instantiated directly in [src/cpu.vhd](../cpu.vhd):

```
              wbi_*            fetch2icache_*         icache2decode_*
   WISHBONE <------->  FETCH  ---------------->  ICACHE  ------------> DECODE
   (instr)                ^   valid/ready/          ^ ^   valid/ready/
                          |   addr/data             | |   addr/data(32)/
                          |                         | |   double_o/double_i
                          +---- wr2fetch_valid -----+ |
                          |     wr2fetch_addr         |   (new PC, hard flush)
                          +---- dc2fetch_valid -------+
                                dc2fetch_addr             (early redirect,
                                                           soft flush)
```

The two entities used to be wrapped in a `fetch_cache.vhd`. That wrapper is
gone; `cpu.vhd` wires them together itself, which is why both flush signals are
visible at the top level (see [Flush](#flush) below). The FETCH half is
documented in [fetch/README.md](../fetch/README.md).

## icache.vhd

```
generic (G_ADDR_SIZE, G_DATA_SIZE : integer);   -- both 16 in cpu.vhd

clk_i      : in  std_logic;
rst_i      : in  std_logic;   -- reset AND pipeline flush (hard)
flush_i    : in  std_logic;   -- DECODE's early redirect (soft)

-- From FETCH
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
increasing stream. FETCH guarantees this between redirects.

## Flush

There are two of them, and the difference between them is the whole content of
this section.

`rst_i` is not merely a startup reset; it is also the pipeline flush, and
`cpu.vhd` drives it as

```vhdl
icache_rst <= rst_i or wr2fetch_valid;
```

with `wr2fetch_valid` being the same redirect that reaches `fetch.dc_valid_i`
and that resets FETCH's own internal FIFOs. This is mandatory, not a
convenience: when FETCH is redirected it discards its buffers, so any words
still held here belong to the abandoned instruction stream and must be discarded
in the **same** clock cycle. Omitting it delivers one or two stale instructions
to DECODE after every taken branch.

Consequently this module is written for an `rst_i` that pulses during normal
operation:

* `m_valid_o` is gated combinatorially by `rst_i`, so the flush takes effect in
  the same cycle and DECODE never observes a stale word.
* `s_ready_o` is likewise gated, so no input handshake completes during a flush
  cycle — otherwise the module would signal acceptance of a word it is about to
  discard. That is safe with respect to FETCH, which is discarding it too.
* `m_double` is cleared alongside `m_valid`, so `m_double_o` can never be left
  asserted while `m_valid_o` is low.

### The soft flush

`flush_i` is the second one, and it is the counterpart of `rst_i` for a redirect
that DECODE originates itself rather than receives — an unconditional branch to
an immediate target, see
[Early redirect](../cpu_main/README.md#early-redirect). `cpu.vhd` drives the two
separately:

```vhdl
icache_rst   <= rst_i or wr2fetch_valid;   -- hard
icache_flush <= dc2fetch_valid;            -- soft
```

It discards the buffered words at the end of the cycle in which it is asserted,
and it gates `s_ready_o` exactly as `rst_i` does, because an input word arriving
in a flush cycle belongs to the abandoned stream and FETCH — redirected by the
same signal — is discarding it too.

**What it must not do is gate `m_valid_o`.** DECODE raises the flush *because*
it is accepting the branch this cycle; withdrawing that offer would withdraw the
very handshake the flush is derived from, and the combinational loop settles on
"no branch accepted, no flush", leaving the optimisation silently inert. This is
the same asymmetry `two_stage_fifo` documents in its own contract (b), and for
the same reason: the consumer shares the flush, so it discards what it must.

`f_flush_comb`, `f_flush_offers` and `f_cover_flush_handshake` in
[icache.psl](../../formal/icache.psl) state both halves and make the mistake
visible. Note also the `flush_i = '0'` term in the trigger of `f_stable_double`
and `f_stable_single` there, where `rst_i` needs none: `rst_i` gates `m_valid_o`
so those triggers cannot fire in a hard-reset cycle at all, whereas a soft flush
leaves the output asserted and they fire normally. `abort` does not cover the
trigger cycle in GHDL, so the qualifier has to be in the trigger.

## Formal verification

`icache.sby` is in `DUTS` in [formal/Makefile](../../formal/Makefile), as is
FETCH's own job; see
[fetch/README.md](../fetch/README.md#formal-verification) for what the two
together do *not* prove.

`bmc`, `cover` and `prove` (k-induction), depth 10, elaborated with the small
generics `G_ADDR_SIZE=4`, `G_DATA_SIZE=8`. Self-contained — `icache.vhd` has no
sub-instances. [formal/icache.psl](../../formal/icache.psl) pins down the
combinational `count`, that buffered addresses are consecutive, output stability
under back-pressure for both the single- and double-word cases, the
same-cycle/next-cycle reset behaviour, and a full transition table of the
occupancy for every (`s_valid_i`, `m_ready_i`, `m_double_i`) combination. The
environment assumptions are the interface contracts above: input stability,
consecutive input addresses, and `m_double_i` only when two words are offered.

`flush_i` runs through all of it as a second emptying condition alongside
`rst_i`, and three properties are specifically about the difference between the
two: `f_flush_comb` (it gates `s_ready_o`), `f_flush_offers` (it does *not*
withdraw `m_valid_o`) and `f_cover_flush_handshake` / `f_cover_flush_double`
(an output handshake really does complete in a flush cycle, including the
two-word case DECODE actually uses). The covers are the important ones: make
`flush_i` behave like `rst_i` and every assertion still passes while those two
become unreachable.

The stability properties in `icache.psl` carry an `rst_i = '0'` term for the
same reason FETCH's carry `abort rst_i`: here too `rst_i` is the flush, and a
valid or ready signal can legitimately drop *within* the cycle it is asserted.
See [Reset and flush escapes](../fetch/README.md#reset-and-flush-escapes).
