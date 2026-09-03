; A subroutine-heavy benchmark, shaped like ordinary QNICE code rather than
; like a CPU test.
;
; WHY THIS EXISTS
; The other programs here are correctness tests, and their branch mix reflects
; that: prog.asm resolves 731 pipeline redirects, of which only 73 (10%) are an
; unconditional branch to an immediate target. Real QNICE code is nothing like
; that. Counting the branches in the QNICE-FPGA monitor sources gives
;
;    RSUB <label>, 1     328      unconditional, immediate target
;    RBRA <label>, 1     182      unconditional, immediate target
;    RBRA <label>, cond  308      conditional
;    everything else       5
;
; i.e. 62% of all branches are the unconditional immediate form -- every
; subroutine call and every unconditional jump. That is the class DECODE
; resolves on its own (see "Early redirect" in src/cpu_main/decode.vhd), so
; measuring that optimisation against prog.asm alone understates it by roughly
; a factor of six. This program exists to keep an honest number in
; test/prog_subroutine.stats.golden.
;
; It is deliberately CONSERVATIVE about that mix. Per loop iteration it issues
; two unconditional calls, two returns and one conditional branch; the returns
; are "MOVE @R13++, R15", whose target comes out of memory and so can never be
; resolved early. Two of five redirects benefit, against the monitor's rather
; higher share.
;
; It is also a real test, not just a stopwatch: the accumulated result is
; checked before the status word is written, so a pipeline bug that corrupts a
; call or a return fails the run rather than merely changing the cycle count.

#define RET     MOVE    @R13++, R15

                .ORG    0x0000

                MOVE    STACK, R13      ; Stack pointer, pre-decremented on push
                MOVE    0x0000, R0      ; Accumulator
                MOVE    0x0010, R1      ; Loop counter, 16 down to 1

LOOP            MOVE    R1, R8          ; Argument
                RSUB    TRIPLE, 1
                ADD     R9, R0          ; Accumulate the result
                SUB     0x0001, R1
                RBRA    LOOP, !Z

                CMP     0x0198, R0      ; 3 * (1 + 2 + ... + 16) = 3 * 136 = 408
                RBRA    FAIL, !Z
                RBRA    EXIT, 1

; ---------------------------------------------------------------
; TRIPLE: R9 = 3 * R8, computed through a nested call so that the
; stack and the return path are exercised two levels deep. R8 is
; preserved by DOUBLE, which touches only R9.
; ---------------------------------------------------------------
TRIPLE          MOVE    R8, R9
                RSUB    DOUBLE, 1
                ADD     R8, R9
                RET

DOUBLE          ADD     R9, R9
                RET

; ---------------------------------------------------------------
FAIL            MOVE    0x1FFF, R0      ; Test status word (see test/README.md)
                MOVE    0x0001, @R0     ; Non-zero = fail
                HALT

EXIT            MOVE    0x1FFF, R0      ; Test status word (see test/README.md)
                MOVE    0x0000, @R0     ; 0 = pass
                HALT

                .DW     0, 0, 0, 0, 0, 0, 0, 0
STACK
