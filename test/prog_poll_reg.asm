; The control experiment for test/prog_poll.asm.
;
; This is the same five-word loop, at the same addresses, with one difference:
; the first instruction reads a register instead of memory. It therefore does
; no data access at all, and it runs in NINE clock cycles per iteration where
; prog_poll.asm takes ten. That one cycle is the entire cost of the data read,
; and doc/README.md#Where-the-ten-cycles-go quotes the comparison to show why:
; the read's latency hides inside the fetch of the loop's remaining instruction
; words, and all it actually costs is stalling DECODE long enough that the
; two-deep Icache has to refuse a word.
;
; Keeping the two programs word-for-word aligned is the point of the file, so
; that the nine-versus-ten really does isolate the data access:
;
;   * "MOVE DEV, R0" stays, although the loop no longer uses R0, because
;     removing it would move every address in the program.
;   * "XOR R1, R1" replaces one word of "MOVE R1, R1" padding, so that R1 is a
;     defined zero rather than whatever the register file powers up holding.
;     The loop needs the AND to leave Z set, exactly as prog_poll.asm does.
;
; CAUTION: LIKE test/prog_poll.asm, THIS PROGRAM NEVER HALTS, AND IS THEREFORE
; DELIBERATELY NOT IN THE "TESTS" LIST IN THE TOP-LEVEL MAKEFILE. R1 is zero,
; so the AND always leaves Z set and the branch is always taken.
; "make check TEST=prog_poll_reg" would run until the G_TIMEOUT watchdog in
; test/tb_cpu.vhd failed it. Run it with an explicit stop time instead:
;
;    make build
;    ghdl -r --std=08 tb_cpu -gG_ROM=test/prog_poll_reg.rom \
;         -gG_REGISTER_BANK_WIDTH=8 --stop-time=500ns
;
; The disassembly that src/debug.vhd reports is enough to read the period off:
; the loop settles by 300 ns and retires its MOVE every 90 ns thereafter.

      .ORG 0x0000

      MOVE  DEV, R0     ; Unused here; kept so the addresses match prog_poll.asm
      XOR   R1, R1      ; R1 = 0, the value the loop will poll
      MOVE  R1, R1      ; Padding, so the loop is entered with a full pipeline
      MOVE  R1, R1

LOOP  MOVE  R1, R2      ; 0x0005. prog_poll.asm has "MOVE @R0, R2" here
      AND   0x0002, R2  ; 0x0006, 0x0007
      RBRA  LOOP, Z     ; 0x0008, 0x0009

DEV   .DW   0x0000      ; 0x000A. Read by nothing in this variant.
