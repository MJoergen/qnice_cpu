; Stress test for the ALU flags input path (t_stage.alu_flags -> alu_flags.sr_i).
;
; The point of this program is to make an instruction CONSUME the Status
; Register in the ALU (carry-in of ADDC/SUBC, fill bits of SHL/SHR) on the
; clock cycle immediately after another instruction PRODUCED it. If the flags
; reaching the ALU were one pipeline beat stale, these would read the previous
; instruction's flags instead.
;
; Note: prog.asm already covers the VALUES on this path -- its stimulus tables
; run both polarities of the relevant SR bit. What this program adds is timing:
; producer and consumer in adjacent clock cycles, at several spacings and in
; several addressing modes.
;
; Every failed sub-test branches to its own HALT. Success falls through to EXIT.

; Status register (bits 7 - 0) of R14:  - - V N Z C X 1
#define ST______ 0x0001
#define ST____C_ 0x0005

; ---------------------------------------------------------------
; T1: C produced by ADD, consumed by the ADDC in the very next cycle
; ---------------------------------------------------------------
                MOVE    0x0000, R2
                MOVE    0x0000, R3
                MOVE    0xFFFF, R0
                MOVE    0x0001, R1
                ADD     R1, R0          ; R0 = 0x0000, C = 1
                ADDC    R3, R2          ; R2 = 0 + 0 + C
                CMP     0x0001, R2
                ABRA    T2, Z
E_T1            HALT

; ---------------------------------------------------------------
; T2: same shape, but the ADD produces C = 0
; ---------------------------------------------------------------
T2              MOVE    0x0000, R2
                MOVE    0x0000, R3
                MOVE    0x0001, R0
                MOVE    0x0001, R1
                ADD     R1, R0          ; R0 = 0x0002, C = 0
                ADDC    R3, R2          ; R2 = 0 + 0 + 0
                CMP     0x0000, R2
                ABRA    T3, Z
E_T2            HALT

; ---------------------------------------------------------------
; T3: C written to R14 through the ORDINARY register write port,
;     consumed by the ADDC in the very next cycle
; ---------------------------------------------------------------
T3              MOVE    0x0000, R2
                MOVE    0x0000, R3
                MOVE    ST____C_, R14   ; C = 1
                ADDC    R3, R2          ; R2 = 0 + 0 + 1
                CMP     0x0001, R2
                ABRA    T4, Z
E_T3            HALT

; ---------------------------------------------------------------
; T4: one instruction of spacing between producer and consumer.
;     MOVE updates N and Z but preserves C.
; ---------------------------------------------------------------
T4              MOVE    0x0000, R2
                MOVE    0x0000, R3
                MOVE    0xFFFF, R0
                MOVE    0x0001, R1
                ADD     R1, R0          ; C = 1
                MOVE    0x0007, R5      ; preserves C
                ADDC    R3, R2          ; R2 = 0 + 0 + 1
                CMP     0x0001, R2
                ABRA    T5, Z
E_T4            HALT

; ---------------------------------------------------------------
; T5: two instructions of spacing
; ---------------------------------------------------------------
T5              MOVE    0x0000, R2
                MOVE    0x0000, R3
                MOVE    0xFFFF, R0
                MOVE    0x0001, R1
                ADD     R1, R0          ; C = 1
                MOVE    0x0007, R5
                MOVE    0x0008, R6
                ADDC    R3, R2          ; R2 = 0 + 0 + 1
                CMP     0x0001, R2
                ABRA    T6, Z
E_T5            HALT

; ---------------------------------------------------------------
; T6: ADDC with a MEMORY source operand, so the consumer is a
;     multi-micro-op instruction that stalls on the memory read
; ---------------------------------------------------------------
T6              MOVE    D_ZERO, R6
                MOVE    0x0000, R7
                MOVE    0xFFFF, R0
                MOVE    0x0001, R1
                ADD     R1, R0          ; C = 1
                ADDC    @R6, R7         ; R7 = 0 + 0 + 1
                CMP     0x0001, R7
                ABRA    T7, Z
E_T6            HALT

; ---------------------------------------------------------------
; T7: differential SUBC. Same operands, borrow-in 0 vs 1.
;     The two results MUST differ, whatever the exact convention is.
; ---------------------------------------------------------------
T7              MOVE    0x0000, R2
                MOVE    0x0000, R3
                MOVE    ST______, R14   ; C = 0
                SUBC    R3, R2
                MOVE    R2, R8          ; save first result

                MOVE    0x0000, R2
                MOVE    0x0000, R3
                MOVE    ST____C_, R14   ; C = 1
                SUBC    R3, R2
                MOVE    R2, R9          ; save second result

                CMP     R8, R9
                ABRA    T8, !Z          ; must differ
E_T7            HALT

; ---------------------------------------------------------------
; T8: differential SHR. The vacated top bits are filled with C.
; ---------------------------------------------------------------
T8              MOVE    0x8000, R2
                MOVE    ST______, R14   ; C = 0
                SHR     0x0004, R2
                MOVE    R2, R8

                MOVE    0x8000, R2
                MOVE    ST____C_, R14   ; C = 1
                SHR     0x0004, R2
                MOVE    R2, R9

                CMP     R8, R9
                ABRA    EXIT, !Z        ; must differ
E_T8            HALT

; ---------------------------------------------------------------
EXIT            MOVE    OK, R8
                HALT

OK              .ASCII_W "OK\n"
D_ZERO          .DW     0x0000
