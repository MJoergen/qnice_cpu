# Simple Makefile which just runs through all the DUTs
# and does Bounded Model Check on each of them.

DUTS  = one_stage_buffer
DUTS += one_stage_fifo
DUTS += two_stage_buffer
DUTS += two_stage_fifo
DUTS += pipe_concat
DUTS += dp_ram
DUTS += icache
DUTS += memory
DUTS += serializer
DUTS += registers
DUTS += fetch
DUTS += decode_execute

BMC   = $(patsubst %,%_bmc,$(DUTS))
COVER = $(patsubst %,%_cover,$(DUTS))
PROVE = $(patsubst %,%_prove,$(DUTS))
BMC_PASS   = $(patsubst %,%_bmc/PASS,$(DUTS))
COVER_PASS = $(patsubst %,%_cover/PASS,$(DUTS))

all: $(BMC_PASS)

%_bmc/PASS: DUT=$(patsubst %_bmc/PASS,%,$@)
%_bmc/PASS:
	sby --yosys "yosys -m ghdl" -f $(DUT).sby

clean:
	rm -rf $(BMC)
	rm -rf $(COVER)
	rm -rf $(PROVE)

