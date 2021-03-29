; Test of timer interrupt

#define RET     MOVE    @R13++, R15

#define A_TIMER_ADDR   0x8000
#define A_TIMER_VALUE  0x8001

                .ORG    0x0000

                MOVE    0, R14               ; Clear register bank
                MOVE    A_TIMER_ADDR, R0
                MOVE    A_TIMER_VALUE, R1
                MOVE    1, R2                ; Value of timer to be written

                MOVE    L_IRQ, @R0           ; Set address of IRQ
                ABRA    L_GO, 1              ; This clears the instruction cache

L_GO            MOVE    R2, @R1              ; This instruction executes in one clock cycle

                INCRB                        ; This instruction executes in one clock cycle
                INCRB                        ; This instruction executes in one clock cycle
                INCRB                        ; This instruction executes in one clock cycle
                HALT

L_IRQ           MOVE    L_RES, R4
                MOVE    R14, @R4
                RTI

L_RES           .DW 0

