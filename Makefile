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
SOURCES += src/fetch/icache.vhd
SOURCES += src/registers/registers.vhd
SOURCES += src/memory/memory.vhd
SOURCES += src/debug.vhd

SOURCES += src/cpu_main/sub/alu_data.vhd
SOURCES += src/cpu_main/sub/alu_flags.vhd
SOURCES += src/cpu_main/sub/alu.vhd
SOURCES += src/cpu_main/sub/microcode.vhd
SOURCES += src/cpu_main/sub/sequencer.vhd
SOURCES += src/cpu_main/decode.vhd
SOURCES += src/cpu_main/prepare.vhd
SOURCES += src/cpu_main/write.vhd
SOURCES += src/cpu_main/cpu_main.vhd

SOURCES += src/cpu.vhd

TEST_SOURCES += test/wb_dp_mem.vhd
TEST_SOURCES += test/test_monitor.vhd
TEST_SOURCES += test/system.vhd

TEST ?= prog
REGISTER_BANK_WIDTH ?= 8

# Every test program that "make test" runs.
TESTS  = prog
TESTS += prog_simple
TESTS += prog_pipeline
TESTS += prog_interleave
TESTS += prog_flags
TESTS += prog_r15
TESTS += prog_hazard
TESTS += prog_self_modifying
TESTS += prog_waveform

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
	@echo "  make sim        : Run simulation and open the waveform viewer"
	@echo "  make test       : Run all test programs headless, for CI"
	@echo "  make check      : Run one test program headless"
	@echo "  make golden     : Regenerate the test/*.writes.golden reference files"
	@echo "  make system.bit : Run synthesis using Vivado"
	@echo "  make utilization: Refresh the utilization numbers in doc/README.md (needs Vivado)"
	@echo "  make synth      : Run synthesis using yosys"
	@echo "  make timing     : Re-render src/cpu_main/timing.png (needs pdflatex)"
	@echo "  make formal     : Run formal verification"
	@echo "  make clean      : Remove all generated files"
	@echo "  make help       : This message"
	@echo "Optional arguments:"
	@echo "  TEST=<filename>           : Specify assembly source file. Defaults to prog."
	@echo "  REGISTER_BANK_WIDTH=<val> : Number of bits in register bank number. Defaults to 8."
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
	   -gG_STATS_FILE=$(STATS)

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
	diff -u $(GOLDEN) $(WRITES)
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

# Regenerate the reference copies. Only ever do this deliberately, and read the
# resulting "git diff" carefully -- these files are the regression check.
.PHONY: golden
golden:
	@for t in $(TESTS); do \
	   echo "=== $$t ==="; \
	   $(MAKE) --no-print-directory run TEST=$$t || exit 1; \
	   cp test/$$t.writes test/$$t.writes.golden; \
	   cp test/$$t.stats  test/$$t.stats.golden; \
	done

$(ROM): $(ASM)
	$(ASSEMBLER) $(ASM)


################################################
## Documentation
################################################

# The pipeline timing diagram in src/cpu_main/README.md#Waveforms. The .tex is
# hand-written -- every value in it was read off a simulation of
# test/prog_waveform.asm -- so this target only renders it, it does not derive
# it. If you change the pipeline, re-read the values from a fresh simulation
# before running this.
TIMING = src/cpu_main/timing

.PHONY: timing
timing: $(TIMING).png

$(TIMING).png: $(TIMING).tex
	pdflatex -interaction=nonstopmode -halt-on-error -output-directory=$(dir $@) $<
	pdftoppm -r 150 -png -singlefile $(TIMING).pdf $(TIMING)
	rm -f $(TIMING).pdf $(TIMING).aux $(TIMING).log


################################################
## Synthesis using Vivado
################################################

$(TOP).bit: hw/$(TOP).tcl $(SOURCES) $(TEST_SOURCES) hw/$(TOP).xdc $(ROM)
	bash -c "source $(XILINX_DIR)/settings64.sh ; vivado -mode tcl -source $<"

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
# not evidence that the design met timing.
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
	echo "if {[get_property SLACK [get_timing_paths]] < 0} { error {TIMING VIOLATED -- see timing_summary.rpt} }" >> $@
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
	bash -c "source $(XILINX_DIR)/settings64.sh ; vivado -mode tcl -source $<"

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

.PHONY: synth
synth: $(SOURCES) $(TEST_SOURCES) $(ROM)
	ghdl -a --std=08 $(SOURCES) $(TEST_SOURCES)
	yosys -m ghdl -p 'ghdl --std=08 -gG_ROM=$(ROM) -gG_REGISTER_BANK_WIDTH=$(REGISTER_BANK_WIDTH) $(TOP); synth_xilinx -top $(TOP) -edif $(TOP).edif' > yosys.log


################################################
## Formal
################################################

.PHONY: formal
formal:
	make -C formal


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
	rm -rf system.edif
	rm -rf .Xil
	make -C formal clean

