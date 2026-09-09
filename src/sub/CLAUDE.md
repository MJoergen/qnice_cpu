# Elastic pipeline building blocks

Guidance for Claude Code when working in `src/sub/`. Claude Code loads this file on demand,
when it touches a file in this directory; the repository-wide rules stay in the top-level
[CLAUDE.md](../../CLAUDE.md). These six modules have no README of their own; this file is it.

Six small, reusable valid/ready ("AXI-style") primitives that the rest of the design (FETCH,
REGISTERS, MEMORY, CPU_MAIN) is built from. All are formally verified (`formal/<name>.{psl,sby}`)
— **run `sby -f <name>.sby` after touching any of these**; several of the properties below only
hold because of non-obvious interactions that BMC/induction catches but casual reading won't.

| Module | Depth | Forward path (valid+data) | Backward path (ready) | Notes |
|---|---|---|---|---|
| `one_stage_buffer.vhd` | 1 | combinational when empty | combinational | zero-latency cut-through both ways |
| `one_stage_fifo.vhd` | 1 | **registered** (always ≥1 cycle) | combinational | only `ready` cuts through |
| `two_stage_buffer.vhd` | 2 | combinational when empty | combinational | 2× chained `one_stage_buffer` |
| `two_stage_fifo.vhd` | 2 | registered | combinational, gated by `rst_i` | hand-built, not chained |
| `dp_ram.vhd` | — | registered, 1-cycle, gated by `*_rd_en_i` | n/a | port A reads, port B reads+writes; read-first on same-address collision |
| `pipe_concat.vhd` | 0 | fully combinational | fully combinational | pure join, no storage, `clk_i`/`rst_i` unused |

Subtleties worth knowing before reusing or modifying any of these:

- **`one_stage_buffer` / `two_stage_buffer` are combinational in *both* directions when empty** —
  valid+data ripple forward, ready ripples backward, in the same cycle. Chaining N of them creates
  an O(N) combinational path each way; budget this against Fmax. `one_stage_fifo` / `two_stage_fifo`
  avoid this by registering the forward path, at the cost of a guaranteed cycle of latency.
- **`s_afull_o` (on `one_stage_buffer`) is raw occupancy, not "not ready."** `s_ready_o` can still be
  `'1'` while `s_afull_o='1'` if downstream drains in the same cycle. Gate acceptance on `s_ready_o`,
  never on `s_afull_o`.
- **`m_valid_o` on `one_stage_buffer`/`two_stage_buffer` is gated combinationally by `rst_i`**
  (`(m_valid_r or s_valid_i) and not rst_i`), so asserting reset clears it *within the same cycle*,
  not just on the next clock edge. Any PSL property (or downstream logic) reasoning about "stability
  until accepted" must account for this — a missing `abort rst_i`/`rst_i='1' or ...` escape here is
  exactly the kind of bug that silently breaks k-induction (this has happened before; see git
  history on `formal/two_stage_buffer.psl`).
- **`two_stage_fifo`'s reset is asymmetric by design**, because it doubles as a mid-stream pipeline
  flush (callers like FETCH OR it with the global reset): `s_ready_o` IS gated by `rst_i` (no input
  can be accepted during a flush), but `m_valid_o` is deliberately NOT gated by `rst_i` (an output
  handshake can still complete on the same cycle a flush is asserted). This means **the consumer
  must share the same `rst_i`**, or it will silently accept a word the flush is discarding upstream.
- **`dp_ram` has two ports, each with one address**: port A reads, port B reads *and writes*, both
  at `b_addr_i`. It serves both the register file (reads on A, writes on B, `G_B_READ` false) and
  the testbench memory model (reads on both, writes on B, `G_B_READ` true). Only port B writes,
  because a second writer cannot be inferred — see "no shared variables" in the top-level
  [CLAUDE.md](../../CLAUDE.md#what-this-is).
  **One address per port is load-bearing**: giving the write an address of its own makes three
  independent addresses, which does not fit a two-port primitive, and Vivado duplicates the array
  (measured: 8 RAMB36 instead of 4 on the 8 kW memory). Tying two address ports to the same net at
  the instantiation does *not* rescue it, because `make utilization` synthesises with
  `-flatten_hierarchy none` and elaborates the module in isolation. `G_B_READ` exists for the same
  reason: a caller's `b_rd_en_i => '0'` is invisible in that pass, so the dead read port gets built
  and inflates the register file's row by 40 LUTs of phantom LUTRAM.
- **`dp_ram` read/write collision is read-first**: a read and write to the same address in the same
  cycle returns the *old* value; the new value is visible from the next read. `G_RAM_STYLE="block"`
  adds a falling-edge staging register per read port to ease BRAM timing (requires a reasonably
  balanced clock duty cycle) — `"distributed"` is a plain single rising-edge read register.
  `G_INIT_FILE` loads the array from a text file; memory contents are never reset by `rst_i`
  (unused, kept only for interface uniformity).
- **`pipe_concat` has `clk_i`/`rst_i` ports that do nothing** — it's stateless combinational logic;
  the ports exist only so it fits the same instantiation convention and formal-env uniformity as
  everything else.
- All six modules require the standard valid/ready contract from upstream: once `s_valid_i='1'` and
  `s_ready_o='0'`, both `s_valid_i` and `s_data_i` must hold stable until accepted. Several files
  check this in simulation only (`pragma translate_off`/`on`), not in synthesis.
