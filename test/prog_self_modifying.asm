; Tests for self-modifying code
; The purpose is specifically to test the pipelining, i.e. that the pipeline
; gets updated correctly when instructions immediately following are updated.
;
; T1, T2, T4, T5, and T7 are the regression tests: each one fails without the
; store-hits-fetch-window flush in src/cpu_main/write.vhd, verified by stashing
; that change and running each sub-test on its own.
;
; T3 and T6 are deliberately the opposite -- they pass with or without that
; flush, and are here to pin down its two edges. T3 stores FAR ahead, outside
; the window, where correctness comes from nothing having prefetched the
; address yet; if the window were ever sized too small, the gap between the
; real prefetch depth and the window is what T3 walks through. T6 stores to
; data that merely happens to sit near the program counter, which costs a
; needless flush that must not change what executes.
;
; Every failed sub-test branches to its own HALT. Success falls through to EXIT.

                .ORG 0x0000

; ---------------------------------------------------------------
; T1: Update the opcode of the next instruction
; ---------------------------------------------------------------
T1              MOVE    L_T1, R0        ; Address of instruction
                MOVE    L_T1_1, R1      ; Address of new instruction
                MOVE    @R1, R1
                MOVE    0x5555, R2      ; Prepare register value for test
                MOVE    0xAAAA, R3      ; Prepare register value for test
                MOVE    R1, @R0         ; Overwrite opcode of next instruction
L_T1            MOVE    R2, R3          ; This becomes "MOVE R3, R2"
                CMP     0xAAAA, R2      ; Expected value
                ABRA    E_T1_1, !Z
                CMP     0xAAAA, R3      ; Expected value
                ABRA    T2, Z
E_T1_2          HALT
E_T1_1          HALT
L_T1_1          MOVE    R3, R2          ; New instruction, to replace the one at
                                        ; L_T1


; ---------------------------------------------------------------
; T2: Update the operand of the next instruction
; ---------------------------------------------------------------
T2              MOVE    L_T2, R0        ; Address of instruction opcode
                ADD     0x0001, R0      ; Address of instruction operand
                MOVE    0xAAAA, R1      ; New operand
                MOVE    0x0000, R2      ; Prepare register value for test
                MOVE    R1, @R0         ; Overwrite operand of next instruction
L_T2            MOVE    0x5555, R2      ; This becomes "MOVE 0xAAAA, R2"
                CMP     0xAAAA, R2      ; Expected value
                ABRA    T3, Z
E_T2            HALT


; ---------------------------------------------------------------
; T3: Modify an instruction FAR ahead, well outside the flush window.
;     Nothing has prefetched it, so it must work for the opposite reason to
;     T1/T2: the fetch that eventually reaches it sees the new value. This is
;     the upper edge of the window in src/cpu_main/write.vhd.
; ---------------------------------------------------------------
T3              MOVE    L_T3, R0
                MOVE    L_T3_1, R1
                MOVE    @R1, R1
                MOVE    0x1234, R2      ; Prepare register value for test
                MOVE    0x8765, R3      ; Prepare register value for test
                MOVE    R1, @R0         ; Overwrite the instruction at L_T3

                ; Padding, to push L_T3 outside the flush window. These also
                ; have to still execute correctly themselves.
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4
                MOVE    R4, R4

L_T3            MOVE    R2, R3          ; This becomes "MOVE R3, R2"
                CMP     0x8765, R2      ; Expected value
                ABRA    E_T3, !Z
                ABRA    T4, 1
E_T3            HALT
L_T3_1          MOVE    R3, R2          ; New instruction, to replace L_T3


; ---------------------------------------------------------------
; T4: Modify the instruction TWO ahead, not the immediately following one.
;     The instruction in between must still execute as originally written.
; ---------------------------------------------------------------
T4              MOVE    L_T4, R0
                MOVE    L_T4_1, R1
                MOVE    @R1, R1
                MOVE    0x1111, R2      ; Prepare register value for test
                MOVE    0x2222, R3      ; Prepare register value for test
                MOVE    0x0000, R4
                MOVE    R1, @R0         ; Overwrite the instruction at L_T4
                MOVE    0x3333, R4      ; In between: must run unmodified
L_T4            MOVE    R2, R3          ; This becomes "MOVE R3, R2"
                CMP     0x2222, R2      ; Expected value
                ABRA    E_T4_1, !Z
                CMP     0x3333, R4      ; The in-between instruction ran
                ABRA    T5, Z
E_T4_2          HALT
E_T4_1          HALT
L_T4_1          MOVE    R3, R2          ; New instruction, to replace L_T4


; ---------------------------------------------------------------
; T5: Modify the instruction through a PRE-DECREMENT pointer. The WRITE stage
;     derives the memory address as dst_val-1 in that mode, so this reaches
;     mem_req_addr_o by a different path than T1-T4.
; ---------------------------------------------------------------
T5              MOVE    L_T5, R0
                ADD     0x0001, R0      ; One past the instruction
                MOVE    L_T5_1, R1
                MOVE    @R1, R1
                MOVE    0x4444, R2      ; Prepare register value for test
                MOVE    0x5555, R3      ; Prepare register value for test
                MOVE    R1, @--R0       ; Overwrite the instruction at L_T5
L_T5            MOVE    R2, R3          ; This becomes "MOVE R3, R2"
                CMP     0x5555, R2      ; Expected value
                ABRA    T6, Z
E_T5            HALT
L_T5_1          MOVE    R3, R2          ; New instruction, to replace L_T5


; ---------------------------------------------------------------
; T6: A store to DATA that happens to sit close to the program counter. It is
;     inside the flush window, so it costs a needless flush -- but it must not
;     change what executes.
; ---------------------------------------------------------------
T6              MOVE    D_NEAR, R0
                MOVE    0x0000, R1
                MOVE    0x9999, @R0     ; Data store within the window
                ADD     0x0001, R1      ; Must still execute, exactly once
                ADD     0x0001, R1
                CMP     R1, 0x0002
                ABRA    T7_CHECK, Z
E_T6            HALT
D_NEAR          .DW     0x0000


; ---------------------------------------------------------------
; T7: Self-modification inside a LOOP -- the classic idiom. The loop body
;     patches its own next iteration, so R2 must accumulate 1 then 2 then 3.
; ---------------------------------------------------------------
T7_CHECK        MOVE    0x0001, R9      ; The three values the patched
                MOVE    0x0002, R10     ; instruction reads, in turn
                MOVE    0x0003, R11
                MOVE    0x0000, R2      ; Accumulator
                MOVE    0x0003, R6      ; Trip count
                MOVE    L_T7, R7        ; Address of the patched instruction

; Each pass rewrites the instruction that the CPU is about to execute, so the
; hazard is exercised three times over. R_SRC_REG is bits 11 downto 8 of the
; instruction word, hence 0x0100 per step: R8 -> R9 -> R10 -> R11. R8 is only
; ever the starting ENCODING, never read, because the patch lands before the
; instruction runs for the first time.
L_T7_LOOP       MOVE    @R7, R0         ; Read the instruction back...
                ADD     0x0100, R0      ; ...and bump its source register field
                MOVE    R0, @R7
L_T7            ADD     R8, R2          ; Runs as ADD R9/R10/R11, R2
                SUB     0x0001, R6
                ABRA    L_T7_LOOP, !Z

                CMP     R2, 0x0006      ; 1 + 2 + 3
                ABRA    EXIT, Z
E_T7            HALT


; ---------------------------------------------------------------
EXIT            MOVE    0x1FFF, R0      ; Test status word (see test/README.md)
                MOVE    0x0000, @R0     ; 0 = pass
                HALT

