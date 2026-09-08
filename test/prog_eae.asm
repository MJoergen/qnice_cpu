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
L_EAE_01        MOVE    @R8++, R0               ; First operand
                CMP     0x1111, R0
                RBRA    L_END, Z                ; End of test
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
                CMP     @R10++, R4
                RBRA    E_EAE_01, !Z            ; Jump if error
                CMP     @R10, R3
                RBRA    L_EAE_01, Z
                HALT
E_EAE_01        HALT

L_END           MOVE    0x7FFF, R0
                MOVE    0x0000, @R0  ; 0 = pass
ERROR           HALT

STIM_EAE        .DW     0xD431, 0x3039, EAE_CSR_MULU, 0x27F8, 0x6EE9
                .DW     0xD431, 0x3039, EAE_CSR_MULS, 0xF7BF, 0x6EE9
                .DW     0xD431, 0x3039, EAE_CSR_DIVU, 0x134D, 0x0004
                .DW     0xD431, 0x3039, EAE_CSR_DIVS, 0x046A, 0x0000
                .DW     0x1111

