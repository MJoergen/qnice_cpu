# Available make targets:
# 'make' runs the simulation
# 'make system.bit' runs Vivado synthesis and bitfile generation
# 'make synth' runs Yosys synthesis

XILINX_DIR = /opt/Xilinx/Vivado/2019.2

SOURCES += src/sub/dp_ram.vhd
SOURCES += src/sub/one_stage_buffer.vhd
SOURCES += src/sub/one_stage_fifo.vhd
SOURCES += src/sub/pipe_concat.vhd
SOURCES += src/sub/two_stage_buffer.vhd
SOURCES += src/sub/two_stage_fifo.vhd

SOURCES += src/cpu_constants.vhd
SOURCES += src/fetch/axi_pause.vhd
SOURCES += src/fetch/fetch.vhd
SOURCES += src/fetch/icache.vhd
SOURCES += src/fetch/fetch_cache.vhd
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

TEST_SOURCES += test/tdp_ram.vhd
TEST_SOURCES += test/wb_tdp_mem.vhd
TEST_SOURCES += test/system.vhd

TEST ?= prog
REGISTER_BANK_WIDTH ?= 8

ASM = test/$(TEST).asm
ROM = test/$(TEST).rom
ASSEMBLER = $(HOME)/git/sy2002/QNICE-FPGA/assembler/asm

TB  = tb_cpu
TEST_SOURCES += test/$(TB).vhd
WAVE          = test/$(TB).ghw
SAVE          = test/$(TB).gtkw

TOP = system


################################################
## Help
################################################

.PHONY: help
help:
	@echo
	@echo "Possible targets:"
	@echo "  make sim        : Run simulation"
	@echo "  make system.bit : Run synthesis using Vivado"
	@echo "  make synth      : Run synthesis using yosys"
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

.PHONY: sim
sim: $(WAVE)
	gtkwave $(WAVE) $(SAVE)

$(WAVE): $(SOURCES) $(TEST_SOURCES) $(ROM)
	ghdl -i --std=08 $(SOURCES) $(TEST_SOURCES)
	ghdl -m --std=08 -frelaxed $(TB)
	ghdl -r --std=08 -frelaxed $(TB) --wave=$(WAVE) --stop-time=850us -gG_ROM=$(ROM) -gG_REGISTER_BANK_WIDTH=$(REGISTER_BANK_WIDTH)

$(ROM): $(ASM)
	$(ASSEMBLER) $(ASM)


################################################
## Synthesis using Vivado
################################################

$(TOP).bit: hw/$(TOP).tcl $(SOURCES) $(TEST_SOURCES) hw/$(TOP).xdc $(ROM)
	bash -c "source $(XILINX_DIR)/settings64.sh ; vivado -mode tcl -source $<"

hw/$(TOP).tcl: Makefile
	echo "# This is a tcl command script for the Vivado tool chain" > $@
	echo "read_vhdl -vhdl2008 { $(SOURCES) $(TEST_SOURCES) }" >> $@
	echo "read_xdc hw/$(TOP).xdc" >> $@
	echo "synth_design -top $(TOP) -part xc7a100tcsg324-1 -flatten_hierarchy none -generic G_ROM=$(ROM) -generic G_REGISTER_BANK_WIDTH=$(REGISTER_BANK_WIDTH)" >> $@
	echo "write_checkpoint -force post_synth.dcp" >> $@
	echo "opt_design" >> $@
	echo "place_design" >> $@
	echo "phys_opt_design" >> $@
	echo "route_design" >> $@
	echo "write_checkpoint -force post_route.dcp" >> $@
	echo "write_bitstream -force $(TOP).bit" >> $@
	echo "exit" >> $@


################################################
## Synthesis using yosys
################################################

.PHONY: synth
synth: $(SOURCES) $(TEST_SOURCES) $(ROM)
	ghdl -a --std=08 -frelaxed $(SOURCES) $(TEST_SOURCES)
	yosys -m ghdl -p 'ghdl --std=08 -frelaxed -gG_ROM=$(ROM) -gG_REGISTER_BANK_WIDTH=$(REGISTER_BANK_WIDTH) $(TOP); synth_xilinx -top $(TOP) -edif $(TOP).edif' > yosys.log


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
	rm -rf test/$(TEST).lis
	rm -rf test/$(TEST).out
	rm -rf work-obj08.cf
	rm -rf $(WAVE)
	rm -rf $(ROM)
	rm -rf yosys.log
	rm -rf hw/$(TOP).tcl
	rm -rf post_synth.dcp
	rm -rf post_route.dcp
	rm -rf $(TOP).bit
	rm -rf vivado*
	rm -rf usage_statistics_webtalk*
	rm -rf tight_setup_hold_pins.txt
	rm -rf system.edif
	rm -rf .Xil
	make -C formal clean

