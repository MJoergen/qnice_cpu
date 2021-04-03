      MOVE 0xFF28, R8   ; PRE
      MOVE 0xFF29, R9   ; CNT
      MOVE 0xFF2A, R10  ; INT

      MOVE L_ISR, @R10
      MOVE 2, @R8
      MOVE 2, @R9

      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0
      MOVE R0, R0

      HALT

L_ISR MOVE 0xFFFF, R14
      RTI
      HALT

