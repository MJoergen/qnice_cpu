# ICACHE

A two-word instruction buffer that presents DECODE with an instruction and its
possible immediate operand in the same cycle. It sits between FETCH and DECODE,
and `icache.vhd` is instantiated directly in [src/cpu.vhd](../cpu.vhd):

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
the first, so it reports back — combinationally, in the same cycle as the
handshake — how many words it consumed: `m_double_i = '0'` for one word,
`'1'` for two. Therefore `m_double_i` must depend combinationally on the output
signals. `m_double_i = '1'` is only legal when `m_valid_o = '1'` and
`m_double_o = '1'`; consuming two words when only one is offered is a protocol
violation.

Buffer occupancy (`count`) is derived combinationally from `m_valid_o`/
`m_double_o` rather than kept in a separate register, so it cannot disagree with
what is being offered. Internally, slot 0 is the low half of each vector (older
word) and slot 1 the high half (newer word); the upper half of `m_addr` is never
driven off-chip, but is retained so the slot-1-to-slot-0 shift is a uniform
vector operation and so the formal properties can check the two buffered
addresses really are consecutive.

The words arriving on the input port must be **consecutive in address** — the
"second word is the immediate operand" reading is only meaningful for a gapless,
increasing stream. FETCH guarantees this between redirects.

## What the two-word offer is worth

The module exists so that DECODE sees the instruction and its immediate operand
in the same beat, and a one-word instruction such as `MOVE @R15++, R0` therefore
retires without a bubble. That is the design intent; this section is the
measurement of it, made by disabling the two-word offer and re-running the whole
test suite.

**It is not an optimisation layered on a working design.** The obvious
experiment — tying `m_double_i` and `ic_double_i` to `'0'` in `cpu.vhd` — does
not run at all. DECODE holds `ic_ready_o` at `'0'` whenever `ic_double_o` is set
and `ic_double_i` is not (see the back-pressure block at the top of
[decode.vhd](../cpu_main/decode.vhd)), so the first instruction carrying an
immediate is never accepted and every program dies on `tb_cpu.vhd`'s watchdog.
DECODE has no state in which to hold half an instruction: it is combinational
over a single beat, and the two-word offer is what makes that possible. Anything
that removes it is a redesign of DECODE, not a wiring change.

So the alternative has to be modelled rather than unplugged. A DECODE fed one
word per beat would need a second handshake for the operand, i.e. one extra
cycle per immediate-bearing instruction at the head of the buffer. That was
inserted temporarily in `cpu.vhd`, by withholding the ICACHE-to-DECODE handshake
for one cycle the first time an instruction with an immediate reaches the head,
and releasing it the next. The model is architecturally transparent — every
`test/*.writes` log is byte-identical to its golden file, only the cycle counts
move — and it is deliberately *pessimistic*, because withholding the whole beat
also keeps word 0 in the buffer for that cycle, where a real one-word design
would have popped it and let FETCH refill a cycle earlier. The deltas below are
therefore an upper bound on what the two-word offer buys.

| Program | Cycles now | One word per beat | Delta | Buffer was ahead |
|---|---:|---:|---:|---:|
| `prog` | 15581 | 15602 | +21 (+0.13%) | 31 of 3991 |
| `prog_simple` | 84 | 84 | 0 | 2 of 13 |
| `prog_pipeline` | 28 | 28 | 0 | 0 of 7 |
| `prog_interleave` | 54 | 54 | 0 | 1 of 12 |
| `prog_flags` | 248 | 248 | 0 | 0 of 77 |
| `prog_r15` | 53 | 54 | +1 (+1.9%) | 1 of 12 |
| `prog_hazard` | 457 | 459 | +2 (+0.44%) | 3 of 131 |
| `prog_self_modifying` | 283 | 283 | 0 | 0 of 78 |
| `prog_subroutine` | 580 | 580 | 0 | 0 of 103 |
| `prog_waveform` | 39 | 39 | 0 | 0 of 8 |
| `prog_eae` | 1873 | 1873 | 0 | 43 of 394 |
| `prog_eae_stall` | 111 | 111 | 0 | 2 of 39 |
| `prog_wb_mux` | 80 | 80 | 0 | 3 of 18 |
| `prog_mandel_perf` | 170041 | 171817 | +1776 (+1.04%) | 4440 of 37947 |

**Between 0 and 1.0% of the cycle count, and on the one real program in the
suite 1.04%.** Eight of the fourteen programs do not move at all, including
`prog_subroutine`, which is the branch-dense benchmark, and `prog_eae`, which is
the one that stalls hardest on a device.

The last column is why, and it is the number worth remembering. It counts the
occasions on which ICACHE was already holding **both** words at the moment the
instruction reached the head of the buffer — the only case in which offering
them together can save anything. On `prog` that is 31 of 3991 immediate-bearing
instructions, 0.8%; even on `prog_mandel_perf`, where the EAE and the data bus
stall DECODE often enough for the buffer to fill, it is 11.7%.

The cause is bandwidth, not buffering. The instruction bus delivers **one word
per cycle**, so a two-word instruction occupies two fetch cycles whether DECODE
consumes them in one beat or two, and a DECODE that consumes two words per beat
is asking for more than FETCH can supply. ICACHE can only get ahead while DECODE
is blocked for some other reason — a multi-micro-op instruction, a memory wait,
a bank hold — and in exactly those cycles DECODE is not the bottleneck, so most
of even the 31 and the 4440 are absorbed downstream rather than showing up in the
total. That is the whole of the +21 and the +1776.

DECODE's early redirect rides on the same beat: `early_addr_o` is built from
`ic_data_i(R_IMMEDIATE)`, and `early_valid_o` names `ic_double_i` explicitly for
that reason (see [Early redirect](../cpu_main/README.md#early-redirect)). Under
the model it still fires, one cycle later, and `prog_subroutine` — the benchmark
that optimisation was written for — costs exactly the same 580 cycles. So the
two features do not compound.

**The justification for this module is therefore structural rather than
arithmetic.** It is what allows DECODE to be a purely combinational function of
one beat, with the two-word assembly, its flush behaviour, and its occupancy
accounting factored out into 280 lines that k-induction closes completely. The
cycles it buys are real but small, and the numbers above are what to weigh
against any future change that would cost timing to keep them.

## Flush

There are two of them, and the difference between them is the whole content of
this section.

`rst_i` is not merely a startup reset; it is also the pipeline flush, and
`cpu.vhd` drives it as

```vhdl
ic_rst <= rst_i or wr2fetch_valid;
```

with `wr2fetch_valid` being the same redirect that reaches `fetch.wr_valid_i`
and that resets FETCH's own internal FIFOs. This is mandatory, not a
convenience: when FETCH is redirected it discards its buffers, so any words
still held here belong to the abandoned instruction stream and must be discarded
in the **same** clock cycle. Omitting it delivers one or two stale instructions
to DECODE after every taken branch.

Consequently this module is written for an `rst_i` that pulses during normal
operation:

* `m_valid_o` is gated combinationally by `rst_i`, so the flush takes effect in
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
ic_rst   <= rst_i or wr2fetch_valid;   -- hard
ic_flush <= dc2fetch_valid;            -- soft
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

`f_flush_comb`, `f_flush_offers`, and `f_cover_flush_handshake` in
[icache.psl](../../formal/icache.psl) state both halves and make the mistake
visible. Note also the `flush_i = '0'` term in the trigger of `f_stable_double`
and `f_stable_single` there, where `rst_i` needs none: `rst_i` gates `m_valid_o`
so those triggers cannot fire in a hard-reset cycle at all, whereas a soft flush
leaves the output asserted and they fire normally. `abort` does not cover the
trigger cycle in GHDL, so the qualifier has to be in the trigger.

## Formal verification

`bmc`, `cover`, and `prove` (k-induction), depth 10, elaborated with the small
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
