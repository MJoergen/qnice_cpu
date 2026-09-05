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
# 7.35 ns, not the 7.25 ns this design was constrained at until now.
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
# Timing numbers quoted in the documentation that cite a 7.25 ns constraint were
# measured before this change and have been left as measured; see doc/README.md,
# "The critical path".
create_clock -name sys_clk -period 7.35 [get_ports {clk_i}];

# Configuration Bank Voltage Select
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

