; ============================================================================
; ADAPTED FOR THIS REPOSITORY. Read this before trusting any number below.
;
; Every other program in test/ is hand-written to corner some specific part of
; the CPU, which makes the instruction mix of the suite unlike real code. This
; one exists to supply the opposite: a genuine program, doing genuine work, with
; the instruction sequence and the branch and memory access patterns that come
; out of compiling and hand-writing real QNICE software rather than out of the
; intent of a test author. It is the closest thing here to a representative
; workload, which is why the EAE (test/eae.vhd) was brought in alongside it --
; the multiply routine below is what a real QNICE monitor does, and it needs a
; multiplier device to do it.
;
; Both the EAE and this program are SIMULATION ONLY. The EAE instance in
; test/system.vhd sits inside a "pragma synthesis_off" block and is not part of
; any bitstream; see its header and CLAUDE.md.
;
; Three changes from the upstream QNICE-FPGA version:
;
; * The monitor ROM routines it called via SYSCALL are inlined below, between
;   the "INSERT MONITOR ROM CODE" markers, because there is no monitor here.
;   All character output (putc, puts, crlf, puthex) is simply gone, as is the
;   hardware cycle/instruction counter I/O, which this CPU does not implement --
;   test/test_monitor.vhd counts cycles instead, into the .stats files.
;
; * It ends by writing the test status word to 0x7FFF, so that it reports a
;   verdict like every other program here. See test/README.md.
;
; * X_STEP and Y_STEP were coarsened (0x000B -> 0x004B and 0x0013 -> 0x0053),
;   sampling roughly an 11 x 7 grid instead of 70 x 41, so that the run fits
;   inside the tb_cpu.vhd watchdog. It halts at 168270 cycles, 1683 us against
;   a 10 ms G_TIMEOUT.
;
; THE UPSTREAM MEASUREMENTS BELOW THEREFORE DESCRIBE NEITHER THIS GRID NOR THIS
; CPU. They are kept as the historical record they are. The number that tracks
; this program on this CPU is the committed test/prog_mandel_perf.stats.golden,
; which "make check" diffs on every run.
;
; ----------------------------------------------------------------------------
; CHECKSUM
;
; The upstream program printed its output, so its correctness was a thing a
; human looked at. Here there is nowhere to print to, and for a long time this
; program checked nothing at all: it computed the fractal, discarded every
; result, and wrote a passing status word unconditionally. What actually stood
; in for a check was prog_mandel_perf.writes.golden, a trace of all 91000
; register and memory writes -- 3.0 MB, more than every other golden file in
; the tree put together, and not diffed by "make test_slow" at all, so under a
; slow memory this program verified only that it terminated.
;
; So it now checks itself instead. Every pixel folds its final z0 and z1 into
; CHECKSUM, and MANDEL_END compares the total against C_CHECKSUM before
; reporting a pass, halting with status 0x0001 on a mismatch. That is one sum
; over the actual 16-bit arithmetic of the entire sweep, so a wrong ALU result,
; a mis-set flag, a dropped EAE response or a misattributed Wishbone ACK all
; move it -- verified by fault injection: +256 on the EAE's signed multiply
; (+1 does not count, the /256 below discards the low byte) fails the run.
;
; It costs three instructions per pixel and none in the iteration loop, 1.05%
; of the cycle count. In exchange the trace is gone, and the check now works
; under "make test_slow", where nothing is diffed and the status word is the
; whole verdict.
;
; C_CHECKSUM IS PART OF THE GRID. Change X_STEP, Y_STEP or ITERATION and it
; changes with them; re-read it from prog_mandel_stats below and update it.
;
; ----------------------------------------------------------------------------
; INSTRUMENTATION (#ifdef INSTRUMENT)
;
; Choosing X_STEP / Y_STEP / ITERATION is a trade: the grid has to be coarse
; enough to fit the tb_cpu.vhd watchdog, but the workload only stays
; representative while a decent fraction of the pixels still run the iteration
; loop to completion instead of diverging after two or three passes. Judging
; that needs three numbers the run does not otherwise report -- how many pixels
; there were, how many iterations they cost in total, and how many pixels used
; their whole ITERATION budget without breaking out early.
;
; The blocks below count exactly those, and dump them -- along with CHECKSUM,
; which is why retuning the grid tells you its new value -- into the probe
; window test_monitor.vhd watches (0x7FF0-0x7FFE) just before the status word,
; so the simulator prints them. They are compiled out unless INSTRUMENT is
; defined, which ONLY test/prog_mandel_stats.asm does:
;
;    make run TEST=prog_mandel_stats
;
; That indirection is the point. This file is the performance benchmark, and
; four extra instructions in the iteration loop would move every counter in
; prog_mandel_perf.stats.golden -- so the instrumented program is a second
; build of this same source rather than a copy of it, and the benchmark build
; is exactly what it would be with these blocks deleted. Note make cannot see
; the #include that makes that work, so the Makefile names this file as an
; explicit prerequisite of prog_mandel_stats.rom.
;
; R7 is the scratch register throughout: nothing else in the program uses it,
; and MTH$MULS runs in a bank of its own.
; ============================================================================

; CPU performance testbed based instrumenting vaxmans mandelbrot demo
; mandelbrot demo done by vaxman in 2015
; performance testbed done and used for CPU improvement by sy2002 in May 2016
; added instruction counter by sy2002 in July 2020
;
; ****************************************************************************
;
; !!! All test results from V1.7 on are in doc/MIPS.md !!!
;
; ****************************************************************************
;
; Results on August, 18th 2020 (Vivado on Nexys 4 DDR):

; speed and cycle count comparison using VGA (after three runs due to cater
; for the effects of scrolling)
;
; 008C 7A95 = 9.206.421 cycles => 0,1841 sec
; 0026 4514 = 2.508.052 instructions => 3,67 cycles / instruction
;                                    => 13,62 MIPS
;
; ============================================================================
; Results on July, 13th 2020 (Vivado on MEGA65):
;
; speed and cycle count comparison using UART:
;
; 00FE 547F = 16.667.775 cycles = 0,3334 sec
; 0042 C59C =  4.375.964 instructions => 3,8089 cycles / instruction
;                                     => 13,13 MIPS
;
; speed and cycle count comparison using VGA:
;
; 0091 66D5 = 9.529.045 cycles = 0,1906 sec
; 0026 51C0 = 2.511.296 instructions => 3,7945 cycles / instruction
;                                    => 13,18 MIPS
;
; everything below this line has been done in 2016
; ============================================================================
; speed comparison using UART:
;
;  CPU revision GIT #f6ccada needs 0106 BDF3 = 17.219.059 cycles = 0,3444 sec
;
; speed comparison using VGA:
;
;  CPU revision GIT #f6ccada needs 009F 12AD = 10.425.005 cycles = 0,2085 sec
;
;
; everything below this line has been done and measured using the software
; implementation of muls, so these results are not comparable any more with
; the new results that have been generated using the hardware muls of the EAE
; ============================================================================
;
; speed comparison using UART:
;
;  CPU revision GIT #0a9e0b0 needs 0426 8EF9 = 69.635.833 cycles = 1,3927 sec
;  CPU revision GIT #0aeb48e needs 02F9 31C8 = 49.885.640 cycles = 0,9977 sec
;  CPU revision GIT #60f1294 needs 02D4 FA6C = 47.512.172 cycles = 0,9502 sec
;  CPU revision GIT #83e2936 needs 02D2 3BCF = 47.332.303 cycles = 0,9466 sec
;
; speed comparison using VGA:
;
;  CPU revision GIT #0a9e0b0 needs 0425 7A16 = 69.564.950 cycles = 1,3913 sec
;  CPU revision GIT #0aeb48e needs 02F4 3938 = 49.559.864 cycles = 0,9913 sec
;  CPU revision GIT #60f1294 needs 02CF 1666 = 47.126.118 cycles = 0,9425 sec
;  CPU revision GIT #83e2936 needs 02CC 0531 = 46.925.105 cycles = 0,9385 sec
;
;  using the instruction counter feature of the emulator we learned, that this
;  test program consists of 12.143.388 instructions, i.e. the FGA QNICE system
;  performs at an average of 3,86 cycles/instruction which leads to 
;  a system performance 12,93 MIPS.

; BEGIN INSERT MONITOR ROM CODE
#define         SYSCALL(x,y)    ASUB    x, y
#define         RET             MOVE    @R13++, R15

IO$EAE_OPERAND_0    .EQU    0xFF18
IO$EAE_OPERAND_1    .EQU    0xFF19
IO$EAE_RESULT_LO    .EQU    0xFF1A
IO$EAE_RESULT_HI    .EQU    0xFF1B
IO$EAE_CSR          .EQU    0xFF1C ; Command and Status Register

EAE$MULU        .EQU    0x0000                  ; Unsigned 16 bit multiplication
EAE$MULS        .EQU    0x0001                  ; Signed 16 bit multiplication
EAE$DIVU        .EQU    0x0002                  ; Unsigned 16 bit division with remainder
EAE$DIVS        .EQU    0x0003                  ; Signed 16 bit division with remainder


reset           RBRA    START, 1
muls            RBRA    MTH$MULS, 1

L_STACK_BOT     .DW     0, 0, 0, 0, 0, 0, 0, 0, 0, 0
L_STACK_TOP     .DW     0

MTH$MULS        INCRB
                MOVE    IO$EAE_OPERAND_0, R0
                MOVE    R8, @R0++           ; R0 now points to OPERAND_1
                MOVE    R9, @R0
                MOVE    IO$EAE_CSR, R0
                MOVE    EAE$MULS, @R0
                MOVE    IO$EAE_RESULT_LO, R0
                MOVE    @R0++, R10
                MOVE    @R0, R11
                DECRB
                RET

START           MOVE    L_STACK_TOP, R13    ; setup Stack Pointer

; END INSERT MONITOR ROM CODE


#define         POINTER R12

;
DIVERGENT       .EQU    0x0400              ; Constant for divergence test
X_START         .EQU    -0x0200             ; -512 = - 2 * scale with scale = 256
X_END           .EQU    0x0100              ; +128
X_STEP          .EQU    0x004B              ; was 0x000B
Y_START         .EQU    -0x0180             ; -256
Y_END           .EQU    0x0180              ; 256
Y_STEP          .EQU    0x0053              ; was 0x0013
ITERATION       .EQU    0x001A              ; Number of iterations
; Fingerprint of the whole sweep: the sum, with 16-bit wraparound, of the final
; z0 and z1 of every pixel. Re-read it from prog_mandel_stats (probe 0x7FF0)
; and update this line whenever X_STEP / Y_STEP / ITERATION change -- those
; four constants are one unit, and a mismatch halts with status 0x0001.
C_CHECKSUM      .EQU    0xFD71              ; Expected checksum for this grid
;
#ifdef INSTRUMENT
; The probe window test_monitor.vhd reports. Five consecutive words, written in
; the same order as the CHECKSUM / STAT_* block at the end of this file.
PROBE_BASE      .EQU    0x7FF0              ; checksum
;                       0x7FF1                pixels
;                       0x7FF2                completed pixels
;                       0x7FF3                total iterations, low word
;                       0x7FF4                total iterations, high word
#endif
;
; for (y = y_start; y <= y_end; y += y_step)
; {
                XOR     R2, R2
                MOVE    CHECKSUM, POINTER   ; Zero the checksum
                MOVE    R2, @POINTER
#ifdef INSTRUMENT
                MOVE    STAT_PIXELS, R7     ; Zero the four counters
                MOVE    R2, @R7++
                MOVE    R2, @R7++
                MOVE    R2, @R7++
                MOVE    R2, @R7
#endif
                MOVE    Y_START, R0         ; R0 = y
OUTER_LOOP      CMP     Y_END, R0           ; End reached?
                RBRA    MANDEL_END, !V      ; Yes
;   for (x = x_start; x <= x_end; x += x_step)
;   {
                MOVE    X_START, R1         ; R1 = x
INNER_LOOP      CMP     X_END, R1           ; End reached?
                RBRA    INNER_LOOP_END, !V  ; Yes
;     z0 = z1 = 0;
                XOR     R2, R2
                XOR     R3, R3
#ifdef INSTRUMENT
                MOVE    STAT_PIXELS, R7     ; One more pixel
                ADD     1, @R7
#endif
;     for (i = i_max; i; i--)
;     {
                MOVE    ITERATION, R6       ; i = i_max
;;;
#ifdef INSTRUMENT
; 32-bit, because a finer grid overflows 16 bits quickly: the upstream 70 x 41
; sweep runs to about 75000 iterations. MOVE leaves the carry alone, so the
; reload of R7 between the two halves is harmless.
ITERATION_LOOP  MOVE    STAT_ITER_LO, R7    ; One more iteration
                ADD     1, @R7
                MOVE    STAT_ITER_HI, R7
                ADDC    0, @R7
                MOVE R3, R8                 ; Compute z1 ** 2 for z2 = (z0 * z0 - z1 * z1) / 256
#else
ITERATION_LOOP  MOVE R3, R8                 ; Compute z1 ** 2 for z2 = (z0 * z0 - z1 * z1) / 256
#endif
                MOVE R3, R9
                SYSCALL(muls, 1)
;
                MOVE    Z1SQUARE_LOW, POINTER
                MOVE    R10, @POINTER       ; Remember the result for later
                MOVE    Z1SQUARE_HIGH, POINTER
                MOVE    R11, @POINTER
;
                MOVE    R2, R8              ; Compute z0 * z0
                MOVE    R2, R9
                SYSCALL(muls, 1)
;
                MOVE    Z0SQUARE_LOW, POINTER
                MOVE    R10, @POINTER       ; Remember the result for later
                MOVE    Z0SQUARE_HIGH, POINTER
                MOVE    R11, @POINTER
;
                MOVE    Z1SQUARE_LOW, POINTER
                MOVE    @POINTER, R8
                MOVE    Z1SQUARE_HIGH, POINTER
                MOVE    @POINTER, R9
                SUB     R8, R10             ; First step of subtraction
                SUBC    R9, R11 ; Subtract high word
; R11/R10 now contains z0 ** 2 - z1 ** 2, next step is division by 256:
                SWAP    R10, R10
                AND     0x00FF, R10
                SWAP    R11, R11
                AND     0xFF00, R11
                OR      R11, R10
                MOVE    R10, R4             ; R4 now contains z2
;       z3 = 2 * z0 * z1 / 256
                MOVE    R2, R8
                ADD     R2, R8              ; R8 = 2 * z0
                MOVE    R3, R9
                SYSCALL(muls, 1)          ; R11|R10 = 2 * R2 * R3
                SWAP    R10, R10
                AND     0x00FF, R10
                SWAP    R11, R11
                AND     0xFF00, R11
                OR      R11, R10
                MOVE    R10, R5             ; R5 now contains z3
;       z1 = z3 + y
                MOVE    R5, R3
                ADD     R0, R3
;       z0 = z2 + x
                MOVE    R4, R2
                ADD     R1, R2
;       if (z0 * z0 / 256 + z1 * z1 / 256 > DIVERGENT)
; Implemented as (z0 ** 2 + z1 ** 2) / 256
                MOVE    Z0SQUARE_LOW, POINTER
                MOVE    @POINTER, R8
                MOVE    Z0SQUARE_HIGH, POINTER
                MOVE    @POINTER, R9
                MOVE    Z1SQUARE_LOW, POINTER
                MOVE    @POINTER, R10
                MOVE    Z1SQUARE_HIGH, POINTER
                MOVE    @POINTER, R11
                ADD     R10, R8
                ADDC    R11, R9
                SWAP    R8, R8
                AND     0x00FF, R8
                SWAP    R9, R9
                AND     0xFF00, R9
                OR      R9, R8              ; R8 now contains the left side of the comparison
                CMP     DIVERGENT, R8
;         break;
                RBRA    BREAK, !V           ; The sequence is diverging
;;;
                SUB     1, R6               ; i--
                RBRA    ITERATION_LOOP, !Z
#ifdef INSTRUMENT
; Reached only by falling out of the loop with R6 = 0, i.e. the pixel used its
; whole ITERATION budget. The diverging path branches straight to BREAK and
; skips this.
                MOVE    STAT_FULL, R7       ; One more pixel that did not diverge
                ADD     1, @R7
#endif
;     }
;     printf("%c", display[iteration % 7]);
; Fold this pixel's final z0 and z1 into the checksum. Once per pixel, so the
; iteration loop above is untouched -- see the CHECKSUM note in the header.
BREAK           MOVE    CHECKSUM, POINTER
                ADD     R2, @POINTER
                ADD     R3, @POINTER
                ADD     X_STEP, R1          ; x += x_step
                RBRA    INNER_LOOP, 1
;   }
;   printf("\n");
INNER_LOOP_END  ADD     Y_STEP, R0
                RBRA    OUTER_LOOP, 1

; }

#ifdef INSTRUMENT
MANDEL_END      MOVE    CHECKSUM, R7    ; Hand the five words to test_monitor.vhd
                MOVE    PROBE_BASE, POINTER
                MOVE    @R7++, @POINTER++
                MOVE    @R7++, @POINTER++
                MOVE    @R7++, @POINTER++
                MOVE    @R7++, @POINTER++
                MOVE    @R7, @POINTER
                MOVE    CHECKSUM, POINTER
#else
MANDEL_END      MOVE    CHECKSUM, POINTER
#endif
                CMP     C_CHECKSUM, @POINTER
                RBRA    MANDEL_FAIL, !Z
                MOVE    0x7FFF, R0      ; Test status word (see test/README.md)
                MOVE    0x0000, @R0     ; 0 = pass
                HALT

; The sweep computed something other than the fractal. The probe lines above
; carry the checksum it did compute, so run prog_mandel_stats to see it.
MANDEL_FAIL     MOVE    0x7FFF, R0
                MOVE    0x0001, @R0
                HALT

Z0SQUARE_LOW    .BLOCK      1
Z0SQUARE_HIGH   .BLOCK      1
Z1SQUARE_LOW    .BLOCK      1
Z1SQUARE_HIGH   .BLOCK      1

; Zeroed at START rather than trusted to come out of the ROM image that way.
; The instrumented build copies all five words to PROBE_BASE in this order, so
; the STAT_* block has to stay immediately below CHECKSUM.
CHECKSUM        .BLOCK      1
#ifdef INSTRUMENT
STAT_PIXELS     .BLOCK      1
STAT_FULL       .BLOCK      1
STAT_ITER_LO    .BLOCK      1
STAT_ITER_HI    .BLOCK      1
#endif

