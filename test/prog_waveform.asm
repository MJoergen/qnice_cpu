; This program exists to generate the pipeline timing diagram in
; src/cpu_main/README.md#Waveforms. That diagram follows the single instruction
; "ADD @R0++, @R0++" at address 0x0006, and quotes concrete addresses, register
; values and cycle numbers taken from a simulation run of this program. The
; blocks of "MOVE R1, R1" around it are padding, so that the ADD is entered and
; left with a full pipeline and is not perturbed by its neighbours.
;
; CAUTION: changing this file (or anything that shifts the addresses in it)
; invalidates the numbers in that README section and in src/cpu_main/timing.tex.
; Re-read them off a fresh simulation and run "make timing".
;
; The tail of the program checks that the ADD did what the diagram claims: that
; R0 ends up at L2 after the two post-increments, and that L3 holds the sum
; 0x1234 + 0x2345 = 0x3579.

      .ORG 0x0000

      MOVE L1, R0
      MOVE R1, R1
      MOVE R1, R1
      MOVE R1, R1
      MOVE R1, R1
      ADD  @R0++, @R0++
      MOVE R1, R1
      MOVE R1, R1
      MOVE R1, R1
      MOVE R1, R1
      CMP  L2, R0
      ABRA E1, !Z
      MOVE L3, R0
      CMP  0x3579, @R0
      ABRA E2, !Z

      MOVE 0x1FFF, R0   ; Test status word (see test/README.md)
      MOVE 0x0000, @R0  ; 0 = pass
E1    HALT
E2    HALT

L1    .DW 0x1234
L3    .DW 0x2345
L2    .DW 0x0000


