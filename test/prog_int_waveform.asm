; This program exists to generate the interrupt timing diagram in
; src/interrupt/timing.tex, as test/prog_waveform.asm does for
; src/cpu_main/timing.tex. It is written for the Interrupt Generator defined in
; test/interrupt.vhd.
;
; The diagram follows two hardware interrupts. The first is requested from the
; main program and lands in a run of padding. Its service routine requests the
; second, which is therefore refused at every instruction boundary inside that
; routine, including at the RTI, and is taken at the boundary after the first
; instruction back at the return address.
;
; CAUTION: changing this file (or anything that shifts the addresses in it, or
; the number of cycles an instruction takes) invalidates the cycle numbers and
; addresses in src/interrupt/timing.tex and src/interrupt/README.md. Re-read them
; off a fresh simulation and run "make diagrams".
;
; The padding is "MOVE R2, R2": one word, one micro-op, and no memory access, so
; it retires one instruction per cycle once the pipeline is full and does not
; perturb its neighbours.
;
; ISR1 requests the second interrupt with "MOVE R5, @R1" rather than
; "MOVE 0x0001, @R1", with R5 loaded in the main program. The immediate would
; cost a word and a cycle, and the diagram is wide enough without it.
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

; The test may be run separately by the following command:
; "make run TEST=prog_int_waveform"


            .ORG    0x0000

            MOVE    INT_ADDR, R0
            MOVE    INT_COUNT, R1
            MOVE    0x0000, R3              ; Counts entries into ISR1
            MOVE    0x0000, R4              ; Counts entries into ISR2
            MOVE    0x0001, R5              ; Countdown for the second request
            MOVE    ISR1, @R0               ; ISR address of the first request
            MOVE    0x0001, @R1             ; First request, one idle cycle from now
            MOVE    R2, R2                  ; Padding: the first request lands in here
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2
            MOVE    R2, R2

            CMP     0x0001, R3              ; Each service routine ran exactly once
            RBRA    E1, !Z
            CMP     0x0001, R4
            RBRA    E2, !Z

            MOVE    0x7FFF, R0              ; Test status word (see test/README.md)
            MOVE    0x0000, @R0             ; 0 = pass
E1          HALT
E2          HALT

ISR1        MOVE    ISR2, @R0               ; ISR address of the second request
            MOVE    R5, @R1                 ; Second request, inside this routine
            ADD     0x0001, R3              ; The second request is pending, and
            MOVE    R2, R2                  ; refused, at these boundaries
            RTI                             ; ...and at this one

ISR2        ADD     0x0001, R4
            RTI
