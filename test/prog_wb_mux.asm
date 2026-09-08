; Regression test for test/wb_mux.vhd, the data-bus multiplexer.
;
; The data bus is split at 0x8000: RAM below, EAE above. The two slaves have
; different latencies, and either can be slowed further from the Makefile
; (A_ACK_DELAY / B_ACK_DELAY and the matching stall delays). A pipelined
; WISHBONE ACK is a bare pulse, so the master can only pair responses with
; requests by position -- if the mux let a fast slave answer ahead of a slow
; one, MEMORY would route read data to the wrong operand.
;
; The instruction that catches this is one whose two operands live on opposite
; sides of the split, because DECODE issues those two reads on consecutive
; cycles and both are then in flight at once. SUB is used rather than ADD
; precisely because it does not commute: crossed routing does not merely give
; the same answer by luck, it flips the sign.
;
; At the default delays both slaves answer in one cycle and nothing can
; reorder, so this program is only a sanity check under "make test". It earns
; its keep under "make test_slow", which sets B_ACK_DELAY=3 and so makes the
; RAM strictly slower than the EAE. Before wb_mux.vhd existed, S1 below failed
; at every B_ACK_DELAY above 1 -- hanging at 2 and 3, computing the wrong
; answer from 4 up.

EAE_REG_OPERAND_0    .EQU    0xFF18             ; upper half: the EAE
EAE_REG_OPERAND_1    .EQU    0xFF19

SCRATCH              .EQU    0x1000             ; lower half: the RAM

                MOVE    SCRATCH, R7
                MOVE    EAE_REG_OPERAND_0, R9

; ----------------------------------------------------------------------------
; S1: SRC in the RAM, DST in the EAE. This is the ordering that breaks without
; the mux, because the slower slave is the one asked first.
; ----------------------------------------------------------------------------
S1              MOVE    0x0005, @R7
                MOVE    0x0003, @R9
                SUB     @R7, @R9                ; EAE = 3 - 5
                MOVE    @R9, R1
                CMP     0xFFFE, R1              ; crossed routing would give 2
                RBRA    E_S1, !Z

; ----------------------------------------------------------------------------
; S2: the same instruction with the operands the other way round, so the
; request to the upper half is the older of the two.
; ----------------------------------------------------------------------------
S2              MOVE    0x0004, @R7
                MOVE    0x0009, @R9
                SUB     @R9, @R7                ; RAM = 4 - 9
                MOVE    @R7, R1
                CMP     0xFFFB, R1              ; crossed routing would give 5
                RBRA    E_S2, !Z

; ----------------------------------------------------------------------------
; S3: back-to-back mixed instructions, to keep requests to both slaves in
; flight across several cycles rather than just one instruction's worth.
; ----------------------------------------------------------------------------
S3              MOVE    0x0064, @R7
                MOVE    0x0007, @R9
                SUB     @R7, @R9                ; EAE = 7 - 100 = -93
                SUB     @R9, @R7                ; RAM = 100 - (-93) = 193
                MOVE    @R9, R1
                MOVE    @R7, R2
                CMP     0xFFA3, R1              ; -93
                RBRA    E_S3, !Z
                CMP     0x00C1, R2              ; 193
                RBRA    E_S3, !Z

L_END           MOVE    0x7FFF, R0              ; Test status word
                MOVE    0x0000, @R0             ; 0 = pass
                HALT

; Every failure path halts without writing the status word, which is what
; test_monitor.vhd turns into a failing exit code. See test/README.md.
E_S1            HALT
E_S2            HALT
E_S3            HALT
