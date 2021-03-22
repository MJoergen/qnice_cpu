# Simple Makefile which just runs through all the DUTs
# and does Bounded Model Check on each of them.

DUTS  = one_stage_buffer
DUTS += one_stage_fifo

BMC   = $(patsubst %,%_bmc,$(DUTS))
COVER = $(patsubst %,%_cover,$(DUTS))

all: $(BMC)

%_bmc: SBY=$(patsubst %_bmc,%,$@)
%_bmc:
	sby --yosys "yosys -m ghdl" -f $(SBY).sby

clean:
	rm -rf $(BMC)
	rm -rf $(COVER)

