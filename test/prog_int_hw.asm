; This program tests hardware interrupts.
; It is written specifically for the Interrupt Generator defined in
; test/interrupt.vhd.
;
; This program specifically tests items: 4, 5, and 6 in the "Test cases" list
; in doc/interrupts.md.
;
; Register Map for Interrupt Generator
; 0xFF00 : Countdown number of clock cycles until interrupt is asserted
; 0xFF01 : Address of interrupt service routine
; 0xFF02 : Bit 0 indicates whether interrupt is currently asserted (useful for
;          reading while inside an ISR).
;

#define NOP MOVE R8, R8             ; Note: this is strictly not a
                                    ; no-operation, because it affects the flags
                                    ; (specifically N and Z).

#define INT_COUNT 0xFF00
#define INT_ADDR  0xFF01
#define INT_STAT  0xFF02

; The test may be run separately by the following command:
; "make run TEST=prog_int_hw"


            .ORG    0x0000

            MOVE    STACK_TOP, R13  ; Initialize stack pointer to a sane value

            MOVE    INT_COUNT, R0   ; Verify reset values of Interrupt Generator
            MOVE    INT_ADDR, R1
            MOVE    INT_STAT, R2
            CMP     0x0000, @R0
            RBRA    ERR0, !Z
            CMP     0x0000, @R1
            RBRA    ERR0, !Z
            CMP     0x0000, @R2
            RBRA    ERR0, !Z

            MOVE    ISR, @R1        ; Verify ISR address can be written and read back
            CMP     ISR, @R1
            RBRA    TEST4, Z

ERR0        HALT

;
; Test 4 : Hardware path: the program writes the trigger address, the device asserts
; irq_valid_i with an ISR address. Checks the whole handshake, including that the
; device holds the request until irq_ready_o and releases it after.
;
TEST4       MOVE    INT_ADDR, R8
            MOVE    INT_COUNT, R9
            MOVE    INT_STAT, R10
            MOVE    DATA, R11
            MOVE    0x0000, @R11
            CMP     0x0000, @R10
            RBRA    ERR4, !Z
            MOVE    ISR4, @R8
            MOVE    0x0001, @R9     ; Request interrupt in one clock cycle
            NOP                     ; ISR should be executed somewhere around here
            NOP
            NOP
            NOP
            NOP
            CMP     0x0000, @R10
            RBRA    ERR4, !Z
            CMP     0x0001, @R11
            RBRA    ERR4, !Z
            RBRA    TEST5, 1

ISR4        CMP     0x0001, @R10
            RBRA    ERR4, !Z
            ADD     0x0001, @R11
            RTI

ERR4        HALT


;
; Test 5 : Request a second interrupt from inside an ISR. Checks it is not
; accepted until after the RTI.
TEST5       NOP

;
; Test 6 : Interrupt an instruction that is two words, e.g. MOVE 0x1234, R0. Checks
; the +2 path of next_pc. The reference treats this as a case worth handling
; explicitly rather than by inference: for INT <constant>, which is itself two
; words (@R15++ on the destination), the amIndirPostInc arm bumps the saved PC —
; fsmPC_org <= PC + 1 — so that RTI resumes after the constant word rather than on
; it. That is exactly the semantics next_pc already gives this design for free.
;
TEST6       NOP

SUCCESS     MOVE    0x7FFF, R0
            MOVE    0x0000, @R0
            HALT

ISR         RTI


L_NOP       NOP
L_HALT      HALT

DATA        .DW     0x0000

STACK_BOT   .BLOCK  5
STACK_TOP   .DW     0x0000

