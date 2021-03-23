      MOVE 0x0001, R0
      MOVE 0x0002, R0
      MOVE 0x0003, R0
      MOVE 0x0004, R0
      MOVE 0x0005, R0

      MOVE @R0, @R1
      MOVE @R1, @R2
      MOVE @R2, @R3
      MOVE @R3, @R4
      MOVE @R4, @R5

      MOVE 0x0001, R0
      MOVE @R0, @R1
      MOVE 0x0002, R0
      MOVE @R0, @R2
      MOVE 0x0003, R0
      MOVE @R0, @R3
      MOVE 0x0004, R0
      MOVE @R0, @R4
      MOVE 0x0005, R0
      MOVE @R0, @R5

      HALT
