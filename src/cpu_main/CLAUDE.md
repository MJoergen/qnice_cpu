# DECODE, SEQUENCER, PREPARE, WRITE

Guidance for Claude Code when working in `src/cpu_main/`. Claude Code loads this file on demand,
when it touches a file in this directory; the repository-wide rules stay in the top-level
[CLAUDE.md](../../CLAUDE.md). Full design writeup: [README.md](README.md).

## Microcode / instruction decomposition

The core trick of this design: DECODE dynamically translates each CISC-like QNICE instruction into
1-3 RISC-like micro-operations via a combinational ROM (`src/cpu_main/sub/microcode.vhd`), indexed
by a 4-bit classification of the instruction (reads-from-dst / writes-to-dst / src-in-memory /
dst-in-memory). DECODE emits that whole list in a single beat; SEQUENCER
(`src/cpu_main/sequencer.vhd`), instantiated by CPU_MAIN **between DECODE and PREPARE**, then
issues it one micro-op per clock cycle. This exists because an instruction like `ADD @R0, @R1`
needs two memory reads and one memory write, but only one memory operation is possible per cycle —
the micro-ops serialize that. Each micro-op is a 12-bit word (`LAST`, `REG_MOD_SRC`, `REG_MOD_DST`,
`MEM_WAIT_SRC`, `MEM_WAIT_DST`, `REG_WRITE`, `MEM_READ_SRC`, `MEM_READ_DST`, `MEM_WRITE`); the
three register-op bits are mutually exclusive, as are the three memory-op bits. Immediate operands
(`@R15++`) are special-cased to skip a memory read since FETCH already supplies the value inline.
**`alu_data.vhd`'s four `null` arms are not dead code.** `CMP` and `CTRL` genuinely are don't-cares
(their microcode writes nothing), but `JMP` is **load-bearing**: DECODE rewrites a JMP's microcode
to carry `REG_WRITE` with `res_reg = R15`, so the branch target reaches the PC through
`res_other`'s `"0" & src_data_i` default. Give that arm a value of its own and every branch in the
CPU breaks — verified by forcing it, which makes the suite stop reaching `HALT` at all. The fourth,
reserved opcode `0xD`, is classified like `ADD` and so writes the source over the destination; that
is unsanctioned fall-through, which is why `p_unimplemented` traps it. See
[src/cpu_main/README.md](README.md#microcoding-of-instructions) for the full worked
examples (`MOVE R0,R1`, `MOVE @R0,@R1`, `ADD @R0,@R1`).

Data hazards from this pipelining (later WRITE-stage register writes vs. earlier DECODE-stage
register reads) are handled via bypass logic described in
[src/cpu_main/README.md](README.md#bypass), and via write-before-read semantics
built into REGISTERS itself (see [src/registers/README.md](../registers/README.md#operation)).
Write-before-read applies to both `R14` write ports: the ordinary one and the dedicated SR port
(`wr_sr_en_i`), the latter forwarded by `src_val_o`/`dst_val_o` as well. `test/prog_hazard.asm`
exercises these paths directly.

## Register bank switch

The upper eight bits of `R14` select which of the 256 pages of `R0`-`R7` the register file
presents, and **changing them costs a pipeline flush unless nothing already in flight would read
the old bank**. DECODE issues a register read two stages ahead of WRITE, so the instruction after
an `INCRB` has already read the old bank by the time the new one lands, and forwarding the bank
into the read address cannot fix it (the address reaches the RAM a cycle before the new bank
exists). Exactly two instructions can be affected — the one in DECODE's output register and the one
at its input — and only if they *consume* a banked value: WRITING `R0`-`R7` is safe, because the
write carries a register number down the pipeline and lands in whatever bank is current when it
retires, which is the new one. So `uses_bank` in `src/cpu_main/decode.vhd` classifies each
instruction, `bank_switch_o`/`bank_stale_i` carry the two bits between WRITE and DECODE, and an
`INCRB`/`DECRB` flushes only when the instruction in DECODE's output register reads a banked
register, holds DECODE for one cycle when the one at its input does, and costs nothing otherwise —
which is the case for the standard `INCRB` / `MOVE R8, R0` prologue and `DECRB` /
`MOVE @R13++, R15` epilogue. All ten bank switches in `prog.asm` are now free (15070 → 15030
cycles, i.e. a 4-cycle branch penalty apiece). One detail is load-bearing for TIMING rather than
function: `is_crb` is decoded in DECODE and carried in the stage records, not re-derived from
`prep_stage_i.inst` in WRITE. Deriving it there puts a ten-bit compare in front of `fetch_valid_o`
and the design **does not build** (WNS −0.036 ns at 7.25 ns, 4 failing endpoints); with the
precomputed bit it closes at +0.093 ns.

An ordinary write to `R14` still flushes **unconditionally**, and its trigger is deliberately
**syntactic** — "writes `R14`, or writes `R15`", collapsed into a single product term because the
two share `reg_addr_o(3 downto 1)` — and NOT a comparison of the new bank against the old: the
precise form is more selective but costs the entire timing margin, since `fetch_valid_o` is the
reset pin of every flip-flop in DECODE and PREPARE. So `MOVE ST____C_, R14` does cost a branch
penalty. Do not "optimise" either half of this without reading the measured numbers in the "Register bank
switch" comment in `write.vhd`.
`test/prog_hazard.asm` `H11`-`H17` pin the behaviour down (before the flush existed, `INCRB` /
`ADD 0, R0` silently copied one bank's `R0` into the next bank's; `H14`-`H15` are the write-only
case that must NOT flush), and `f_flush_on_bank_change` / `f_hold_on_bank_change` in
`formal/cpu_main.psl` state what `uses_bank` has to cover: whenever the bank bits actually change,
an in-flight instruction that consumes a banked value must be flushed or refused. Both derive
"consumes a banked value" from the raw instruction encoding rather than from `uses_bank`, so
narrowing `uses_bank` fails them. See
[src/cpu_main/README.md](README.md#register-bank-switch).

## Self-modifying code

Instruction and data memory are the same physical RAM, so a store can land on an
instruction that FETCH/ICACHE/DECODE/PREPARE has already read. `smc_hit` in
`src/cpu_main/write.vhd` detects a store within 32 words after the current instruction
and joins `fetch_valid_o`, flushing exactly as a taken branch does. Two constraints shape
that code and are easy to undo by accident: the flush net is the reset pin of every
flip-flop in DECODE and PREPARE, so the comparison must subtract **raw stage registers**
(the exact `mem_req_addr_o - next_pc` form misses timing at −0.042 ns), and it must stay a
*window* rather than "every store" (unconditional flushing costs +8.5% on `prog.asm`,
+64% on `prog_interleave.asm`). Over-approximating the window is always safe — a spurious
flush costs cycles, not correctness. `test/prog_self_modifying.asm` covers both edges;
see [doc/README.md](../../doc/README.md#self-modifying-code).

`smc_hit` is qualified by `inst_done_o`, which is correct for every store in the microcode
ROM — they all sit on the micro-op carrying `C_LAST` — and misses the **one** that does
not: the return address `ASUB`/`RSUB` pushes, which `decode.vhd` writes by hand onto the
instruction's *first* micro-op. `smc_push` is the second term that covers it, and its
shape is not interchangeable with the first. The flush must be **deferred to the last
micro-op** (a flush mid-sequence resets SEQUENCER and discards the rest of the branch,
falling through to `next_pc`); it applies **only when `early_jmp` suppressed WRITE's own
redirect**, since otherwise the `R15` write flushes anyway and FETCH refills from the
target after the push has landed; and its window is measured from the **target**
(`prep_stage_i.immediate`) and is **8, not 32**. That last number is load-bearing in the
opposite direction from the one above: a stack placed just past the end of the program is
normal, so a loose window here is not free — 16 costs `prog_mandel_perf` 4.7% and the
ordinary 32-word window costs `prog_subroutine` 8%, most of the early redirect's gain.
The bound is derived and measured in the comment above `smc_push`; `T8` in
`test/prog_self_modifying.asm` and `f_flush_on_smc_push` in `formal/cpu_main.psl` pin it.

Separately, `mem_req_op_o`'s **write** bit is ANDed with `update_reg`, the branch-taken
term that also gates `p_reg`'s register writes. Without it a conditional `ASUB`/`RSUB`
that was *not* taken still wrote its return address to `SP-1` — `SP` itself was correctly
untouched, so nothing in the suite noticed and the stray writes simply sat in
`test/prog.writes.golden`. The two **read** bits must stay ungated: a not-taken
`ASUB @R0, Z` still reaches its last micro-op, which carries `C_MEM_WAIT_SRC` and would
wait forever for a read that was never issued. `f_no_push_when_not_taken` in
`formal/cpu_main.psl` and the sentinel in `prog.asm`'s `L_COND_ASUB_00` are the tripwires.


## Early redirect (unconditional branches)

A branch normally costs **four cycles**: one to register the new PC in FETCH, one for the
instruction memory's read latency, one in ICACHE, and one because DECODE and PREPARE are then
empty. Measured on `prog.asm` before the early redirect below, the 731 redirects cost 3625 cycles
of a then-15030-cycle run — **24%**.

`ABRA`/`ASUB`/`RBRA`/`RSUB <label>, 1` escapes most of that, because DECODE can resolve it without
help: the condition selects `SR` bit 0, which reads as 1 always, and the target is the immediate
word FETCH already delivered alongside the instruction (`decode.vhd` even computes the absolute
address for the relative modes, for `seq_stage_o.immediate`). So `early_jmp` in
`src/cpu_main/decode.vhd` drives `early_valid_o`/`early_addr_o` on the cycle DECODE accepts the
instruction, two cycles before WRITE would have; `cpu.vhd` merges that with WRITE's redirect into
the single port `fetch.vhd` sees. **Four cycles becomes two, and one for `ASUB`/`RSUB`**, whose
second micro-op overlaps another cycle of the refill. **It costs 0.091 ns of the 0.093 ns of margin
there was** (WNS +0.093 → +0.002 ns): it closes, the cycles are free at the shipping frequency, and
there is now essentially nothing left for the next change. The critical path is unmoved — inside
PREPARE, through the ALU operand muxing, which this does not touch — so re-measure rather than
assume any particular edit is what moved it.

Three things are load-bearing:

* **The early redirect flushes FETCH and ICACHE only** — never DECODE or PREPARE. By the end of the
  cycle the branch is in DECODE's output register and everything downstream is *older*, so those
  two are the only place wrong-path instructions live. Hence `ic_rst` (from WRITE) and `ic_flush`
  (from DECODE) are separate signals in `cpu.vhd`.
* **The ICACHE flush must be soft.** `icache.vhd`'s `rst_i` gates `m_valid_o` combinationally, which
  is mandatory for WRITE's flush and fatal here: DECODE raises the flush *because* it is accepting
  the branch being offered this cycle, so gating `m_valid_o` withdraws the handshake the flush is
  derived from and the loop settles on "no branch accepted, no flush" — silently inert. `flush_i`
  therefore clears the buffer at the edge and gates `s_ready_o` but leaves `m_valid_o` alone, the
  same asymmetry `two_stage_fifo` documents in its contract (b). `f_flush_offers` and
  `f_cover_flush_handshake` in `formal/icache.psl` are the tripwires.
* **WRITE must not redirect again**, or it discards what the early redirect went to fetch.
  `prep_stage_i.early_jmp` carries that in the stage records beside `is_crb` and `is_sub`. Its `rst_i` companion term in
  `write.vhd` is not decoration: `p_reg` forces the `R15 = 0` write that gives FETCH its initial PC
  during reset, and PREPARE's output register is *not* cleared by reset, so a stale `early_jmp`
  would suppress it.

`test/prog_subroutine.asm` exists because the rest of the suite is unrepresentative here: only 73
of `prog.asm`'s 731 redirects are of this form (−1.0%), whereas the QNICE-FPGA monitor sources are
62% unconditional-immediate branches (328 `RSUB x, 1`, 182 `RBRA x, 1` against 308 conditional
`RBRA`). That benchmark falls 678 → 580 cycles, **−14.5%**.

Two things were measured and rejected, both defeated by the same fact — `dp_ram`'s block-RAM read
stages through a **falling-edge** register, so a RAM address path gets **half a clock period**.
Removing FETCH's `wbi_addr_o` register — the one-cycle gap between `WRITE/fetch_addr_o` and
`FETCH/wb_addr_o` in the loop timing diagram — concatenates a 7.002 ns leg (PREPARE to that
register) with a 2.698 ns one (that register to the RAM), i.e. ~9.7 ns plus a mux into a 3.625 ns
budget; it does not fit in a full 7.25 ns period either, and it would buy one cycle per redirect,
5.4% of the suite. Making ICACHE cut-through merges a 4.373 ns path with a 2.558 ns (also
half-cycle) and a 6.565 ns one. Details and numbers in doc/README.md's Optimizations section — read
them before trying either again. **The lever that works on a branch penalty is making the redirect
DECISION arrive earlier, not moving the register**, which is what the early redirect above does.
