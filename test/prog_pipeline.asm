      .ORG 0x0000
      MOVE L_1, R0
      ABRA L_START, 1

      .ORG 0x0010
L_START
      ADD @R0++, @R0++
      MOVE 0x1234, R8
      MOVE 0x2345, R9
      HALT

      .ORG 0x1000
L_1   .DW 0x4321
L_2   .DW 0x5432
L_3   .DW 0x0000

