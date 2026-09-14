; This program tests hardware interrupts are not serviced after a HALT.
; It is written specifically for the Interrupt Generator defined in
; test/interrupt.vhd.
;
; A HALT that has retired stops the CPU, so an interrupt request that is pending
; when the HALT retires must never be accepted: the next instruction boundary
; after the HALT is never reached.
;
; The request has to be pending exactly when the HALT retires, and a countdown
; alone cannot put it there reliably. The window between the instruction before
; the HALT retiring and the HALT retiring is about one clock cycle, and where it
; falls depends on the memory latency, so an earlier version of this program --
; arm with a countdown of one, then HALT -- landed after the HALT under
; "make test" and on it under "make test_slow". So the request is raised from
; inside a software ISR instead, where it cannot be accepted, and the ISR
; returns straight onto the HALT. The request is then already pending when the
; RTI retires, is held off by the ISR until then, and the very next instruction
; to retire is the HALT, whatever the latencies.
;
; The verdict does NOT rest on the status word. The word is written, as 0x0000,
; before the HALT, and only the first write to it counts, so the failure code
; ISR_HALT writes is diagnostic only. What fails the run is test/test_monitor.vhd
; seeing any instruction retire after the HALT.
;
; Upstream's CPU answers this differently, and legitimately: it takes a pending
; interrupt before it latches the next instruction, so it enters ISR_HALT
; straight after the RTI and never executes the HALT. See test/CLAUDE.md.
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

            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    INT_STAT, R2
            MOVE    INT_ACCEPT, R3
            MOVE    ISR_HALT, @R0           ; Set ISR address for the hardware interrupt
            MOVE    ISR_SW, R4
            INT     R4                      ; The RTI in ISR_SW returns to the HALT below
            HALT                            ; A pending interrupt must NOT be accepted here

; Software ISR. Hardware interrupts are held off for as long as it runs.
ISR_SW      MOVE    0x0001, @R1             ; Request interrupt in one clock cycle
            MOVE    0x0100, R6              ; Bound on the wait below
L_WAIT      CMP     0x0001, @R2             ; Wait until the request line is asserted.
            RBRA    L_WAIT_OK, Z            ; The bound is not for this CPU, where it takes
            SUB     0x0001, R6              ; a few cycles: it is for upstream's emulator,
            RBRA    L_WAIT, !Z              ; which has no Interrupt Generator and would
            RBRA    ERR_NO_REQ, 1           ; otherwise poll forever. See test/crosscheck.py.
L_WAIT_OK   CMP     0x0000, @R3             ; Verify the request was not accepted inside the ISR
            RBRA    ERR_ACCEPT, !Z
            MOVE    0x7FFF, R5
            MOVE    0x0000, @R5             ; Indicate success, provided nothing runs after the HALT
            RTI

ISR_HALT    MOVE    0x7FFF, R0
            MOVE    0x1802, @R0             ; Indicate failure (diagnostic only, see above)
            HALT

ERR_ACCEPT  MOVE    0x7FFF, R0
            MOVE    0x1801, @R0             ; Indicate failure
            HALT

ERR_NO_REQ  MOVE    0x7FFF, R0
            MOVE    0x1803, @R0             ; Indicate failure: the request never asserted
            HALT

