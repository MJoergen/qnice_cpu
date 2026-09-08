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
DUTS += wb_mux

# One stamp file per DUT, touched only when sby exits successfully.
#
# The stamp deliberately does NOT name a task output directory. Task names vary
# between jobs -- sequencer.sby has cover+prove and no bmc at all, and
# dp_ram.sby parameterises its tasks (bmc_block, bmc_distributed, ...) -- so
# there is no single "<dut>_bmc/PASS" that every job produces. Depending on one
# made those two jobs re-run on every invocation while the other ten never
# re-ran at all, even after their sources changed.
STAMPS = $(addsuffix .stamp,$(DUTS))

all: $(STAMPS) gtkw

# The .gtkw save files are the one artifact in this tree that nothing else
# reads -- not compiled, not linted, not an input to any sby job -- so drift in
# them is invisible until someone opens a counterexample and finds half the rows
# missing, which looks like a broken tool rather than a stale file. Six of the
# nine that existed before this target had rotted against RTL renames.
#
# It hangs off the stamps because it needs the traces a run leaves behind: the
# names are checked against what GTKWave will actually be handed, not against
# the source. Every job here has a cover task and a cover task always writes
# traces, so a successful run leaves something to check for all of them.
.PHONY: gtkw
gtkw: $(STAMPS)
	python3 check_gtkw.py

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

clean:
	rm -rf $(STAMPS)
	rm -rf $(foreach d,$(DUTS),$(d) $(d)_bmc* $(d)_cover* $(d)_prove*)

.PHONY: all clean
