; Regression test for the EAE stall bug fixed in bd0b7da.
;
; The EAE arms a G_DELAY-cycle read stall after every write to one of its
; registers, to cover the settling time of its combinational arithmetic.
; Before the fix that stall reached the CPU two ways it should not have: it was
; not qualified by the chip select of the EAE itself, and system.vhd ORed it onto the
; shared data-bus stall line rather than selecting the addressed slave.  So an
; EAE write held off a following access aimed at the RAM as well.
;
; That is fatal rather than merely slow.  wb_dp_mem hardwires its own stall low
; and acks on "cyc and stb and not stall", so while the CPU held the request
; waiting for the shared stall to drop, the RAM re-accepted that one request
; once per stalled cycle and acked each time.  MEMORY matches each ack against
; the head of its op-type FIFO (see src/memory/README.md), so the surplus acks
; popped entries belonging to later requests, the FIFO desynced, and the CPU
; wedged until the tb_cpu watchdog fired.
;
; S1 and S2 below therefore issue RAM traffic inside the EAE stall window.
; They check returned values and not just liveness, because a desynced FIFO
; misroutes read data before it runs out of entries to pop.  S3 covers the
; opposite direction, so that deleting the stall does not pass either.
;
; Fault injection confirms what this pins down.  Reverting both halves of
; bd0b7da (the chip-select gate in eae.vhd and the stall mux in system.vhd)
; hangs the run; replacing the stall with a constant '0' fails at E_S3.
; Reverting either half ALONE still passes, because each one masks the bug on
; its own -- the two are defence in depth, and no test at this level can
; separate them.

EAE_REG_OPERAND_0    .EQU    0xFF18
EAE_REG_OPERAND_1    .EQU    0xFF19
EAE_REG_RESULT_LO    .EQU    0xFF1A
EAE_REG_RESULT_HI    .EQU    0xFF1B
EAE_REG_CSR          .EQU    0xFF1C             ; Command and Status Register

EAE_CSR_MULU         .EQU    0x0000             ; unsigned multiply

; A RAM scratch area, deliberately far from the code so that storing to it
; cannot trigger a self-modifying-code flush (write.vhd flushes on a store
; within 32 words after the current instruction).
SCRATCH              .EQU    0x1000

                MOVE    SCRATCH, R7
                MOVE    0x1234, @R7++
                MOVE    0x5678, @R7++
                MOVE    0x9ABC, @R7++
                MOVE    0xDEF0, @R7

; ----------------------------------------------------------------------------
; S1: four RAM reads issued immediately after an EAE write.  The address
; registers are set up first so that the first read follows the EAE write with
; no instruction in between, putting it inside the stall window.
; ----------------------------------------------------------------------------
S1              MOVE    SCRATCH, R7
                MOVE    EAE_REG_OPERAND_0, R9
                MOVE    0x0003, @R9             ; arms the EAE stall
                MOVE    @R7++, R0               ; RAM read inside the window
                MOVE    @R7++, R1
                MOVE    @R7++, R2
                MOVE    @R7, R3
                CMP     0x1234, R0
                RBRA    E_S1, !Z
                CMP     0x5678, R1
                RBRA    E_S1, !Z
                CMP     0x9ABC, R2
                RBRA    E_S1, !Z
                CMP     0xDEF0, R3
                RBRA    E_S1, !Z

; ----------------------------------------------------------------------------
; S2: RAM reads interleaved between an EAE command write and the read of its
; result, so that acks from both slaves are outstanding across the stall
; window.  This pins ack attribution: 3 * 5 must still come back as 15, and the
; RAM words must still come back intact, with the two streams not crossed.
; ----------------------------------------------------------------------------
S2              MOVE    SCRATCH, R7
                MOVE    EAE_REG_OPERAND_0, R9
                MOVE    EAE_REG_RESULT_LO, R10
                MOVE    EAE_REG_CSR, R11
                MOVE    0x0003, @R9++           ; operand 0
                MOVE    0x0005, @R9             ; operand 1
                MOVE    EAE_CSR_MULU, @R11      ; command; arms the stall
                MOVE    @R7++, R0               ; RAM read inside the window
                MOVE    @R7, R1
                MOVE    @R10++, R2              ; EAE result lo
                MOVE    @R10, R3                ; EAE result hi
                CMP     0x1234, R0
                RBRA    E_S2, !Z
                CMP     0x5678, R1
                RBRA    E_S2, !Z
                CMP     0x000F, R2              ; 3 * 5
                RBRA    E_S2, !Z
                CMP     0x0000, R3
                RBRA    E_S2, !Z

; ----------------------------------------------------------------------------
; S3: the stall doing its actual job.  S1 and S2 would both still pass if the
; stall were deleted outright rather than qualified, so pin the other
; direction too: overwrite the operands and read the result back with no
; instruction in between.  The EAE recomputes one cycle after the operand
; lands, so without the stall this read is accepted too early and returns the
; previous result -- which S2 left at 15, distinct from the 63 expected here.
; ----------------------------------------------------------------------------
S3              MOVE    EAE_REG_OPERAND_0, R9
                MOVE    EAE_REG_RESULT_LO, R10
                MOVE    0x0007, @R9++           ; operand 0
                MOVE    0x0009, @R9             ; operand 1; arms the stall
                MOVE    @R10, R2                ; read back with no delay
                CMP     0x003F, R2              ; 7 * 9, not the 15 left by S2
                RBRA    E_S3, !Z

L_END           MOVE    0x7FFF, R0              ; Test status word
                MOVE    0x0000, @R0             ; 0 = pass
                HALT

; Every failure path halts without writing the status word, which is what
; test_monitor.vhd turns into a failing exit code.  See test/README.md.
E_S1            HALT
E_S2            HALT
E_S3            HALT
