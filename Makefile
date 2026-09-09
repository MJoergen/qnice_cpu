# Available make targets:
# 'make' runs the simulation
# 'make system.bit' runs Vivado synthesis and bitfile generation
# 'make synth' runs Yosys synthesis

XILINX_DIR = /opt/Xilinx/Vivado/2022.2

SOURCES += src/sub/dp_ram.vhd
SOURCES += src/sub/one_stage_buffer.vhd
SOURCES += src/sub/one_stage_fifo.vhd
SOURCES += src/sub/pipe_concat.vhd
SOURCES += src/sub/two_stage_buffer.vhd
SOURCES += src/sub/two_stage_fifo.vhd

SOURCES += src/cpu_constants.vhd
SOURCES += src/fetch/fetch.vhd
SOURCES += src/icache/icache.vhd
SOURCES += src/registers/registers.vhd
SOURCES += src/memory/memory.vhd
SOURCES += src/debug.vhd

SOURCES += src/cpu_main/sub/alu_data.vhd
SOURCES += src/cpu_main/sub/alu_flags.vhd
SOURCES += src/cpu_main/sub/alu.vhd
SOURCES += src/cpu_main/sub/microcode.vhd
SOURCES += src/cpu_main/decode.vhd
SOURCES += src/cpu_main/sequencer.vhd
SOURCES += src/cpu_main/prepare.vhd
SOURCES += src/cpu_main/write.vhd
SOURCES += src/cpu_main/cpu_main.vhd

SOURCES += src/cpu.vhd

TEST_SOURCES += test/wb_dp_mem.vhd
TEST_SOURCES += test/test_monitor.vhd
TEST_SOURCES += test/eae.vhd
TEST_SOURCES += test/wb_mux.vhd
TEST_SOURCES += test/system.vhd

# The testbench that runs the same programs on upstream's own CPU, and the one
# patch this repository applies to upstream source. Both belong to
# "make crosscheck_rtl" -- see that section below -- and are named here so that
# "make lint" holds the testbench to the same style rules as everything else.
UPSTREAM_TB    = test/tb_upstream.vhd
UPSTREAM_PATCH = test/upstream.patch

TEST ?= prog
REGISTER_BANK_WIDTH ?= 8

# Wishbone slave latency injected by the memory model test/wb_dp_mem.vhd, per
# port: *_STALL_DELAY delays acceptance of a request, *_ACK_DELAY is the total
# acceptance-to-ACK latency (minimum 1). See that file's header -- the two are
# not interchangeable, and only the ACK delay leaves requests in flight, which
# is what FETCH's wb_stale counting and MEMORY's op-type FIFO exist to track.
#
# These defaults are the zero-latency behaviour that every test/*.golden file
# was recorded against, so "make check" is only meaningful at these values.
# "make test_slow" below overrides them and checks the programs' own verdicts.
A_STALL_DELAY ?= 0
B_STALL_DELAY ?= 0
A_ACK_DELAY   ?= 1
B_ACK_DELAY   ?= 1

# Disassemble each retiring instruction to the console. Off by default: a full
# run is thousands of lines, and the verdict comes from the status word and the
# writes log, not from reading them. "make run TEST=prog DEBUG=true" turns it
# on for following a run instruction by instruction; the disassembly goes to
# stdout, so it does not disturb any of the files that are diffed.
DEBUG ?= false

# The configuration "make test_slow" uses: slow in both ways, on both ports.
SLOW = A_STALL_DELAY=2 B_STALL_DELAY=2 A_ACK_DELAY=3 B_ACK_DELAY=3

# Every test program that "make test" runs.
TESTS  = prog
TESTS += prog_simple
TESTS += prog_pipeline
TESTS += prog_interleave
TESTS += prog_flags
TESTS += prog_r15
TESTS += prog_hazard
TESTS += prog_self_modifying
TESTS += prog_subroutine
TESTS += prog_waveform
TESTS += prog_eae
TESTS += prog_eae_stall
TESTS += prog_wb_mux
TESTS += prog_mandel_perf

# Programs whose write log is deliberately NOT kept as a golden file. The log
# is still produced -- it is the first thing to read when one of these fails --
# it is just not compared against a committed copy, and "make golden" does not
# write one.
#
# Only prog_mandel_perf is on this list, and only because of its size: 91k
# lines and 3.0 MB, 95% of every golden file in the tree put together, for a
# 170000-cycle run. What made that affordable to drop is that the program now
# checks its own arithmetic -- see the CHECKSUM note in its header -- which is
# a stronger check than the trace in the way that matters here, because a
# status word is also checked by "make test_slow", where no golden file is
# diffed at all. Its .stats.golden is unaffected and still diffed.
NO_WRITES_GOLDEN = prog_mandel_perf

ASM = test/$(TEST).asm
ROM = test/$(TEST).rom
# Override this if the QNICE-FPGA checkout lives somewhere else, e.g. in CI:
#   make test ASSEMBLER=/path/to/QNICE-FPGA/assembler/asm
ASSEMBLER ?= $(HOME)/git/sy2002/QNICE-FPGA/assembler/asm

# Log of every register and memory write, and the committed reference copy of it
WRITES = test/$(TEST).writes
GOLDEN = test/$(TEST).writes.golden

# Per-run statistics (cycle count, memory request counts), and its reference
# copy. Unlike WRITES this is about performance rather than behaviour: a diff
# here means the program got faster or slower, or changed how it uses the two
# memory buses. See test/README.md.
STATS  = test/$(TEST).stats
STATS_GOLDEN = test/$(TEST).stats.golden

TB  = tb_cpu
TEST_SOURCES += test/$(TB).vhd
WAVE          = test/$(TB)_$(TEST).ghw
SAVE          = test/$(TB).gtkw

TOP = system


################################################
## Help
################################################

.PHONY: help
help:
	@echo
	@echo "Possible targets:"
	@echo "  make sim            : Run simulation and open the waveform viewer"
	@echo "  make test           : Run all test programs headless, for CI"
	@echo "  make test_slow      : Run all test programs against a slow memory model"
	@echo "  make crosscheck     : Diff every program against the reference emulator"
	@echo "  make crosscheck_rtl : Diff every program against the upstream RTL CPU"
	@echo "  make check          : Run one test program headless"
	@echo "  make golden         : Regenerate the test/*.{writes,stats}.golden files"
	@echo "  make system.bit     : Run synthesis using Vivado"
	@echo "  make utilization    : Refresh the utilization numbers in doc/README.md (needs Vivado)"
	@echo "  make synth          : Run synthesis using yosys"
	@echo "  make diagrams       : Re-render every .tex diagram to .png (needs pdflatex)"
	@echo "  make formal         : Run formal verification"
	@echo "  make lint           : Run VSG style-guide linting on all source files"
	@echo "  make clean          : Remove all generated files"
	@echo "  make help           : This message"
	@echo "Optional arguments:"
	@echo "  TEST=<filename>           : Specify assembly source file. Defaults to prog."
	@echo "  REGISTER_BANK_WIDTH=<val> : Number of bits in register bank number. Defaults to 8."
	@echo "  A_STALL_DELAY / B_STALL_DELAY=<val> : Memory stall cycles per port. Default 0."
	@echo "  A_ACK_DELAY / B_ACK_DELAY=<val>     : Memory ACK latency per port. Default 1."
	@echo "  DEBUG=true                : Disassemble each instruction to stdout. Default false."
	@echo


################################################
## Simulation
################################################

# The simulation ends itself: test/test_monitor.vhd reads the status word that
# the test program writes just before its final HALT and exits 0 on pass,
# 1 on fail, so every target below can simply be believed. See test/README.md.
GHDL_RUN = ghdl -r --std=08 $(TB) \
	   -gG_ROM=$(ROM) \
	   -gG_REGISTER_BANK_WIDTH=$(REGISTER_BANK_WIDTH) \
	   -gG_WRITES_FILE=$(WRITES) \
	   -gG_STATS_FILE=$(STATS) \
	   -gG_A_STALL_DELAY=$(A_STALL_DELAY) \
	   -gG_B_STALL_DELAY=$(B_STALL_DELAY) \
	   -gG_A_ACK_DELAY=$(A_ACK_DELAY) \
	   -gG_B_ACK_DELAY=$(B_ACK_DELAY) \
	   -gG_DEBUG=$(DEBUG)

.PHONY: build
build: $(SOURCES) $(TEST_SOURCES)
	ghdl -i --std=08 $(SOURCES) $(TEST_SOURCES)
	ghdl -m --std=08 $(TB)

# Run one test program, with waveform tracing, and open the waveform viewer.
.PHONY: sim
sim: $(WAVE)
	gtkwave $(WAVE) $(SAVE)

$(WAVE): $(SOURCES) $(TEST_SOURCES) $(ROM)
	$(MAKE) build
	$(GHDL_RUN) --wave=$(WAVE)

# Run one test program headless, without waveform tracing.
.PHONY: run
run: build $(ROM)
	$(GHDL_RUN)

# Run one test program and additionally compare the log of every register and
# memory write against its committed reference copy. This catches regressions
# that the program's own self-checks do not, so it is what CI should run.
.PHONY: check
check: run
	@if [ -n "$(filter $(TEST),$(NO_WRITES_GOLDEN))" ]; then \
	   echo "($(TEST): writes log deliberately not kept, see test/README.md)"; \
	else \
	   echo "diff -u $(GOLDEN) $(WRITES)"; \
	   diff -u $(GOLDEN) $(WRITES); \
	fi
	diff -u $(STATS_GOLDEN) $(STATS)

# Run every test program. Unlike a plain "make -k", this reports the failures
# together at the end, and still fails the build as a whole.
.PHONY: test
test:
	@failed=""; \
	for t in $(TESTS); do \
	   echo "=== $$t ==="; \
	   $(MAKE) --no-print-directory check TEST=$$t || failed="$$failed $$t"; \
	done; \
	if [ -n "$$failed" ]; then echo "FAILED:$$failed"; exit 1; fi; \
	echo "All $(words $(TESTS)) tests passed"

# Run every test program against a deliberately slow memory. Unlike "make
# test" this compares nothing against the golden files: the delays change every
# cycle count, and stalling the data bus reorders the write log's interleaving
# of register and memory writes. What is checked is each program's OWN verdict,
# the status word it writes to 0x7FFF, which must not depend on how long the
# memory takes to answer. That makes this the test for the masters' response
# bookkeeping -- FETCH's wb_stale counting and MEMORY's op-type FIFO -- which
# against a zero-latency slave is barely exercised at all.
.PHONY: test_slow
test_slow:
	@failed=""; \
	for t in $(TESTS); do \
	   echo "=== $$t ==="; \
	   $(MAKE) --no-print-directory run TEST=$$t $(SLOW) || failed="$$failed $$t"; \
	done; \
	if [ -n "$$failed" ]; then echo "FAILED:$$failed"; exit 1; fi; \
	echo "All $(words $(TESTS)) tests passed against slow memory ($(SLOW))"

# Regenerate the reference copies. Only ever do this deliberately, and read the
# resulting "git diff" carefully -- these files are the regression check.
.PHONY: golden
golden:
	@for t in $(TESTS); do \
	   echo "=== $$t ==="; \
	   $(MAKE) --no-print-directory run TEST=$$t || exit 1; \
	   case " $(NO_WRITES_GOLDEN) " in \
	      *" $$t "*) echo "(skipping $$t.writes.golden)" ;; \
	      *) cp test/$$t.writes test/$$t.writes.golden ;; \
	   esac; \
	   cp test/$$t.stats  test/$$t.stats.golden; \
	done

$(ROM): $(ASM)
	$(ASSEMBLER) $(ASM)

# test/prog_mandel_stats.asm is two preprocessor directives that #include
# test/prog_mandel_perf.asm; the assembler resolves that, but the rule above
# lists only the named source, so make cannot see it. Without this an edit to
# the benchmark silently fails to reach the instrumented build, and the numbers
# it reports describe the previous version of the program.
test/prog_mandel_stats.rom: test/prog_mandel_perf.asm


################################################
## Differential test against the reference emulator
################################################

# Everything under "make test" compares this CPU against itself: the .writes
# and .stats golden files were recorded from a passing run of this very
# implementation, so they catch a regression but cannot say whether the CPU
# agrees with upstream QNICE. This target is the other half -- it runs each
# program on the reference emulator from the QNICE-FPGA project and diffs the
# final contents of RAM against what this CPU left behind.
#
# test/crosscheck.py carries the design: what is compared, why it is memory
# rather than registers, and the one documented range where the two are not
# required to agree.

# Where the upstream checkout lives. Derived from ASSEMBLER so that overriding
# that one path -- as CI does -- moves both.
QNICE_FPGA ?= $(patsubst %/assembler/asm,%,$(ASSEMBLER))

# The upstream commit the emulator is built from. Keep this in step with the
# "ref:" in .github/workflows/test.yml; the point of both is that "the QNICE
# ISA" names two diverged branches unless a commit is given. See README.md's
# "Which upstream version" section.
QNICE_REF ?= b1fb36c56508d1237f662f6234b3bfa4142b3432

CROSSCHECK_DIR = test/crosscheck
EMULATOR       = $(CROSSCHECK_DIR)/emulator/qnice

# Build the emulator from the pinned commit, into a work directory of our own.
# Deliberately NOT built in place in $(QNICE_FPGA): that is somebody else's
# checkout, it may sit on a different commit, and this must not write to it.
#
# Three things the upstream build script cannot do for us here.
#
# dist_kit/sysdef.h is generated rather than tracked (upstream removed the
# generated files from the repository), so it has to be regenerated from
# monitor/sysdef.asm with upstream's own perl script -- at the same pinned
# commit, since it defines the EAE addresses the test programs use.
#
# -fcommon is required: the sources predate GCC 10, whose -fno-common default
# turns their tentative definitions into "multiple definition of uart_status"
# at link time.
#
# And the feature set is cut down to what a differential test needs, which is
# narrower than what upstream's emulator/make.bash builds. USE_TIMER is the one
# that matters: it spawns pthreads that raise interrupts asynchronously, so
# leaving it in makes the reference side of this comparison depend on host
# timing. No test program here writes the timer registers, so no thread is ever
# actually created -- but "no thread is created today" is a worse guarantee
# than "no thread can be created", especially on a CI runner. USE_SD goes with
# it (no disk image is attached), and with both gone so does -lpthread. The
# EAE, which prog_eae.asm and prog_mandel_perf.asm need, is unconditional in
# qnice.c and is unaffected. Verified: the results are identical either way.
$(EMULATOR):
	@mkdir -p $(CROSSCHECK_DIR)
	git -C $(QNICE_FPGA) archive $(QNICE_REF) \
	   emulator monitor/sysdef.asm monitor/sysdef2header.pl | tar -x -C $(CROSSCHECK_DIR)
	@mkdir -p $(CROSSCHECK_DIR)/dist_kit
	cd $(CROSSCHECK_DIR)/monitor && perl sysdef2header.pl sysdef.asm ../dist_kit/sysdef.h
	cd $(CROSSCHECK_DIR)/emulator && cc qnice.c uart.c linenoise.c \
	   -O3 -fcommon -DUSE_UART -DUSE_SYSINFO \
	   -UUSE_SD -UUSE_TIMER -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ \
	   -o qnice -Wno-unused-result

# Narrow the scope the ordinary make way, by overriding TESTS:
#   make crosscheck TESTS=prog
.PHONY: crosscheck
crosscheck: $(EMULATOR)
	@for t in $(TESTS); do \
	   echo "=== $$t ==="; \
	   $(MAKE) --no-print-directory run TEST=$$t > $(CROSSCHECK_DIR)/$$t.runlog 2>&1 \
	      || { echo "simulation failed, see $(CROSSCHECK_DIR)/$$t.runlog"; exit 1; }; \
	done
	python3 test/crosscheck.py --emulator $(EMULATOR) $(TESTS)


################################################
## Differential test against the upstream RTL
################################################

# The other half of the differential test. "make crosscheck" above compares
# this CPU against QNICE-FPGA's C emulator; this target compares it against the
# OTHER reference the same project ships, its own VHDL CPU -- vhdl/qnice_cpu.vhd,
# a multi-cycle FSM -- running the same programs in a testbench of ours.
#
# The two references are not redundant. Where they disagree with each other,
# and they do in three places today, it is the RTL that this CPU has to match,
# because the RTL is what QNICE-FPGA synthesises; the emulator alone could not
# have told us that. test/crosscheck.py's KNOWN_DIVERGENCE records each case
# against the reference it applies to, and test/tb_upstream.vhd's header
# describes the system built around upstream's CPU.

UPSTREAM_DIR   = $(CROSSCHECK_DIR)/vhdl
UPSTREAM_WORK  = $(CROSSCHECK_DIR)/work
UPSTREAM_STAMP = $(CROSSCHECK_DIR)/upstream.stamp

# Upstream's CPU and everything below it, in analysis order. sim/dev_int_globals.vhd
# is upstream's own simulation copy of the env1_globals package; register_file.vhd
# needs exactly one constant from it (SHADOW_REGFILE_SIZE), and taking that copy
# rather than one of the two board-specific ones avoids dragging in qnice_tools
# and a board's memory map for it.
UPSTREAM_SOURCES  = $(UPSTREAM_DIR)/sim/dev_int_globals.vhd
UPSTREAM_SOURCES += $(UPSTREAM_DIR)/cpu_constants.vhd
UPSTREAM_SOURCES += $(UPSTREAM_DIR)/alu_shifter.vhd
UPSTREAM_SOURCES += $(UPSTREAM_DIR)/alu.vhd
UPSTREAM_SOURCES += $(UPSTREAM_DIR)/register_file.vhd
UPSTREAM_SOURCES += $(UPSTREAM_DIR)/qnice_cpu.vhd
UPSTREAM_SOURCES += $(UPSTREAM_DIR)/EAE.vhd

# Extract those files at the pinned commit, patch one of them, and analyse them
# into a GHDL library of their own.
#
# The extract names the seven files rather than taking upstream's whole vhdl/,
# which is 64 files and 1.6 MB of somebody else's VHDL -- the boards, the VGA,
# the SD card, the HyperRAM. None of it is analysed, and left in place it lands
# in every "grep -r" run in this repository, inside test/ of all places. The
# paths come from UPSTREAM_SOURCES above with the work directory stripped off,
# so the list cannot drift from what is actually compiled; naming a file that
# upstream has moved or removed makes "git archive" fail rather than leave the
# analysis to discover it.
#
# The separate --workdir is not tidiness: upstream's cpu_constants.vhd and this
# repo's src/cpu_constants.vhd declare packages of the same name, so the two
# designs cannot share one work library. Analysing them apart also means the
# ordinary "make build" never sees a line of upstream code.
#
# -fsynopsys is required and is upstream's choice, not ours: qnice_cpu.vhd and
# register_file.vhd use ieee.std_logic_arith and ieee.std_logic_unsigned, which
# GHDL refuses to elaborate without it. It is passed to "ghdl -r" as well, by
# test/crosscheck.py, since that re-elaborates.
#
# The patch is the one modification made to upstream source anywhere in this
# repository, it touches one file, and every reason for it is written in the
# patch's own header. "patch" fails the build if it no longer applies, which is
# what should happen when the pinned commit moves.
$(UPSTREAM_STAMP): $(UPSTREAM_TB) $(UPSTREAM_PATCH) Makefile
	@mkdir -p $(CROSSCHECK_DIR)
	rm -rf $(UPSTREAM_DIR) $(UPSTREAM_WORK)
	git -C $(QNICE_FPGA) archive $(QNICE_REF) \
	   $(patsubst $(CROSSCHECK_DIR)/%,%,$(UPSTREAM_SOURCES)) | tar -x -C $(CROSSCHECK_DIR)
	patch -p1 -d $(CROSSCHECK_DIR) < $(UPSTREAM_PATCH)
	@mkdir -p $(UPSTREAM_WORK)
	ghdl -a --std=08 -fsynopsys --workdir=$(UPSTREAM_WORK) $(UPSTREAM_SOURCES) $(UPSTREAM_TB)
	touch $@

# Narrow the scope the ordinary make way, by overriding TESTS:
#   make crosscheck_rtl TESTS=prog
.PHONY: crosscheck_rtl
crosscheck_rtl: $(UPSTREAM_STAMP)
	@for t in $(TESTS); do \
	   echo "=== $$t ==="; \
	   $(MAKE) --no-print-directory run TEST=$$t > $(CROSSCHECK_DIR)/$$t.runlog 2>&1 \
	      || { echo "simulation failed, see $(CROSSCHECK_DIR)/$$t.runlog"; exit 1; }; \
	done
	python3 test/crosscheck.py --reference rtl --workdir $(UPSTREAM_WORK) $(TESTS)


################################################
## Documentation
################################################

# Every hand-written timing diagram in the tree. Each is a standalone LaTeX
# document that pulls in the shared macros from doc/timing.sty; both the .tex
# and the rendered .png are committed.
#
# These targets only RENDER the diagrams, they do not derive them: every value
# in a .tex was read off a simulation by hand (src/cpu_main/timing.tex from
# test/prog_waveform.asm, doc/loop_timing.tex from test/prog_poll.asm, the two
# src/registers ones from test/prog.asm). If you change the pipeline, re-read
# the values from a fresh simulation first.
TIMINGS  = src/cpu_main/timing src/interrupt/timing doc/loop_timing
TIMINGS += src/registers/write_before_read src/registers/write_before_read_2

# Block diagrams: standalone TikZ, no shared macros. doc/cpu.tex replaced a
# diagrams.net drawing that could only be edited in the GUI -- see its header.
BLOCK_DIAGRAMS = doc/cpu

.PHONY: diagrams
diagrams: $(addsuffix .png,$(TIMINGS) $(BLOCK_DIAGRAMS))

# doc/timing.sty is a prerequisite of the timing diagrams only, which is why it
# is attached here rather than to the pattern rule: a block diagram that does
# not use it must not be rebuilt when it changes.
$(addsuffix .png,$(TIMINGS)): doc/timing.sty

%.png: %.tex
	TEXINPUTS=doc: pdflatex -interaction=nonstopmode -halt-on-error -output-directory=$(dir $@) $<
	pdftoppm -r 150 -png -singlefile $*.pdf $*
	rm -f $*.pdf $*.aux $*.log


################################################
## Synthesis using Vivado
################################################

# -mode batch, NOT -mode tcl. In tcl mode Vivado exits 0 even when the sourced
# script raises an error, so a build that aborted -- on the timing check below,
# or on a failure inside synth_design or route_design -- reported success to
# make. No bitstream was written, so nothing bad could ship, but "make
# system.bit" said nothing was wrong and "make utilization" would then go on to
# rewrite doc/README.md from whatever reports the previous run had left behind.
# Batch mode propagates the error as a non-zero exit status.
$(TOP).bit: hw/$(TOP).tcl $(SOURCES) $(TEST_SOURCES) hw/$(TOP).xdc $(ROM)
	bash -c "source $(XILINX_DIR)/settings64.sh ; vivado -mode batch -source $<"

# The -directive options below are load-bearing, not decoration. With the
# default directives this design misses timing at the 8.50 ns constraint by
# about 0.28 ns (108 failing endpoints); with them it meets it. Most of the
# violation was clock skew on a path crossing four module boundaries, i.e. a
# placement problem rather than a logic-depth one. Note the SECOND
# phys_opt_design, after route_design -- post-route physical optimisation is
# where a good part of the recovery comes from.
#
# report_timing_summary writes timing_summary.rpt next to the bitstream, and the
# check after it aborts the build on negative slack. Vivado's write_bitstream
# succeeds even when timing is violated, so without that check a bitstream is
# not evidence that the design met timing. The check calls "exit 1" rather than
# "error", so the exit status does not depend on how Vivado chooses to map a
# Tcl error onto one -- see the -mode batch note above.
#
# -flatten_hierarchy rebuilt (rather than none) lets synthesis optimise across
# module boundaries and then restores the hierarchy for reporting. The critical
# path here crosses four modules, so this is worth about 0.02 ns of slack.
hw/$(TOP).tcl: Makefile
	echo "# This is a tcl command script for the Vivado tool chain" > $@
	echo "read_vhdl -vhdl2008 { $(SOURCES) $(TEST_SOURCES) }" >> $@
	echo "read_xdc hw/$(TOP).xdc" >> $@
	echo "synth_design -top $(TOP) -part xc7a100tcsg324-1 -flatten_hierarchy rebuilt -generic G_ROM=$(ROM) -generic G_REGISTER_BANK_WIDTH=$(REGISTER_BANK_WIDTH)" >> $@
	echo "write_checkpoint -force post_synth.dcp" >> $@
	echo "opt_design -directive Explore" >> $@
	echo "place_design -directive Explore" >> $@
	echo "phys_opt_design -directive AggressiveExplore" >> $@
	echo "route_design -directive Explore" >> $@
	echo "phys_opt_design -directive AggressiveExplore" >> $@
	echo "write_checkpoint -force post_route.dcp" >> $@
	echo "report_timing_summary -file timing_summary.rpt" >> $@
	echo "report_utilization -file utilization_placed.rpt" >> $@
	echo "if {[get_property SLACK [get_timing_paths]] < 0} { puts {TIMING VIOLATED -- see timing_summary.rpt} ; exit 1 }" >> $@
	echo "write_bitstream -force $(TOP).bit" >> $@
	echo "exit" >> $@


################################################
## Utilization report
################################################

# "make utilization" refreshes the numbers in doc/README.md. It does NOT touch
# the prose around them -- the analysis of where the logic sits is hand-written.
#
# Two Vivado passes are needed, because the two tables in that document measure
# different things on purpose:
#
#  * Device totals come from the shipping build, after place-and-route, which
#    uses -flatten_hierarchy rebuilt. That is reused from $(TOP).bit rather than
#    re-run, since place-and-route is the expensive part.
#  * The per-module table comes from a synthesis-only pass with
#    -flatten_hierarchy none, because "rebuilt" lets synthesis move logic across
#    module boundaries -- which is worth real slack, but makes a per-module
#    breakdown meaningless (the ALU gets reported inside PREPARE, and i_write
#    shows 16 LUTs).
.PHONY: utilization
utilization: utilization_placed.rpt utilization_hier.rpt
	python3 hw/update_utilization.py \
	   --placed utilization_placed.rpt \
	   --hier utilization_hier.rpt \
	   --timing timing_summary.rpt \
	   --doc doc/README.md

# Written by the same Vivado run that produces the bitstream.
utilization_placed.rpt timing_summary.rpt: $(TOP).bit

utilization_hier.rpt: hw/$(TOP)_hier.tcl $(SOURCES) $(TEST_SOURCES) hw/$(TOP).xdc $(ROM)
	bash -c "source $(XILINX_DIR)/settings64.sh ; vivado -mode batch -source $<"

hw/$(TOP)_hier.tcl: Makefile
	echo "# This is a tcl command script for the Vivado tool chain" > $@
	echo "# Synthesis only, with the hierarchy preserved -- see 'make utilization'." >> $@
	echo "read_vhdl -vhdl2008 { $(SOURCES) $(TEST_SOURCES) }" >> $@
	echo "read_xdc hw/$(TOP).xdc" >> $@
	echo "synth_design -top $(TOP) -part xc7a100tcsg324-1 -flatten_hierarchy none -generic G_ROM=$(ROM) -generic G_REGISTER_BANK_WIDTH=$(REGISTER_BANK_WIDTH)" >> $@
	echo "report_utilization -hierarchical -hierarchical_depth 6 -file utilization_hier.rpt" >> $@
	echo "exit" >> $@


################################################
## Synthesis using yosys
################################################

# Yosys elaborates CPU, not SYSTEM, and that is forced by a limitation in
# yosys rather than chosen. SYSTEM instantiates test/wb_dp_mem.vhd, whose
# dp_ram runs with G_RAM_STYLE = "block", and in that mode dp_ram reads port A
# on the FALLING clock edge -- a deliberate timing trick, described at length in
# src/sub/dp_ram.vhd, that Vivado is happy with and that buys the read data path
# most of a clock period. Every port in yosys's Xilinx BRAM library
# (share/yosys/xilinx/brams_*.txt) is declared "clock posedge", so a negedge
# read port has no mapping at all and the run dies on
#
#   ERROR: no valid mapping found for memory ....dp_ram_r
#
# Writing the falling edge as a rising edge on an explicitly inverted clock net
# does not help: yosys folds "posedge !clk" straight back into "negedge clk".
# The only ways to keep SYSTEM as the top would be to give up the falling-edge
# register, which costs Vivado timing, or to let the 8 kW array map to logic,
# which is 131072 bits of mux. Both are worse than narrowing the scope.
#
# Little is lost by narrowing it. Everything under src/ is still synthesised
# here, and what drops out is testbench-only: the memory model, the data bus
# multiplexer, the monitor, and system.vhd itself -- all of which Vivado
# synthesises for real in "make system.bit". The GHDL analysis below still
# covers every file, so a syntax or semantic error anywhere still fails this
# target. See hw/CLAUDE.md, "Yosys synthesis".
.PHONY: synth
synth: $(SOURCES) $(TEST_SOURCES) $(ROM)
	ghdl -a --std=08 $(SOURCES) $(TEST_SOURCES)
	yosys -m ghdl -p 'ghdl --std=08 -gG_REGISTER_BANK_WIDTH=$(REGISTER_BANK_WIDTH) cpu; synth_xilinx -top cpu -edif cpu.edif' > yosys.log


################################################
## Formal
################################################

.PHONY: formal
formal:
	make -C formal


################################################
## Linting
################################################

# Checks every VHDL source file against CODING_STYLE.md, as encoded in
# vsg.yml -- see that file's header for what it does and does not cover.
# -ap (all_phases) reports every phase's violations in one pass instead of
# stopping at the first phase that has any, so one run shows the full
# picture. Exits non-zero if any violation is found, same as "make check"/
# "make test".
.PHONY: lint
lint: $(SOURCES) $(TEST_SOURCES) $(UPSTREAM_TB)
	vsg -c vsg.yml -ap -f $(SOURCES) $(TEST_SOURCES) $(UPSTREAM_TB)


################################################
## Cleanup
################################################

.PHONY: clean
clean:
	rm -rf test/*.lis
	rm -rf test/*.out
	rm -rf test/*.rom
	rm -rf test/*.writes
	rm -rf test/*.stats
	rm -rf work-obj08.cf
	rm -rf test/$(TB)_*.ghw
	rm -rf yosys.log
	rm -rf hw/$(TOP).tcl
	rm -rf post_synth.dcp
	rm -rf post_route.dcp
	rm -rf timing_summary.rpt
	rm -rf utilization_placed.rpt
	rm -rf utilization_hier.rpt
	rm -rf hw/$(TOP)_hier.tcl
	rm -rf $(TOP).bit
	rm -rf vivado*
	rm -rf usage_statistics_webtalk*
	rm -rf tight_setup_hold_pins.txt
	rm -rf system.edif cpu.edif
	rm -rf .Xil
	rm -rf $(CROSSCHECK_DIR)
	make -C formal clean

