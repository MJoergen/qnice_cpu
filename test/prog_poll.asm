; This program exists to generate the loop timing diagram in
; doc/README.md#A-polling-loop-cycle-by-cycle. It is the shape a device driver
; spins in while it waits for a status bit: read the device, mask off the bit,
; branch back if it is still clear.
;
; CAUTION: THIS PROGRAM NEVER HALTS, AND IS THEREFORE DELIBERATELY NOT IN THE
; "TESTS" LIST IN THE TOP-LEVEL MAKEFILE. A real device would eventually set
; bit 1 and release the loop, but the testbench has no device: DEV below is an
; ordinary memory word holding zero, and nothing in the loop writes to memory,
; so Z stays set and the branch is always taken. "make check TEST=prog_poll"
; would simply run until the G_TIMEOUT watchdog in test/tb_cpu.vhd fails it.
;
; Run it with an explicit stop time instead, and read the values off the wave:
;
;    make build
;    ghdl -r --std=08 tb_cpu -gG_ROM=test/prog_poll.rom \
;         -gG_REGISTER_BANK_WIDTH=8 --wave=poll.ghw --stop-time=500ns
;
; The loop has settled by 350 ns, and each iteration takes exactly ten clock
; cycles, so cycle 45 is bit-for-bit identical to cycle 35. That window is what
; doc/loop_timing.tex draws; changing this file (or anything that shifts the
; addresses in it) invalidates the diagram.

      .ORG 0x0000

      MOVE  DEV, R0     ; The "device" the loop polls
      MOVE  R1, R1      ; Padding, so the loop is entered with a full pipeline
      MOVE  R1, R1
      MOVE  R1, R1

LOOP  MOVE  @R0, R2     ; 0x0005
      AND   0x0002, R2  ; 0x0006, 0x0007
      RBRA  LOOP, Z     ; 0x0008, 0x0009

DEV   .DW   0x0000      ; 0x000A. Bit 1 never becomes set, so LOOP never exits.
