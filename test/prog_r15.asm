; Tests for R15 (the Program Counter) used as an ordinary ALU operand.
;
; The reference implementation keeps a single PC register: qnice.c updates it
; immediately after fetching the instruction word, and both read_source_operand
; and the destination read go through the same read_register(PC). So reading R15
; must give the address of the next word to be fetched, and the source and
; destination paths must agree with each other.
;
; In this implementation the Program Counter lives in the FETCH stage, and the
; register file's R15 copy is only written when an instruction targets R15.
; Reading R15 as an operand therefore has to be special-cased in PREPARE.
;
; Every failed sub-test branches to its own HALT. Success falls through to EXIT.

                .ORG 0x0000

; ---------------------------------------------------------------
; T1: the source and destination read paths for R15 must agree
; ---------------------------------------------------------------
                MOVE    0x1234, R0      ; a few sequential instructions first,
                MOVE    0x2345, R1      ; so the register file's R15 copy goes
                MOVE    0x3456, R2      ; stale if it is being used

                CMP     R15, R15
                ABRA    T2, Z
E_T1            HALT

; ---------------------------------------------------------------
; T2: R15 as a SOURCE reads the address of the next instruction
; ---------------------------------------------------------------
T2              MOVE    R15, R0         ; one word, so R0 = address of L2
L2              CMP     R0, L2
                ABRA    T3, Z
E_T2            HALT

; ---------------------------------------------------------------
; T3: R15 as a DESTINATION supports a PC-relative jump.
;     "ADD 0x0002, R15" occupies two words, so R15 reads as the address of
;     the next instruction; adding 2 therefore skips the two words below.
; ---------------------------------------------------------------
T3              ADD     0x0002, R15
E_T3            HALT
                HALT

; ---------------------------------------------------------------
; T4: @R15 (PC-relative memory read) must use the same PC.
;     Self-referential and control-flow neutral: read the next word both via
;     @R15 and via an ordinary register, then compare.
; ---------------------------------------------------------------
                MOVE    @R15, R4        ; PC-relative read of the word at T4
T4              MOVE    T4, R5          ; (this instruction IS that word)
                MOVE    @R5, R6         ; same word, via an ordinary register
                CMP     R4, R6
                ABRA    EXIT, Z
E_T4            HALT

; ---------------------------------------------------------------
EXIT            MOVE    OK, R8
                MOVE    0x1FFF, R0      ; Test status word (see test/README.md)
                MOVE    0x0000, @R0     ; 0 = pass
                HALT

OK              .ASCII_W "OK\n"
