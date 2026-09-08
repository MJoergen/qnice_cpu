; Test of the EAE (Extended Arithmetic Element), test/eae.vhd.
;
; Table-driven over all four operations. Each row is
;
;    operand_0, operand_1, command, expected RESULT_HI, expected RESULT_LO
;
; and the table is terminated by a row whose first word is 0x1111 -- so 0x1111
; must not be used as operand_0.
;
; ON FAILURE the status word is the 1-based row number, with bit 15 set if it
; was RESULT_HI rather than RESULT_LO that differed. So status 0x0007 means row
; 7's quotient/low word was wrong and 0x8007 means its remainder/high word was.
; Without that, locating one bad row among the 43 means bisecting the table by
; hand.
;
; WHAT THE EXPECTED VALUES ARE DERIVED FROM
;
; eae.vhd computes division as two separate numeric_std operators:
;
;    RESULT_LO <= op0_s / op1_s        -- truncates TOWARDS ZERO
;    RESULT_HI <= op0_s mod op1_s      -- takes the sign of the DIVISOR
;
; Those two are not the matching pair. "mod" is the floored remainder, whose
; partner quotient is the floored one; pairing it with a truncating "/" means
; that for a negative result with a non-zero remainder the identity
; op0 = op1*quotient + remainder does NOT hold. -30000 / 7 is the clearest
; case: the quotient is -4285 and the remainder is +2, and 7*(-4285) + 2 is
; -29993, not -30000.
;
; That is not a typo in this file -- it is what the hardware does, and this is
; a test of the hardware. Upstream QNICE-FPGA's own vhdl/EAE.vhd has exactly
; the same two lines, so the behaviour is inherited rather than invented here,
; and a program written against the real device sees it. The values below were
; computed from the numeric_std definitions and confirmed against GHDL, not
; read back out of a passing run.
;
; UPSTREAM'S EMULATOR DISAGREES, and deliberately testing this pins that down.
; emulator/qnice.c computes the signed remainder with C's "%", which takes the
; sign of the DIVIDEND, so the two differ on exactly the rows where the signs
; differ and the remainder is non-zero -- 8 of the 21 DIVS rows here. See
; test/README.md's cross-check section; "make crosscheck" knows about this and
; asserts that the divergence is still confined to this program.

EAE_REG_OPERAND_0    .EQU    0xFF18
EAE_REG_OPERAND_1    .EQU    0xFF19
EAE_REG_RESULT_LO    .EQU    0xFF1A
EAE_REG_RESULT_HI    .EQU    0xFF1B
EAE_REG_CSR          .EQU    0xFF1C             ; Command and Status Register

EAE_CSR_MULU         .EQU    0x0000             ; unsigned multiply
EAE_CSR_MULS         .EQU    0x0001             ; signed multiply
EAE_CSR_DIVU         .EQU    0x0002             ; unsigned division
EAE_CSR_DIVS         .EQU    0x0003             ; signed division

                MOVE    STIM_EAE, R8
                MOVE    0x0000, R5              ; row counter, 1-based
L_EAE_01        MOVE    @R8++, R0               ; First operand
                CMP     0x1111, R0
                RBRA    L_END, Z                ; End of test
                ADD     0x0001, R5              ; now testing row R5
                MOVE    @R8++, R1               ; Second operand
                MOVE    @R8++, R2               ; Command
                MOVE    @R8++, R3               ; Expected result hi
                MOVE    @R8++, R4               ; Expected result lo

                ; Load device addresses to registers
                MOVE    EAE_REG_OPERAND_0, R9
                MOVE    EAE_REG_RESULT_LO, R10
                MOVE    EAE_REG_CSR, R11

                ; Move operands and command to EAE device
                MOVE    R0, @R9++
                MOVE    R1, @R9
                MOVE    R2, @R11

                ; Verify result
                CMP     @R10++, R4              ; RESULT_LO
                RBRA    E_EAE_01, !Z            ; Jump if error
                CMP     @R10, R3                ; RESULT_HI
                RBRA    L_EAE_01, Z
                ADD     0x8000, R5              ; it was RESULT_HI that differed
E_EAE_01        MOVE    0x7FFF, R0
                MOVE    R5, @R0                 ; which row, and which half
                HALT

L_END           MOVE    0x7FFF, R0
                MOVE    0x0000, @R0  ; 0 = pass
                HALT

; The four original rows, kept as they were.
STIM_EAE        .DW     0xD431, 0x3039, EAE_CSR_MULU, 0x27F8, 0x6EE9
                .DW     0xD431, 0x3039, EAE_CSR_MULS, 0xF7BF, 0x6EE9
                .DW     0xD431, 0x3039, EAE_CSR_DIVU, 0x134D, 0x0004
                .DW     0xD431, 0x3039, EAE_CSR_DIVS, 0x046A, 0x0000

; MULU: the 32-bit product must survive the full unsigned range.
                .DW     0xFFFF, 0xFFFF, EAE_CSR_MULU, 0xFFFE, 0x0001   ; rows 5..
                .DW     0xFFFF, 0x0001, EAE_CSR_MULU, 0x0000, 0xFFFF
                .DW     0x8000, 0x0002, EAE_CSR_MULU, 0x0001, 0x0000   ; carry into HI
                .DW     0x3039, 0xD431, EAE_CSR_MULU, 0x27F8, 0x6EE9   ; operands swapped
                .DW     0x0000, 0xFFFF, EAE_CSR_MULU, 0x0000, 0x0000

; MULS: all four sign combinations, and the two extremes. -32768 * -32768 is
; the one product that does not fit in a signed 32-bit result as a negative
; number, and 255 * 257 is the largest signed product with a zero HI word.
                .DW     0x7530, 0x0007, EAE_CSR_MULS, 0x0003, 0x3450   ; +30000 * +7
                .DW     0x8AD0, 0x0007, EAE_CSR_MULS, 0xFFFC, 0xCBB0   ; -30000 * +7
                .DW     0x7530, 0xFFF9, EAE_CSR_MULS, 0xFFFC, 0xCBB0   ; +30000 * -7
                .DW     0x8AD0, 0xFFF9, EAE_CSR_MULS, 0x0003, 0x3450   ; -30000 * -7
                .DW     0x8000, 0x8000, EAE_CSR_MULS, 0x4000, 0x0000   ; -32768 * -32768
                .DW     0xFFFF, 0xFFFF, EAE_CSR_MULS, 0x0000, 0x0001   ; -1 * -1
                .DW     0xFFFF, 0x0001, EAE_CSR_MULS, 0xFFFF, 0xFFFF   ; -1 * +1
                .DW     0x00FF, 0x0101, EAE_CSR_MULS, 0x0000, 0xFFFF   ; 255 * 257

; DIVU: no sign to get wrong, so this covers the range and the boundaries.
                .DW     0xFFFF, 0x0001, EAE_CSR_DIVU, 0x0000, 0xFFFF
                .DW     0xFFFF, 0xFFFF, EAE_CSR_DIVU, 0x0000, 0x0001
                .DW     0xFFFF, 0x0002, EAE_CSR_DIVU, 0x0001, 0x7FFF   ; odd dividend
                .DW     0x3039, 0xD431, EAE_CSR_DIVU, 0x3039, 0x0000   ; divisor > dividend
                .DW     0xD431, 0x0007, EAE_CSR_DIVU, 0x0001, 0x1E50
                .DW     0x8000, 0x8000, EAE_CSR_DIVU, 0x0000, 0x0001

; DIVS: the point of this table. Quotient truncates towards zero, remainder
; takes the sign of the DIVISOR, so the two disagree about which way to round
; whenever the operands have different signs. The rows marked (*) are the ones
; where upstream's emulator, using C's "%", gives a different remainder.
                .DW     0x7530, 0x0007, EAE_CSR_DIVS, 0x0005, 0x10BD   ; +30000 / +7 = +4285 rem +5
                .DW     0x8AD0, 0x0007, EAE_CSR_DIVS, 0x0002, 0xEF43   ; -30000 / +7 = -4285 rem +2 (*)
                .DW     0x7530, 0xFFF9, EAE_CSR_DIVS, 0xFFFE, 0xEF43   ; +30000 / -7 = -4285 rem -2 (*)
                .DW     0x8AD0, 0xFFF9, EAE_CSR_DIVS, 0xFFFB, 0x10BD   ; -30000 / -7 = +4285 rem -5

; The same four signs again with |dividend| < |divisor|, so every quotient is
; zero and the remainder carries the whole result.
                .DW     0x2BCF, 0x3039, EAE_CSR_DIVS, 0x2BCF, 0x0000   ; +11215 / +12345
                .DW     0xD431, 0x3039, EAE_CSR_DIVS, 0x046A, 0x0000   ; -11215 / +12345 (*)
                .DW     0x2BCF, 0xCFC7, EAE_CSR_DIVS, 0xFB96, 0x0000   ; +11215 / -12345 (*)
                .DW     0xD431, 0xCFC7, EAE_CSR_DIVS, 0xD431, 0x0000   ; -11215 / -12345

; Exact division: the remainder is zero, so "sign of the divisor" has nothing
; to act on and all four combinations agree with everyone's definition.
                .DW     0x0064, 0x000A, EAE_CSR_DIVS, 0x0000, 0x000A   ; +100 / +10
                .DW     0xFF9C, 0x000A, EAE_CSR_DIVS, 0x0000, 0xFFF6   ; -100 / +10
                .DW     0x0064, 0xFFF6, EAE_CSR_DIVS, 0x0000, 0xFFF6   ; +100 / -10
                .DW     0xFF9C, 0xFFF6, EAE_CSR_DIVS, 0x0000, 0x000A   ; -100 / -10

; Division by +/-1, and the most negative dividend. -32768 / -1 is +32768,
; which is not representable, and wraps back to -32768 -- the one case where
; the quotient is wrong in every 16-bit machine and has to be pinned down
; rather than argued about.
                .DW     0x3039, 0x0001, EAE_CSR_DIVS, 0x0000, 0x3039   ; +12345 / +1
                .DW     0x3039, 0xFFFF, EAE_CSR_DIVS, 0x0000, 0xCFC7   ; +12345 / -1
                .DW     0x8000, 0x0001, EAE_CSR_DIVS, 0x0000, 0x8000   ; -32768 / +1
                .DW     0x8000, 0xFFFF, EAE_CSR_DIVS, 0x0000, 0x8000   ; -32768 / -1, wraps
                .DW     0x8000, 0x0007, EAE_CSR_DIVS, 0x0006, 0xEDB7   ; -32768 / +7 (*)
                .DW     0x8000, 0xFFF9, EAE_CSR_DIVS, 0xFFFF, 0x1249   ; -32768 / -7

; Remainder larger in magnitude than the quotient, both ways round.
                .DW     0x0001, 0xFFFE, EAE_CSR_DIVS, 0xFFFF, 0x0000   ; +1 / -2 = 0 rem -1 (*)
                .DW     0xFFFF, 0x0002, EAE_CSR_DIVS, 0x0001, 0x0000   ; -1 / +2 = 0 rem +1 (*)

                .DW     0x1111
