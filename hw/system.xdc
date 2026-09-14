# This file is specific for the Nexys 4 DDR board.

# Clock and reset
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { clk_i     }];    # CLK100MHZ
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports { rstn_i    }];    # CPU_RESETN

# LEDs
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { led_o[0]  }];    # LED0
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { led_o[1]  }];    # LED1
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports { led_o[2]  }];    # LED2
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { led_o[3]  }];    # LED3
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports { led_o[4]  }];    # LED4
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports { led_o[5]  }];    # LED5
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports { led_o[6]  }];    # LED6
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports { led_o[7]  }];    # LED7
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports { led_o[8]  }];    # LED8
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { led_o[9]  }];    # LED9
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { led_o[10] }];    # LED10
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { led_o[11] }];    # LED11
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { led_o[12] }];    # LED12
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports { led_o[13] }];    # LED13
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { led_o[14] }];    # LED14
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports { led_o[15] }];    # LED15

# Clock definition
#
# 7.80 ns. This design has been relaxed four times, and each step is worth keeping.
#
# FIRST, 7.25 -> 7.35 ns, because the build had become a coin flip.
#
# The worst setup path here is not one path but a dense population of
# near-identical ones -- 103 within 0.2 ns of each other -- all closing the same
# loop: PREPARE's ALU operand registers -> the ALU -> the Status Register and
# the register file's write forwarding -> back into PREPARE. At 7.25 ns that
# whole population sat within a few hundredths of a nanosecond of zero, which
# made the sign of WNS a placement outcome rather than a logic one. Measured on
# ONE unchanged netlist across five place_design directives, WNS ranged from
# +0.028 to -0.028 ns; edits nowhere near the path have moved it by as much as
# 0.284 ns.
#
# The practical consequence was that "make system.bit" had become a coin flip:
# a pair of source-level refactors that added no logic at all (they left the
# design 14 LUTs SMALLER) were enough to take it from +0.025 ns to -0.018 ns and
# turn the build red. The extra 0.10 ns costs 1.4% of clock rate and buys back a
# margin the design can actually be edited in.
#
# SECOND, 7.35 -> 7.45 ns, to afford a correctness fix.
#
# An auto-modifying pointer through R14 or R15 -- "MOVE @R14++, R0" and friends
# -- used to hang the CPU: the pointer write-back raised fetch_valid_o on a
# micro-op that was not the last, which reset DECODE, SEQUENCER and PREPARE and
# discarded the rest of the instruction. See "A pointer through R14 or R15" in
# doc/README.md. Deferring that flush to the last micro-op costs about 0.11 ns
# on exactly the net that cannot afford it, and at 7.35 ns the design missed at
# WNS -0.100 ns with 21 failing endpoints; at 7.45 ns it closes at +0.017.
#
# The 0.11 ns is not logic depth to be optimised away. The failing path runs
# r14 -> update_reg -> reg_we_o -> fetch_valid_o -> ICACHE's clock enable and is
# 80% routing, and update_reg cannot leave that net: a conditional branch that
# is not taken must not redirect. Two attempts to buy it back -- lifting rst_i
# out of a series OR into its own term, and deleting a provably dead arm of
# smc_hit -- together moved WNS by 0.004 ns.
#
# THIRD, 7.45 -> 7.70 ns, to afford hardware interrupts.
#
# In the bitstream the hardware interrupt path is optimised away altogether --
# nothing drives irq_valid_i here -- yet adding it took the design from WNS
# +0.003 ns to -0.163 ns: logically the same netlist, mapped and placed
# differently. Two follow-up changes recovered part of it (INT and RTI decoded
# in DECODE rather than compared in WRITE, and the post-instruction R14/R15
# saves confined to hardware entry, so they fold away too), reaching -0.125 ns
# with 24 failing endpoints. The failing paths are the familiar ones: PREPARE's
# dst_val_pc through the self-modifying-code window into fetch_valid_o and on
# into ICACHE and FETCH, 67-74% routing. Replacing that window's subtraction
# with block compares cut two logic levels and made WNS WORSE (-0.213 ns), which
# is what a routing-dominated path does. The structural fix, registering the
# flush, costs a cycle on every redirect.
#
# Why 7.70 and not less: at 7.60 ns the build closed, at 7.65 ns it FAILED
# (WNS -0.129 ns, 46 failing endpoints, on PREPARE's r14 -> alu_src_val loop),
# and at 7.70 ns it closed again. A looser constraint does not buy margin
# monotonically here, it changes what placement does. Note too that both
# closing builds report WNS exactly 0.000 ns: with these directives Vivado
# stops improving once timing is met, so a zero is not evidence of zero slack,
# and nor is it evidence of more. 0.25 ns costs 3.4% of clock rate.
#
# FOURTH, 7.70 -> 7.80 ns, to synthesise the Interrupt Generator.
#
# test/system.vhd now instantiates test/interrupt.vhd in the bitstream too, so
# that irq_valid_i is driven by real logic and the hardware interrupt path is
# placed and timed instead of optimised away. At 7.70 ns that build FAILED, WNS
# -0.054 ns with 13 failing endpoints -- on PREPARE's dst_val_pc into ICACHE's
# clock enable and on the ALU operand loop, 70% routing, and NOT on the request
# path, whose worst path had +1.343 ns. The interrupt logic that used to fold
# away is merged into those same cones (WRITE grew from 517 to 532 LUTs), and
# that moved the placement. At 7.80 ns it closes at +0.001 ns, the request path
# at +1.627 ns. 0.10 ns costs 1.3% of clock rate.
#
# Timing numbers quoted in the documentation that cite a 7.25, 7.35, 7.45, or
# 7.70 ns constraint were measured before the respective change and have been
# left as measured; see doc/README.md, "The critical path".
create_clock -name sys_clk -period 7.80 [get_ports {clk_i}];

# Configuration Bank Voltage Select
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

