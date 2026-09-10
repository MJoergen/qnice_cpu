; This program tests software interrupts, i.e. the INT and RTI instructions
; combined. They work regardless of any outside devices, and specifically do
; not require even the existence of the irq_valid_i, irq_addr_i, and irq_ready_o
; ports.
;
; This program specifically tests items: 1, 2, 3, and 7 in the "Test cases" list
; in doc/interrupts.md, as well as test case 6 (two word instruction) for
; software interrupts.

#define NOP MOVE R8, R8             ; Note: this is strictly not a
                                    ; no-operation, because it affects the flags
                                    ; (specifically N and Z).
                                    ; It deliberately uses a non-banked
                                    ; register. This is needed in TEST_7.

; The test may be run separately by the following command:
; "make run TEST=prog_int_sw"


            .ORG    0x0000

            NOP                     ; Placeholders for HALT instructions. The
            NOP                     ; purpose is to catch any stray jumps to
            NOP                     ; 0x0000.


            MOVE    0x0000, R0      ; Copy three HALTs to placeholder
            MOVE    L_HALT, R1
            MOVE    @R1, @R0++
            MOVE    @R1, @R0++
            MOVE    @R1, @R0++

            MOVE    STACK_TOP, R13  ; Initialize stack pointer to a sane value

            MOVE    R13, R0         ; Place sentinel value
            MOVE    0xBEEF, @--R0   ; at the top of the stack

;
; Test 1 : INT R0, with R0 holding the ISR address; the ISR sets a marker and
; RTIs. Checks the ISR is entered, runs once, and returns.
;
; Note: There are a total of six different instruction encodings to test here.
;
TEST_1A     MOVE    DATA, R8        ; Prepare data before INT
            MOVE    0x1000, @R8
            MOVE    0x1001, R9      ; Expected value

            INT     ISR1            ; Execute interrupt through immediate operand

            CMP     R9, @R8         ; Assumes R8 and R9 are untouched
            RBRA    TEST_1B, Z
            HALT                    ; Error

TEST_1B     MOVE    DATA, R8        ; Prepare data before INT
            MOVE    0x1100, @R8
            MOVE    0x1101, R9      ; Expected value

            MOVE    ISR1, R0
            INT     R0              ; Execute interrupt through register

            CMP     R9, @R8         ; Assumes R8 and R9 are untouched
            RBRA    TEST_1C, Z
            HALT                    ; Error

TEST_1C     MOVE    DATA, R8        ; Prepare data before INT
            MOVE    0x1200, @R8
            MOVE    0x1201, R9      ; Expected value

            MOVE    DATA1, R0
            MOVE    ISR1, @R0
            INT     @R0             ; Execute interrupt through register indirect

            CMP     R9, @R8         ; Assumes R8 and R9 are untouched
            RBRA    TEST_1D, Z
            HALT                    ; Error

TEST_1D     MOVE    DATA, R8        ; Prepare data before INT
            MOVE    0x1300, @R8
            MOVE    0x1301, R9      ; Expected value

            MOVE    DATA1, R0
            MOVE    ISR1, @R0
            INT     @R0++           ; Execute interrupt through register indirect post-increment
            CMP     DATA2, R0       ; DATA1+1: Verify post-increment
            RBRA    FAIL_1D, !Z

            CMP     R9, @R8         ; Assumes R8 and R9 are untouched
            RBRA    TEST_1E, Z
            HALT                    ; Error
FAIL_1D     HALT                    ; Error

TEST_1E     MOVE    DATA, R8        ; Prepare data before INT
            MOVE    0x1400, @R8
            MOVE    0x1401, R9      ; Expected value

            MOVE    DATA1, R0
            MOVE    ISR1, @R0++
            INT     @--R0           ; Execute interrupt through register indirect pre-decrement
            CMP     DATA1, R0       ; Verify pre-decrement
            RBRA    FAIL_1E, !Z

            CMP     R9, @R8         ; Assumes R8 and R9 are untouched
            RBRA    TEST_2, Z
            HALT                    ; Error
FAIL_1E     HALT                    ; Error

ISR1        MOVE    DATA, R2
            ADD     0x0001, @R2
            NOP                     ; TODO: Remove these NOPs.
            NOP                     ; Make sure memory operations are complete
            NOP                     ; before encountering the RTI
            RTI
            HALT

;
; Test 2: As above, but the instruction after INT increments a counter. Checks
; the return address is exact — that instruction must run exactly once, neither
; skipped nor repeated.
;
TEST_2      MOVE    DATA1, R0       ; Prepare data before INT
            MOVE    0x1234, @R0
            MOVE    0x1111, R1
            MOVE    STACK_TOP, R13  ; Initialize stack pointer
            INT     ISR2            ; Two-word instruction
            ADD     R1, @R0         ; Assumes R0 and R1 are untouched
            CMP     0x2345, @R0
            RBRA    TEST_2A, Z
            HALT                    ; Error

TEST_2A     CMP     STACK_TOP, R13  ; Verify stack pointer unchanged
            RBRA    TEST_2B, Z
            HALT

TEST_2B     MOVE    R13, R0         ; Verify sentinel value
            SUB     0x0001, R0
            CMP     0xBEEF, @R0     ; at top of stack
            RBRA    TEST_2C, Z
            HALT

TEST_2C     MOVE    DATA1, R0       ; Prepare data before INT
            MOVE    0x3456, @R0
            MOVE    0x1111, R1
            MOVE    ISR2, R8
            INT     R8              ; One-word instruction
            ADD     R1, @R0         ; Assumes R0 and R1 are untouched
            CMP     0x4567, @R0
            RBRA    TEST_3, Z
            HALT                    ; Error

ISR2        CMP     STACK_TOP, R13  ; Verify stack pointer unchanged
            RBRA    FAIL2, !Z
            RTI
FAIL2       HALT

;
; Test 3 : Set flags, INT, have the ISR deliberately clobber them, RTI. Checks
; R14 is restored bit for bit.
;

TEST_3      MOVE    DATA, R8        ; Prepare data before INT
            MOVE    0x3000, @R8
            MOVE    0xFFFF, R14
            INT     ISR3
            CMP     0xFFFF, R14
            RBRA    TEST_3A, Z
            HALT

TEST_3A     MOVE    0x0000, R14
            INT     ISR3
            CMP     0x0001, R14     ; Bit 0 is always set
            RBRA    TEST_3B, Z
            HALT

TEST_3B     MOVE    0x3002, R9      ; Expected value (two entries into ISR3)
            CMP     R9, @R8         ; Assumes R8 is untouched
            RBRA    TEST_7, Z
            HALT

ISR3        MOVE    DATA, R2
            ADD     0x0001, @R2
            NOT     R14, R14        ; Clobber the Status Register
            RTI
            HALT

;
; Test 7 : INT immediately after INCRB, with an ISR that changes the bank.
; Checks the bank-change flush still holds across an interrupt.
;

TEST_7      MOVE    DATA, R8        ; Prepare data before INT
            MOVE    0x7000, @R8
            MOVE    0x0000, R14     ; Prepare register bank
            MOVE    0xFF00, R8      ; Mask for register bank
            MOVE    FAIL7, R0       ; Bank 0 decoy: a wrong-bank read halts
            INCRB
            MOVE    ISR7, R0        ; Prepare banked register
            DECRB
            NOP                     ; Fill instruction pipeline
            NOP                     ; with non-banked registers
            NOP
            INCRB
            INT     R0              ; Use banked register
            AND     R14, R8         ; Isolate register bank
            CMP     0x0100, R8      ; Verify register bank unaltered by the ISR
            RBRA    TEST_7A, Z
            HALT

TEST_7A     MOVE    DATA, R8
            MOVE    0x7001, R9      ; Expected value
            CMP     R9, @R8
            RBRA    EXIT, Z
            HALT

ISR7        MOVE    R14, R1         ; Copy Status Register
            AND     0xFF00, R1      ; Isolate register bank
            CMP     0x0100, R1      ; Verify register bank increased
            RBRA    FAIL7, !Z
            MOVE    DATA, R2
            ADD     0x0001, @R2
            NOT     R14, R14        ; Clobber register bank
            RTI
FAIL7       HALT


EXIT        MOVE    0x0000, R0      ; Copy three NOPs to placeholder
            MOVE    L_NOP, R1
            MOVE    @R1, @R0++
            MOVE    @R1, @R0++
            MOVE    @R1, @R0++

SUCCESS     MOVE    0x7FFF, R0
            MOVE    0x0000, @R0
            HALT

L_NOP       NOP
L_HALT      HALT

DATA        .DW     0xDEAD          ; Pre-initialized to arbitrary values
DATA1       .DW     0xDEAD
DATA2       .DW     0xDEAD          ; Must stay immediately after DATA1, see TEST_1D

STACK_BOT   .BLOCK  5
STACK_TOP   .DW     0x0000

