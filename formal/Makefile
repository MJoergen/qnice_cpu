# Simple Makefile which just runs through all the DUTs
# and does Bounded Model Check on each of them.

DUTS  = one_stage_buffer
DUTS += one_stage_fifo
DUTS += two_stage_buffer
DUTS += two_stage_fifo
DUTS += pipe_concat
DUTS += memory
DUTS += fetch

BMC   = $(patsubst %,%_bmc,$(DUTS))
COVER = $(patsubst %,%_cover,$(DUTS))

all: $(BMC)

%_bmc: SBY=$(patsubst %_bmc,%,$@)
%_bmc:
	sby --yosys "yosys -m ghdl" -f $(SBY).sby

clean:
	rm -rf $(BMC)
	rm -rf $(COVER)

