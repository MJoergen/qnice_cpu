# Simple Makefile which just runs through all the DUTs.

DUTS  = one_stage_buffer
DUTS += one_stage_fifo
DUTS += two_stage_buffer
DUTS += two_stage_fifo
DUTS += pipe_concat
DUTS += dp_ram
DUTS += icache
DUTS += memory
DUTS += sequencer
DUTS += registers
DUTS += fetch
DUTS += cpu_main

# One stamp file per DUT, touched only when sby exits successfully.
#
# The stamp deliberately does NOT name a task output directory. Task names vary
# between jobs -- sequencer.sby has cover+prove and no bmc at all, and
# dp_ram.sby parameterises its tasks (bmc_block, bmc_distributed, ...) -- so
# there is no single "<dut>_bmc/PASS" that every job produces. Depending on one
# made those two jobs re-run on every invocation while the other ten never
# re-ran at all, even after their sources changed.
STAMPS = $(addsuffix .stamp,$(DUTS))

all: $(STAMPS) loopcheck

# Every file a job reads, taken from that job's own [files] section, so the
# prerequisites cannot drift out of step with the job description.
sby_files = $(shell sed -n '/^\[files\]/,$$p' $(1).sby | tail -n +2)

$(foreach d,$(DUTS),$(eval $(d).stamp: $(d).sby $(call sby_files,$(d))))

# The stamp is removed before sby runs and recreated only on success, so
# "stamp exists" always means "the last run of this job passed" -- a failed run
# can never be mistaken for an up-to-date one. (.DELETE_ON_ERROR is not enough:
# make only deletes a target it considers changed, and a recipe that dies at the
# sby line never touches the stamp at all.)
%.stamp:
	rm -f $@
	sby --yosys "yosys -m ghdl" -f $*.sby
	@touch $@

# Combinational-loop check for the zero-latency-slave configuration. Not an sby
# job: there is no property to state, only the question of whether the
# elaborated netlist contains a combinational cycle, which "check -assert"
# answers directly. It must be run on the whole CPU and cannot be decomposed --
# the full argument, and the loop it exists to catch, are in
# zero_latency_loop.vhd's header. "prep -flatten" is load-bearing: without it
# "check" cannot see a cycle that crosses module boundaries.
LOOP_SOURCES = $(addprefix ../,$(shell sed -n 's/^SOURCES += //p' ../Makefile))

.PHONY: loopcheck
loopcheck: zero_latency_loop.vhd $(LOOP_SOURCES)
	yosys -m ghdl -p "ghdl --std=08 $(LOOP_SOURCES) zero_latency_loop.vhd \
	   -e zero_latency_loop; prep -top zero_latency_loop -flatten; check -assert"

clean:
	rm -rf $(STAMPS)
	rm -rf $(foreach d,$(DUTS),$(d) $(d)_bmc* $(d)_cover* $(d)_prove*)

.PHONY: all clean
