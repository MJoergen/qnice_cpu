      .ORG 0x0000
      MOVE L_1, R7
      ABRA L_START, 1

      HALT
      HALT
      HALT
      HALT
      HALT
      HALT
      HALT
      HALT
      HALT
      HALT
      HALT
      HALT

L_START
      ADD @R7++, @R7++
      MOVE 0x1234, R8
      MOVE 0x2345, R9

      HALT
      HALT
      HALT
      HALT
      HALT
      HALT

L_1   .DW 0x4321
L_2   .DW 0x5432
L_3   .DW 0x0000

