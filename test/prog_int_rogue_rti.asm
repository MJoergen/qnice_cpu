; This program tests that a rogue RTI -- one executed outside an interrupt
; service routine -- halts the CPU. Neither the ISA document nor int-device.md
; says what a rogue RTI does; upstream's CPU and emulator both halt, and
; doc/interrupts.md records following them as a decision. INT inside a service
; routine is the other rogue case, and test/prog_int_rogue_int.asm tests it: a
; program can only halt once.
;
; The verdict does NOT rest on the status word alone. A halting RTI leaves the
; CPU no way to write anything afterwards, so the passing status word is written
; just BEFORE the rogue RTI, and only the first write to it counts. That makes
; the code after the RTI responsible for failing a CPU that does not halt, and
; it cannot do so by writing a failure code and halting -- that run would pass.
; So it never halts at all:
;
;   * An RTI that is a no-op falls through to L_NO_HALT and spins there until
;     the watchdog in test/tb_cpu.vhd fails the run.
;   * An RTI that pulses halt_o but lets the instructions behind it retire is
;     failed by test/test_monitor.vhd, which fails any run in which an
;     instruction retires after the CPU has halted.
;   * An RTI that returns anyway -- jumping to the saved return address, which
;     has no reset -- is made to land somewhere definite by a genuine INT/RTI
;     round trip first. It resumes at L_RET and loops back onto the rogue RTI
;     forever, never halting.
;
; The writes of 0x1901 are diagnostic only: they show up in the writes log and
; in a DEBUG=true run, but cannot change the verdict.

; The test may be run separately by the following command:
; "make run TEST=prog_int_rogue_rti"


            .ORG    0x0000

            MOVE    0x7FFF, R0
            MOVE    0x0000, R2      ; Counts service routine entries
            MOVE    ISR, R1
            INT     R1              ; A genuine round trip, so that the saved
                                    ; return address is L_RET, see the header
L_RET       CMP     0x0001, R2      ; The service routine ran exactly once
            RBRA    ERR_ISR, !Z

            MOVE    0x0000, @R0     ; Indicate success, provided the CPU halts
                                    ; on the RTI below
            RTI                     ; ROGUE: not in a service routine

            ; Only a CPU that failed to halt gets here.
            MOVE    0x1901, @R0     ; Diagnostic only, see the header
L_NO_HALT   RBRA    L_NO_HALT, 1    ; Never HALT, see the header


ISR         ADD     0x0001, R2
            RTI                     ; Not rogue: returns to L_RET


ERR_ISR     MOVE    0x1902, @R0     ; Indicate failure: the INT did not run the
            HALT                    ; service routine exactly once
