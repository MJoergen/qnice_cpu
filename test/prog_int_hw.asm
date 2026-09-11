; This program tests hardware interrupts.
; It is written specifically for the Interrupt Generator defined in
; test/interrupt.vhd.
;
; This program specifically tests items: 4, 5, and 6 in the "Test cases" list
; in doc/interrupts.md.
;
; Register Map for Interrupt Generator (copied verbatim from test/interrupt.vhd):
; 0xBF00 : Countdown number of clock cycles until interrupt is asserted. After count-down,
;          interrupt line remains asserted until accepted, and is then released. Counter
;          reads back as zero.
; 0xBF01 : Address of interrupt service routine. Initialized to zero, which happens to be
;          the same as the CPU reset address.
; 0xBF02 : Bit 0 indicates whether interrupt is currently asserted (can only ever read
;          non-zero when inside an ISR).
; 0xBF03 : Number of accepted interrupt requests

#define NOP MOVE R8, R8                     ; Note: this is strictly not a
                                            ; no-operation, because it affects the flags
                                            ; (specifically N and Z).
                                            ; However, it does use a non-banked register,
                                            ; which is important in some special cases in
                                            ; handling of pipeline flushing.

INT_COUNT            .EQU    0xBF00
INT_ADDR             .EQU    0xBF01
INT_STAT             .EQU    0xBF02
INT_ACCEPT           .EQU    0xBF03

EAE_REG_OPERAND_0    .EQU    0xFF18
EAE_REG_OPERAND_1    .EQU    0xFF19
EAE_REG_RESULT_LO    .EQU    0xFF1A
EAE_REG_RESULT_HI    .EQU    0xFF1B
EAE_REG_CSR          .EQU    0xFF1C         ; Command and Status Register

EAE_CSR_MULU         .EQU    0x0000         ; unsigned multiply
EAE_CSR_MULS         .EQU    0x0001         ; signed multiply
EAE_CSR_DIVU         .EQU    0x0002         ; unsigned division
EAE_CSR_DIVS         .EQU    0x0003         ; signed division

; The test may be run separately by the following command:
; "make run TEST=prog_int_hw"


            .ORG    0x0000

            MOVE    STACK_TOP, R13          ; Initialize stack pointer to a sane value
                                            ; This is also used to check for spurious writes to
                                            ; the Stack Pointer.

            MOVE    INT_COUNT, R0           ; Verify reset values of Interrupt Generator
            MOVE    INT_ADDR, R1
            MOVE    INT_STAT, R2
            CMP     0x0000, @R0
            RBRA    ERR0, !Z
            CMP     0x0000, @R1
            RBRA    ERR0, !Z
            CMP     0x0000, @R2
            RBRA    ERR0, !Z

            MOVE    ERR0, @R1               ; Verify ISR address can be written and read back
            CMP     ERR0, @R1
            RBRA    TEST4, Z

ERR0        HALT

;
; Test 4 : Hardware path: the program writes the trigger address, the device asserts
; irq_valid_i with an ISR address. Checks the whole handshake, including that the
; device holds the request until irq_ready_o and releases it after.
;
TEST4       MOVE    INT_COUNT, R0
            MOVE    INT_ADDR, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            MOVE    0x0000, @R3             ; Incremented by entry into ISR
            CMP     0x0000, @R2             ; Verify interrupt line is not asserted
            RBRA    ERR4, !Z
            MOVE    ISR4, @R1               ; Set ISR address
            MOVE    0x0001, @R0             ; Request interrupt in one clock cycle
            NOP
            NOP                             ; ISR should be executed somewhere around here
            NOP
            NOP
            NOP
            CMP     0x0000, @R2             ; Verify interrupt line is not asserted
            RBRA    ERR4, !Z
            CMP     0x0001, @R3             ; Verify ISR has been entered exactly once
            RBRA    ERR4, !Z

            CMP     STACK_TOP, R13          ; Verify stack pointer unchanged.
            RBRA    ERR4, !Z
            MOVE    R13, R0                 ; Verify stack sentinel values
            CMP     0xBEEF, @R0
            RBRA    ERR4, !Z
            CMP     0xDEAD, @--R0
            RBRA    ERR4, !Z

            RBRA    TEST5, 1                ; End of Test 4.

ISR4        INCRB
            MOVE    INT_COUNT, R0
            MOVE    INT_ADDR, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            CMP     0x0000, @R2             ; Verify interrupt line is not asserted any more
            RBRA    ERR4, !Z
            ADD     0x0001, @R3             ; Indicate ISR has been entered
            CMP     STACK_TOP, R13          ; Verify stack pointer unchanged.
            RBRA    ERR4, !Z
            DECRB
            RTI

ERR4        HALT


;
; Test 5 : Request a second interrupt from inside an ISR. Checks it is not
; accepted until after the RTI.
TEST5       MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            MOVE    DATA1, R4
            MOVE    0x0000, @R3             ; Incremented by entry into ISR
            MOVE    0x0000, @R4             ; Incremented by entry into ISR
            CMP     0x0000, @R2             ; Verify interrupt line is not asserted
            RBRA    ERR5, !Z
                                            ; Setup first ISR.
            MOVE    ISR5, @R0               ; Set ISR address
            MOVE    0x0001, @R1             ; Request interrupt in one clock cycle

            NOP
            NOP                             ; First ISR should fire around here.
            NOP

            CMP     0x0001, @R3             ; Verify first ISR been fired.
            RBRA    ERR5, !Z

            CMP     0x0001, @R4             ; Verify second ISR has been fired too.
            RBRA    ERR5, !Z

            RBRA    TEST6, 1                ; End of Test 5.

ISR5        INCRB
            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            MOVE    DATA1, R4
            CMP     0x0000, @R2             ; Verify interrupt line is not asserted any more
            RBRA    ERR5, !Z
            ADD     0x0001, @R3             ; Indicate first ISR has been entered

                                            ; Setup second ISR, while inside first ISR.
            MOVE    ISR5A, @R0              ; Set new ISR address
            MOVE    0x0001, @R1             ; Request interrupt in one clock cycle

            NOP
            NOP                             ; Second interrupt should NOT fire here
            NOP

            CMP     0x0001, @R2             ; Verify interrupt line is asserted now.
            RBRA    ERR5, !Z

            CMP     0x0000, @R4             ; Verify second ISR has not been fired yet.
            RBRA    ERR5, !Z

            DECRB
            RTI

ISR5A       INCRB
            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            MOVE    DATA1, R4
            CMP     0x0000, @R2             ; Verify interrupt line is not asserted any more
            RBRA    ERR5, !Z
            ADD     0x0001, @R4             ; Indicate second ISR has been entered
            DECRB
            RTI

ERR5        HALT

;
; Test 6 : Interrupt an instruction that is two words, e.g. MOVE 0x1234, R0. Checks
; the +2 path of next_pc. The reference treats this as a case worth handling
; explicitly rather than by inference: for INT <constant>, which is itself two
; words (@R15++ on the destination), the amIndirPostInc arm bumps the saved PC —
; fsmPC_org <= PC + 1 — so that RTI resumes after the constant word rather than on
; it. That is exactly the semantics next_pc already gives this design for free.
;
TEST6       MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            MOVE    0x0000, @R3             ; Incremented by entry into ISR
            MOVE    ISR6, @R0               ; Set ISR address
            MOVE    0x0000, R8              ; Unbanked accumulator
            MOVE    0x0001, R9              ; Unbanked increment
            MOVE    0x0002, R10             ; Unbanked expected value
            MOVE    0x0002, @R1             ; Request interrupt in two clock cycles
            ADD     R9, R8
            ADD     R9, R8                  ; ISR should enter **after** this instruction.
            ADD     R9, R8
            CMP     0x0003, R8
            RBRA    ERR6, !Z
            CMP     0x0001, @R3             ; Check ISR has been entered
            RBRA    ERR6, !Z

            MOVE    0x0000, R8              ; Unbanked accumulator
            MOVE    0x0001, R9              ; Unbanked increment
            MOVE    0x0001, R10             ; Unbanked expected value
            MOVE    0x0002, @R1             ; Request interrupt in two clock cycles
            ADD     0x0001, R8              ; ISR should enter **after** this instruction.
            ADD     0x0001, R8
            ADD     0x0001, R8
            CMP     0x0003, R8
            RBRA    ERR6, !Z
            CMP     0x0002, @R3             ; Check ISR has been entered
            RBRA    ERR6, !Z

            MOVE    0x0000, R8              ; Unbanked accumulator
            MOVE    0x0001, R9              ; Unbanked increment
            MOVE    0x0002, R10             ; Unbanked expected value
            MOVE    0x0003, @R1             ; Request interrupt in two clock cycles
            ADD     0x0001, R8
            ADD     0x0001, R8              ; ISR should enter **after** this instruction.
            ADD     0x0001, R8
            CMP     0x0003, R8
            RBRA    ERR6, !Z
            CMP     0x0003, @R3             ; Check ISR has been entered
            RBRA    ERR6, !Z

;
; Test 6A : Interrupt instruction with multiple micro-ops, as well as
; instructions with a large memory latency (EAE).
;
TEST6A      MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            MOVE    DATA1, R8
            MOVE    DATA2, R9
            MOVE    ISR6A, @R0              ; Set ISR address
            MOVE    0x0000, @R8             ; Accumulator in memory
            MOVE    0x0001, @R9             ; Increment in memory
            MOVE    0x0001, R10             ; Expected value
            MOVE    0x0001, @R1             ; Request interrupt in one clock cycle
            ADD     @R9, @R8                ; Three micro-op instruction
            ADD     @R9, @R8
            CMP     0x0002, @R8
            RBRA    ERR6A, !Z
            CMP     0x0004, @R3             ; Check ISR has been entered
            RBRA    ERR6A, !Z

            MOVE    0x0000, @R8             ; Accumulator in memory
            MOVE    0x0001, @R9             ; Increment in memory
            MOVE    0x0001, R10             ; Expected value
            MOVE    0x0002, @R1             ; Request interrupt in two clock cycles
            ADD     @R9, @R8                ; Three micro-op instruction
            ADD     @R9, @R8
            CMP     0x0002, @R8
            RBRA    ERR6A, !Z
            CMP     0x0005, @R3             ; Check ISR has been entered
            RBRA    ERR6A, !Z

            MOVE    0x0000, @R8             ; Accumulator in memory
            MOVE    0x0001, @R9             ; Increment in memory
            MOVE    0x0001, R10             ; Expected value
            MOVE    0x0003, @R1             ; Request interrupt in three clock cycles
            ADD     @R9, @R8                ; Three micro-op instruction
            ADD     @R9, @R8
            CMP     0x0002, @R8
            RBRA    ERR6A, !Z
            CMP     0x0006, @R3             ; Check ISR has been entered
            RBRA    ERR6A, !Z

            MOVE    0x0000, @R8             ; Accumulator in memory
            MOVE    0x0001, @R9             ; Increment in memory
            MOVE    0x0002, R10             ; Expected value
            MOVE    0x0004, @R1             ; Request interrupt in four clock cycles
            ADD     @R9, @R8                ; Three micro-op instruction
            ADD     @R9, @R8
            CMP     0x0002, @R8
            RBRA    ERR6A, !Z
            CMP     0x0007, @R3             ; Check ISR has been entered
            RBRA    ERR6A, !Z

; The read from EAE is interrupted, and the ISR performs another read from EAE.
; Both read values are checked.
            MOVE    EAE_REG_OPERAND_0, R8   ; EAE operand
            MOVE    10, @R8++               ; Set first operand
            MOVE    20, @R8++               ; Set second operand
            MOVE    EAE_REG_RESULT_LO, R8   ; EAE result address
            MOVE    EAE_CSR_MULU, R9        ; EAE command value
            MOVE    EAE_REG_CSR, R11        ; EAE command address
            MOVE    200, R10                ; Expected value
            MOVE    0x0002, @R1             ; Request interrupt in two clock cycles
            MOVE    R9, @R11                ; Start EAE operation
            MOVE    @R8, R11                ; Read result - this instruction will stall
            CMP     R10, R11                ; Check result of read
            RBRA    ERR6A, !Z
            CMP     0x0008, @R3             ; Check ISR has been entered
            RBRA    ERR6A, !Z

;
; Test 6B : Interrupt instruction during a pipeline flush: Taken branch and write-to-R14.
;
TEST6B      MOVE    0x8000, R14             ; Set register bank
            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            MOVE    0x0000, @R3             ; Incremented by entry into ISR
            MOVE    ISR6B, @R0              ; Set ISR address
            MOVE    0x0001, @R1             ; Request interrupt in one clock cycle
            ABRA    L_6B_1, 1
L_6B_1      CMP     0x0001, @R3             ; Verify ISR was entered
            RBRA    ERR6B, !Z

            MOVE    0x0002, @R1             ; Request interrupt in two clock cycles
            ABRA    L_6B_2, 1
L_6B_2      CMP     0x0002, @R3             ; Verify ISR was entered
            RBRA    ERR6B, !Z

            MOVE    R14, R9                 ; Store register bank
            MOVE    R0, R10                 ; Store old value
            ADD     0x0600, R14             ; Change register bank
            NOT     R10, R0                 ; Clobber R0 with wrong value
            MOVE    INT_COUNT, R1
            MOVE    0x0001, @R1             ; Request interrupt in one clock cycle
            MOVE    R9, R14                 ; Revert register bank
            CMP     R10, R0                 ; Verify register bank reverted correctly
            RBRA    ERR6B, !Z
            CMP     0x0003, @R3             ; Verify ISR was entered
            RBRA    ERR6B, !Z

            MOVE    R14, R9                 ; Store register bank
            MOVE    R0, R10                 ; Store old value
            ADD     0x0500, R14             ; Change register bank
            NOT     R0, R0                  ; Clobber R0 with wrong value
            MOVE    INT_COUNT, R1
            MOVE    0x0002, @R1             ; Request interrupt in two clock cycles
            MOVE    R9, R14                 ; Revert register bank
            CMP     R10, R0                 ; Verify register bank reverted correctly
            RBRA    ERR6B, !Z
            CMP     0x0004, @R3             ; Verify ISR was entered
            RBRA    ERR6B, !Z

            RBRA    TEST7, 1                ; End of Test 6.

ISR6        CMP     R10, R8                 ; Expect this number of ADD statements to have executed.
            RBRA    ERR6, !Z
            MOVE    DATA, R3
            ADD     0x0001, @R3             ; Indicate ISR has been entered
            RTI

ISR6A       CMP     R10, @R8                ; Verify expected value
            RBRA    ERR6A, !Z
            MOVE    DATA, R3
            ADD     0x0001, @R3             ; Indicate ISR has been entered
            RTI

ISR6B       MOVE    DATA, R3
            ADD     0x0001, @R3             ; Indicate ISR has been entered
            RTI

ERR6        HALT
ERR6A       HALT
ERR6B       HALT

;
; Test 7 : Check restoring of R14 after a hardware interrupt.
;
TEST7       MOVE    0xF000, R14             ; Clobbered register bank
            NOT     INT_ADDR, R0            ; Deliberately write the wrong value
            MOVE    0x4000, R14             ; Set the register bank
            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    DATA, R3
            MOVE    0x0000, @R3             ; Incremented by entry into ISR
            MOVE    ISR7, @R0               ; Set ISR address
            MOVE    0x0001, @R1             ; Request interrupt in one clock cycle

            NOP
            NOP
            NOP

            MOVE    R14, R10
            AND     0xFF00, R10
            CMP     0x4000, R10             ; Verify Register Bank is restored correctly
            RBRA    ERR7, !Z

            CMP     INT_ADDR, R0            ; Verify banked register is correct
            RBRA    ERR7, !Z
            CMP     INT_COUNT, R1           ; Verify banked register is correct
            RBRA    ERR7, !Z

            RBRA    TOTAL, 1               ; End of Test 7.

ISR7        MOVE    0xF000, R14             ; Clobber the register bank
            MOVE    R14, R0                 ; Write to banked register
            MOVE    DATA, R1
            ADD     0x0001, @R1             ; Indicate ISR has been entered
            RTI

ERR7        HALT

TOTAL       MOVE    INT_ACCEPT, R0          ; Verify total number of interrupts
                                            ; acccepted by CPU
            CMP     10, @R0
            RBRA    SUCCESS, Z
            HALT

;
; Success. All test cases have passed. Write 0 to the test status register at 0x7FFF.
;
SUCCESS     MOVE    0x7FFF, R0
            MOVE    0x0000, @R0
; Final test: Fire an interrupt after the halt
            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    ISR_HALT, @R0           ; Set ISR address
            MOVE    0x0005, @R1             ; Request interrupt in a few clock cycles
            HALT
            HALT
ISR_HALT    RBRA    ISR_HALT, 1


DATA        .DW     0x0000
DATA1       .DW     0x0000
DATA2       .DW     0x0000

STACK_BOT   .BLOCK  5
            .DW     0xDEAD                  ; Sentinel values, should never be written to
STACK_TOP   .DW     0xBEEF                  ; Sentinel values, should never be written to

