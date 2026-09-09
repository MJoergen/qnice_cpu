# FETCH

Guidance for Claude Code when working in `src/fetch/`. Claude Code loads this file on demand,
when it touches a file in this directory; the repository-wide rules stay in the top-level
[CLAUDE.md](../../CLAUDE.md). Full design writeup: [README.md](README.md).

## FETCH redirect (branch penalty)

A redirect (`fetch.wr_valid_i`, i.e. CPU_MAIN's `fetch_valid_o`) does **not** terminate the
Wishbone cycle. `CYC` stays asserted and the first request of the new instruction stream goes out on
the next clock cycle; tearing the bus cycle down instead costs an extra cycle before `STB` can be
reasserted, and that cycle lands on the critical path of every taken branch. Worth **−4.7%** on
`prog.asm` and up to −9.1% on branch-dense programs, one cycle per redirect.

Two things are load-bearing and easy to undo. The redirect step in `p_wishbone` must run **before**
the issue step (it used to run after and override it) — that ordering *is* the optimisation. And the
issue budget must count `wb_stale` alongside the allocated slots, or a redirect can push the number
of unacknowledged requests past `C_MAX_PENDING`.

Because the requests abandoned by a redirect are no longer cancelled by dropping `CYC`, they still
owe acknowledgements; `wb_stale` counts them and `wb_rsp_accept` is gated to discard them. That
replaces interface contract (c) with a new contract (d): **the slave must acknowledge in order**
(MEMORY already assumes this). The old teardown remains for the one case that cannot be redirected
— a request stuck on `STB` while the slave stalls, which cannot happen against the dual-port RAM
here. See [src/fetch/README.md](README.md#redirect).

When touching `fetch.psl`, note that `f_wb_outstanding` is cleared on the design's *cancel*
condition, not on `wr_valid_i`. Reverting that one line is silent: `f_wb_slave_ack_idle` then
forbids the stale acknowledgements entirely, so the discard logic goes unexercised and every
assertion still passes. `f_cover_abort_redirect` and `f_cover_stale_ack` are what catch it.
