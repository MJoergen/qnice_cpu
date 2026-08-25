; Data-hazard tests: back-to-back dependent instructions.
;
; The sub-tests that check a Status Register bit first write R14 directly with
; that bit CLEARED, so the bit the test then looks for can only have come from
; the producing instruction. Without that, an SR path that never updated at all
; would pass: every sub-test is entered through a taken "ABRA <label>, Z", so
; Z is already 1 on arrival.
;
; Every failed sub-test branches to its own HALT. Success falls through to EXIT.

; Status register (bits 7 - 0) of R14:  - - V N Z C X 1
#define ST______ 0x0001

                .ORG 0x0000

; ---------------------------------------------------------------
; H1: register written, then read by the very next instruction
; ---------------------------------------------------------------
                MOVE    0x1234, R0
                MOVE    R0, R1
                CMP     R1, 0x1234
                ABRA    H2, Z
E_H1            HALT

; ---------------------------------------------------------------
; H2: register written, then used as a memory pointer immediately
; ---------------------------------------------------------------
H2              MOVE    D_A, R0
                MOVE    @R0, R1
                CMP     R1, 0xAAAA
                ABRA    H3, Z
E_H2            HALT

; ---------------------------------------------------------------
; H3: register written, then used as BOTH ALU operands
; ---------------------------------------------------------------
H3              MOVE    0x1111, R0
                ADD     R0, R0
                CMP     R0, 0x2222
                ABRA    H4, Z
E_H3            HALT

; ---------------------------------------------------------------
; H4: dependency chained through four consecutive instructions
; ---------------------------------------------------------------
H4              MOVE    0x0007, R0
                MOVE    R0, R1
                MOVE    R1, R2
                MOVE    R2, R3
                CMP     R3, 0x0007
                ABRA    H5, Z
E_H4            HALT

; ---------------------------------------------------------------
; H5: SR written as an ORDINARY register, read back by the next instruction,
;     and the Z it produces consumed by the one after that. The value 0x0005
;     has Z clear, so the ABRA can only be taken on the CMP's own Z.
; ---------------------------------------------------------------
H5              MOVE    0x0005, R14
                CMP     R14, 0x0005
                ABRA    H6, Z
E_H5            HALT

; ---------------------------------------------------------------
; H6: SR written, then read as an ORDINARY register next instruction.
;     Z (bit 3) must be set by the ADD.
; ---------------------------------------------------------------
H6              MOVE    0x0000, R0
                MOVE    ST______, R14   ; Z = 0, the inverse of what ADD produces
                ADD     0x0000, R0      ; result 0, so Z = 1
                MOVE    R14, R9
                AND     0x0008, R9
                CMP     R9, 0x0008
                ABRA    H7, Z
E_H6            HALT

; ---------------------------------------------------------------
; H7: same, but the R14 read is the source of a MEMORY-destination
;     instruction, so DECODE stalls while the read is outstanding.
; ---------------------------------------------------------------
H7              MOVE    D_B, R5
                MOVE    0x0000, R0
                MOVE    ST______, R14   ; Z = 0, the inverse of what ADD produces
                ADD     0x0000, R0      ; result 0, so Z = 1
                MOVE    R14, @R5
                MOVE    @R5, R9
                AND     0x0008, R9
                CMP     R9, 0x0008
                ABRA    H8, Z
E_H7            HALT

; ---------------------------------------------------------------
; H8: same, but R14 is read by an instruction with a MEMORY source,
;     which takes two micro-operations
; ---------------------------------------------------------------
H8              MOVE    D_ZERO, R5
                MOVE    0x0000, R0
                MOVE    ST______, R14   ; Z = 0, the inverse of what ADD produces
                ADD     0x0000, R0      ; result 0, so Z = 1
                ADD     @R5, R14        ; adds 0, so SR is unchanged...
                MOVE    R14, R9
                AND     0x0008, R9
                CMP     R9, 0x0008
                ABRA    H9, Z
E_H8            HALT

; ---------------------------------------------------------------
; H9: post-increment pointer written and reused immediately
; ---------------------------------------------------------------
H9              MOVE    D_B, R1
                MOVE    0x1111, R0
                MOVE    R0, @R1++
                MOVE    0x2222, R0
                MOVE    R0, @R1++
                MOVE    D_B, R1
                MOVE    @R1++, R2
                MOVE    @R1++, R3
                CMP     R2, 0x1111
                ABRA    H9B, Z
E_H9            HALT
H9B             CMP     R3, 0x2222
                ABRA    H10, Z
E_H9B           HALT

; ---------------------------------------------------------------
; H10: stack pointer written, then used as a pre-decrement pointer
; ---------------------------------------------------------------
H10             MOVE    D_STACK, R13
                MOVE    0x4321, R0
                MOVE    R0, @--R13
                MOVE    @R13++, R1
                CMP     R1, 0x4321
                ABRA    EXIT, Z
E_H10           HALT

; ---------------------------------------------------------------
EXIT            MOVE    OK, R8
                MOVE    0x1FFF, R0      ; Test status word (see test/README.md)
                MOVE    0x0000, @R0     ; 0 = pass
                HALT

OK              .ASCII_W "OK\n"
D_A             .DW     0xAAAA
D_ZERO          .DW     0x0000
D_B             .DW     0x0000, 0x0000
D_STACK         .DW     0x0000, 0x0000
