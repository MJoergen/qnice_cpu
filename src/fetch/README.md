# FETCH module

## Interfaces
The top-level interface of the FETCH module is as follows:
```
-- From EXECUTE stage
s_valid_i   : in  std_logic;
s_addr_i    : in  std_logic_vector(15 downto 0);

-- Instruction Memory
wbi_cyc_o   : out std_logic;
wbi_stb_o   : out std_logic;
wbi_stall_i : in  std_logic;
wbi_addr_o  : out std_logic_vector(15 downto 0);
wbi_ack_i   : in  std_logic;
wbi_data_i  : in  std_logic_vector(15 downto 0);

-- To DECODE stage
m_valid_o   : out std_logic;
m_ready_i   : in  std_logic;
m_double_o  : out std_logic;
m_addr_o    : out std_logic_vector(15 downto 0);
m_data_o    : out std_logic_vector(31 downto 0);
m_double_i  : in  std_logic
```

Here `m_valid_o` and `m_ready_i` are the usual handshaking signals, `m_addr_o`
is the address of the current instruction, and `m_data_o` contains one or two
words of data, as indicated by the signal `m_double_o`. In either case `data(15
downto 0)` is the instruction, and `data(31 downto 16)` is the immediate
operand if present.

In conjunction with the `m_ready_i` signal, the signal `m_double_i` indicates
whether one or two words are consumed in this clock cycle. Therefore, this
signal must depend combinatorially on the input signals.

## Implementation
The FETCH module consists of a simpler one-word-at-a-time file fetch.vhd and a
simple instruction cache icache.vhd.

## Formal verification

`formal/fetch.sby` verifies `fetch.vhd`, and all three tasks — `bmc`, `cover`
and `prove` (k-induction) — pass. `icache.vhd` has its own job.

Unlike `memory.sby`, this job also loads the `.psl` of every sub-block it
instantiates and then runs

```
chformal -assume2assert fetch/* %M
```

which converts each sub-block's *assumptions about its inputs* into
*assertions on `fetch`*. So the job proves not only that `fetch` behaves, but
that it drives `two_stage_fifo`, `two_stage_buffer` and `pipe_concat` legally.
That is worth keeping in mind when editing the sub-block `.psl` files: an
assumption written there becomes an obligation here.

One cover statement is explicitly removed for this job:

```
chformal -cover -remove c:*i_pipe_concat.f_s0_waits*
```

`pipe_concat`'s `f_s0_waits` covers "s0 arrives before s1". Inside `fetch`, `s1`
is the address FIFO (filled when a request is *issued*) and `s0` is the data
buffer (filled when the response *arrives*), so the address is always present
first and that ordering is unreachable by construction. It stays covered by
`pipe_concat.sby` standalone, where both orderings are reachable.

### Reset and flush escapes

`fetch` resets its address FIFO, data buffer and `pipe_concat` with
`rst_i or dc_valid_i`, so a PC redirect from DECODE flushes them mid-stream.
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

