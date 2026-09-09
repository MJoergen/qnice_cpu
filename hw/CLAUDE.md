# Synthesis, timing, and utilization

Guidance for Claude Code when working in `hw/`. Claude Code loads this file on demand,
when it touches a file in this directory; the repository-wide rules stay in the top-level
[CLAUDE.md](../CLAUDE.md). Covers both synthesis flows and the generated numbers in
[doc/README.md](../doc/README.md), which are refreshed from here.

## Yosys synthesis

`make synth` runs `ghdl -a` over every source file and then `yosys -m ghdl` with `synth_xilinx`. It
is a second opinion on synthesisability, not a build — nothing consumes `cpu.edif` — and it is not
in CI.

**It elaborates `cpu`, not `system`, and that is forced rather than chosen.** `system` instantiates
`test/wb_dp_mem.vhd`, whose `dp_ram` runs at `G_RAM_STYLE = "block"` and therefore reads port A on
the **falling** clock edge. That is the deliberate timing trick documented in `src/sub/dp_ram.vhd`
and in [Elastic pipeline building blocks](../src/sub/CLAUDE.md); Vivado
implements it happily. Yosys cannot: every port in its Xilinx BRAM library
(`share/yosys/xilinx/brams_*.txt`) is declared `clock posedge`, so a negedge read port has no
mapping at all and the run dies on `no valid mapping found for memory ... dp_ram_r`. Expressing the
same edge as a rising edge on an explicitly inverted clock net does **not** work — yosys folds
`posedge !clk` straight back into `negedge clk`. The alternatives were giving up the falling-edge
register, which costs Vivado timing, or letting an 8 kW array map to logic, so the scope was
narrowed instead.

Little is lost by that. Everything under `src/` is still synthesised, including both `dp_ram`
configurations the CPU itself uses (`distributed`); what drops out is testbench-only — the memory
model, `wb_mux`, `test_monitor`, and `system.vhd` — and Vivado synthesises all of that for real in
`make system.bit`. The `ghdl -a` step still covers every file, so a syntax or semantic error
anywhere still fails the target.

This broke in `1617539`, which coalesced `test/dp_mem.vhd` into `src/sub/dp_ram.vhd`: the old
testbench model read both ports on the rising edge, so the negedge port arrived in `system` for the
first time with that merge. `git bisect run` on `make synth` finds it in about eight steps —
the target takes under four seconds.


## Utilization numbers

The "Utilization" section of [doc/README.md](../doc/README.md) is generated, not hand-maintained:
`make utilization` runs two Vivado passes and `hw/update_utilization.py` rewrites the numbers.
Two passes are needed because the two tables measure different things on purpose — device totals
come from the shipping `-flatten_hierarchy rebuilt` build after place-and-route (reused from
`make system.bit`, since place-and-route is the expensive part), while the per-module table needs a
synthesis-only `-flatten_hierarchy none` pass, because "rebuilt" lets synthesis move logic across
module boundaries and reports the ALU inside PREPARE.

It also fills in the "The critical path" note there. That path has been the same in every build
measured: register-to-register inside PREPARE, between two fields of `wr_stage_o`, through the ALU
operand muxing. It is **routing-dominated** (about two thirds interconnect), which has a practical
consequence — logic nowhere near it can still move the slack by perturbing placement. A single
flip-flop added next to ICACHE for the HALT gate once cost 0.284 ns, the whole margin, without
appearing on the path; re-measure after an unrelated edit rather than assuming it cannot matter.

**The clock constraint is 7.45 ns** (`hw/system.xdc`), and has been relaxed twice. It was 7.25 ns
until that placement sensitivity made `make system.bit` a coin flip: two refactors that added no logic — the design came
out 14 LUTs *smaller* — moved WNS from +0.025 to −0.018 ns and stopped the build emitting a
bitstream, while five `place_design` directives on one unchanged netlist spanned +0.028 to
−0.028 ns. Every timing figure quoted in this file and in the per-module READMEs predates the change
and was measured at 7.25 ns; they have deliberately been left as measured, so read them as a record
of that experiment rather than as the current margin. Shortening the critical loop was tried before
relaxing the constraint and does not pay — the reasoning and the measurements are in
doc/README.md's Utilization section.

The **second** relaxation, 7.35 → 7.45 ns, paid for a correctness fix rather than a refactor. Two
flush terms landed on `fetch_valid_o` in quick succession and between them spent more than the
margin. The subroutine-push term (see [Self-modifying code](../src/cpu_main/CLAUDE.md#self-modifying-code)) cost 0.055 ns of
the 0.060 ns there was, without touching the critical path — it reads `prep_stage_i.immediate`,
which WRITE had no other use for, so sixteen flip-flops synthesis used to optimise away came back
and the area moved the placement. Deferring the R14/R15 pointer flush then cost about 0.11 ns more,
and the design missed at 7.35 ns by −0.100 ns with 21 failing endpoints. Neither is logic depth that
can be optimised away: the failing path runs `r14` → `update_reg` → `reg_we_o` → `fetch_valid_o` →
ICACHE's clock enable and is 80% routing, and `update_reg` cannot leave that net. Two attempts to
buy it back — lifting `rst_i` out of a series OR into its own term, and deleting a provably dead arm
of `smc_hit` — moved WNS by 0.004 ns between them. Current build: **WNS +0.017 ns**, no failing
endpoints.

The script rewrites **numbers only** — the surrounding analysis is a hand-written design argument.
Every substitution is anchored on an exact pattern and a missing anchor is a hard error, so
rewording one of those sentences breaks `make utilization` loudly rather than silently leaving a
stale figure behind. **This cannot run in CI**: Vivado is a 38 GB licensed install and
GitHub-hosted runners cannot host it, so the numbers are refreshed deliberately, on a machine that
has Vivado.
