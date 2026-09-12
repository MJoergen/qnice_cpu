; This program tests hardware interrupts are not serviced after a HALT.
; It is written specifically for the Interrupt Generator defined in
; test/interrupt.vhd.
;
; Register Map for Interrupt Generator (copied verbatim from test/interrupt.vhd):
; 0xBF00 : Countdown number of idle clock cycles until interrupt is asserted. After count-down,
;          interrupt line remains asserted until accepted, and is then released. Counter
;          reads back as zero.
; 0xBF01 : Address of interrupt service routine. Initialized to zero, which happens to be
;          the same as the CPU reset address.
; 0xBF02 : Bit 0 indicates whether interrupt is currently asserted (can only ever read
;          non-zero when inside an ISR).
; 0xBF03 : Number of accepted interrupt requests

INT_COUNT            .EQU    0xBF00
INT_ADDR             .EQU    0xBF01
INT_STAT             .EQU    0xBF02
INT_ACCEPT           .EQU    0xBF03

; The test may be run separately by the following command:
; "make run TEST=prog_int_halt"


            .ORG    0x0000

            MOVE    0x7FFF, R0
            MOVE    0x0000, @R0
; Fire an interrupt after the halt
            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    ISR_HALT, @R0           ; Set ISR address
            MOVE    0x0001, @R1             ; Request interrupt in a few clock cycles
            HALT                            ; The interrupt should NOT be accepted.
            HALT
ISR_HALT    MOVE    0x7FFF, R0
            MOVE    0x1802, @R0             ; Indicate failure
            HALT

