# REGISTERS

Guidance for Claude Code when working in `src/registers/`. Claude Code loads this file on demand,
when it touches a file in this directory; the repository-wide rules stay in the top-level
[CLAUDE.md](../../CLAUDE.md). Full design writeup: [README.md](README.md).

## Writing PSL against the forwarding bypass

That write-before-read/bypass forwarding is also the thing to remember when writing PSL for
`registers.vhd`: a property that predicts a forwarded `src_val_o`/`dst_val_o`/`sr_val_o` value one
cycle out is only true if no *other* write to the same register lands on that exact checked cycle
— such a write legitimately overrides the prediction via the same combinational bypass, and BMC
will find that as a "failing" counterexample that isn't actually a bug. Every forwarding property
in [formal/registers.psl](../../formal/registers.psl) carries an explicit escape clause for this reason.
Separately, `sr_val_o`'s combinational mux previously didn't give `rst_i` the same top priority
that `reg_sr`'s register process (`p_sr`) does, so a write coinciding with reset could briefly leak
onto `sr_val_o` before `reg_sr` caught up next edge — fixed by making `rst_i` the first term in
that mux (see [src/registers/README.md](README.md#formal-verification)).
