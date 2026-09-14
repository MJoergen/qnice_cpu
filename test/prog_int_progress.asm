; This program tests that the interrupted program makes progress between two
; service routines: after an RTI, the instruction at the return address retires
; before another hardware interrupt request is accepted, even one that was
; pending all along. It is written specifically for the Interrupt Generator
; defined in test/interrupt.vhd.
;
; This is guarantee 6 of the contract in src/interrupt/README.md, and a
; deliberate divergence from upstream's CPU, which takes a pending request
; before it latches the next instruction and so runs nothing of the interrupted
; program at all. A device that requests again as soon as it is serviced would
; starve that program there. See doc/interrupts.md, "Programmer's model".
;
; The request is raised from inside a software ISR, for the reason
; test/prog_int_halt.asm gives: a countdown alone cannot place a request at a
; particular boundary independently of the memory latencies, but a request
; raised inside a service routine is held off until its RTI, whatever they are.
; The ISR waits until the request is actually asserted, so it is pending when
; the RTI retires.
;
; The RTI returns onto a run of "ADD R7, R6" with R7 = 1, so R6 counts the
; instructions of the main program that retire. The hardware ISR records R6 on
; entry, and the main program checks the record afterwards:
;
;   * 0 means no instruction ran between the two routines -- what upstream's
;     CPU does, and a failure here (0x1B04);
;   * 1 is this CPU: exactly one, the instruction at the return address;
;   * anything more means the request was not taken at the first boundary it
;     could have been (0x1B05).
;
; Test prog_int_halt is the special case of the same rule where the return
; address holds a HALT.
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
; "make run TEST=prog_int_progress"


            .ORG    0x0000

            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    INT_ACCEPT, R3
            MOVE    PROGRESS, R5
            MOVE    0xFFFF, @R5             ; Sentinel: the hardware ISR has not run
            MOVE    ISR_HW, @R0             ; Set ISR address for the hardware interrupt
            MOVE    0x0001, R7
            MOVE    0x0000, R6
            MOVE    ISR_SW, R4
            INT     R4                      ; The RTI in ISR_SW returns to the run below
            ADD     R7, R6                  ; Must run before the pending request is taken
            ADD     R7, R6
            ADD     R7, R6
            ADD     R7, R6

            CMP     0x0001, @R3             ; The hardware request was accepted once
            RBRA    ERR_ACCEPT, !Z
            CMP     0x0000, @R5             ; At least one instruction ran in between
            RBRA    ERR_STARVED, Z
            CMP     0x0001, @R5             ; And exactly one: taken at the first boundary
            RBRA    ERR_LATE, !Z

            MOVE    0x7FFF, R0              ; Test status word (see test/README.md)
            MOVE    0x0000, @R0             ; 0 = pass
            HALT

; Software ISR. Hardware interrupts are held off for as long as it runs.
ISR_SW      MOVE    0x0001, @R1             ; Request interrupt in one clock cycle
            MOVE    0x0100, R8              ; Bound on the wait below
L_WAIT      CMP     0x0001, @R2             ; Wait until the request line is asserted.
            RBRA    L_WAIT_OK, Z            ; The bound is not for this CPU, where it takes
            SUB     0x0001, R8              ; a few cycles: it is for upstream's emulator,
            RBRA    L_WAIT, !Z              ; which has no Interrupt Generator and would
            RBRA    ERR_NO_REQ, 1           ; otherwise poll forever. See test/crosscheck.py.
L_WAIT_OK   CMP     0x0000, @R3             ; Verify the request was not accepted inside the ISR
            RBRA    ERR_NESTED, !Z
            RTI                             ; The request is pending as this retires

; Hardware ISR: record how many instructions of the main program ran.
ISR_HW      MOVE    R6, @R5
            RTI

ERR_NO_REQ  MOVE    0x7FFF, R0
            MOVE    0x1B01, @R0             ; Indicate failure: the request never asserted
            HALT

ERR_NESTED  MOVE    0x7FFF, R0
            MOVE    0x1B02, @R0             ; Indicate failure: accepted inside the ISR
            HALT

ERR_ACCEPT  MOVE    0x7FFF, R0
            MOVE    0x1B03, @R0             ; Indicate failure: not accepted exactly once
            HALT

ERR_STARVED MOVE    0x7FFF, R0
            MOVE    0x1B04, @R0             ; Indicate failure: nothing ran between the routines
            HALT

ERR_LATE    MOVE    0x7FFF, R0
            MOVE    0x1B05, @R0             ; Indicate failure: the request was taken late
            HALT

PROGRESS    .DW     0x0000                  ; R6 as the hardware ISR found it
