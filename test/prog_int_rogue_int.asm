; This program tests that a rogue INT -- one executed inside an interrupt
; service routine -- halts the CPU. Interrupts do not nest. Neither the ISA
; document nor int-device.md says what a rogue INT does; upstream's CPU and
; emulator both halt, and doc/interrupts.md records following them as a
; decision. RTI outside a service routine is the other rogue case, and
; test/prog_int_rogue_rti.asm tests it: a program can only halt once.
;
; The verdict does NOT rest on the status word alone. A halting INT leaves the
; CPU no way to write anything afterwards, so the passing status word is written
; just BEFORE the rogue INT, and only the first write to it counts. That makes
; the code after the INT responsible for failing a CPU that does not halt, and
; it cannot do so by writing a failure code and halting -- that run would pass.
; So it never halts at all:
;
;   * An INT that is a no-op falls through to L_NO_HALT and spins there until
;     the watchdog in test/tb_cpu.vhd fails the run.
;   * An INT that nests enters NESTED and spins in the same place.
;   * An INT that pulses halt_o but lets the instructions behind it retire is
;     failed by test/test_monitor.vhd, which fails any run in which an
;     instruction retires after the CPU has halted.
;
; The rogue INT reads its address from memory, "INT @R3", rather than from a
; register. That makes it an instruction of two micro-ops, a memory read and
; then the one that retires, so the decision to halt is taken on the second one
; and not on the first. It is deliberately not "INT @R3++": the post-increment
; is a register write of its own, whether it lands before the CPU halts is not
; what this program tests, and the two upstream references need not agree on
; it, so R3 could differ in "make crosscheck" for a reason that has nothing to
; do with halting.
;
; The writes of 0x1A02 and 0x1A03 are diagnostic only: they show up in the
; writes log and in a DEBUG=true run, but cannot change the verdict.

; The test may be run separately by the following command:
; "make run TEST=prog_int_rogue_int"


            .ORG    0x0000

            MOVE    0x7FFF, R0
            MOVE    ISR, R1
            MOVE    NESTED_PTR, R3
            INT     R1              ; Not rogue: enters ISR, which never returns

            MOVE    0x1A01, @R0     ; Indicate failure: the INT above did not
            HALT                    ; enter the service routine


ISR         MOVE    0x0000, @R0     ; Indicate success, provided the CPU halts
                                    ; on the INT below
            INT     @R3             ; ROGUE: already in a service routine

            ; Only a CPU that failed to halt gets here.
            MOVE    0x1A02, @R0     ; Diagnostic only: a no-op INT
            RBRA    L_NO_HALT, 1

NESTED      MOVE    0x1A03, @R0     ; Diagnostic only: an INT that nested
L_NO_HALT   RBRA    L_NO_HALT, 1    ; Never HALT, see the header


NESTED_PTR  .DW     NESTED
