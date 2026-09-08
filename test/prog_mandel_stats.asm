; The instrumented build of test/prog_mandel_perf.asm.
;
; Same program, same grid, same everything -- but with the #ifdef INSTRUMENT
; blocks of that file compiled in, so that it counts pixels and iterations and
; hands the totals to test/test_monitor.vhd through the probe window at 0x7FF0.
; Run it with
;
;    make run TEST=prog_mandel_stats
;
; and read the five "Probe 0x7FFx = ..." lines it prints:
;
;    0x7FF0  checksum over the whole sweep
;    0x7FF1  pixels visited
;    0x7FF2  pixels that used their whole ITERATION budget without diverging
;    0x7FF3  total ITERATION_LOOP passes, low word
;    0x7FF4  total ITERATION_LOOP passes, high word
;
; The last four are the feedback for tuning X_STEP / Y_STEP / ITERATION in
; prog_mandel_perf.asm: the ratio 0x7FF2 / 0x7FF1 says how much of the sweep is
; still doing real iteration work rather than diverging immediately, and
; 0x7FF4:0x7FF3 divided by 0x7FF1 is the average cost of a pixel.
;
; The first is what makes retuning practical. C_CHECKSUM in that program is
; part of the grid -- change a step or the iteration count and the sweep
; computes something different, so the benchmark halts with status 0x0001 until
; C_CHECKSUM is updated to match. Probe 0x7FF0 is the value to paste in, and it
; is dumped before the comparison so a failing run still reports it.
;
; This is a two-line file on purpose. Instrumenting by COPYING the program
; would leave two versions to keep in step, and the copy would be the one that
; rots; including it means the numbers always describe the benchmark as it
; actually is. It is deliberately NOT in the TESTS list in the Makefile, and has no
; .writes/.stats golden files: it is a measurement tool, not a test. The
; program still writes the usual status word, so the run exits 0 on success.

#define         INSTRUMENT
#include        "prog_mandel_perf.asm"
