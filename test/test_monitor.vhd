-- Simulation-only monitor that turns a test program's own verdict into an exit
-- code, so that "make test" can run unattended in CI.
--
-- The protocol is entirely in-band. Just before its final HALT, a test program
-- writes a status word to the reserved address G_STATUS_ADDR:
--
--    MOVE    0x1FFF, R0
--    MOVE    0x0000, @R0     ; 0 = pass, anything else = failure code
--    HALT
--
-- This monitor snoops the data Wishbone bus for that write, and when the CPU
-- halts it ends the simulation with
--
--    status word 0             ->  finish(0), i.e. exit code 0
--    status word non-zero      ->  stop(1),   i.e. exit code 1
--    no status word ever seen  ->  stop(1),   i.e. exit code 1
--
-- The last rule is what makes the protocol cheap to adopt: every HALT that a
-- program reaches on a failed sub-test is a failure automatically, without the
-- failure paths having to write anything at all. Writing a distinct code on
-- each of them is optional, and only improves the diagnostic.
--
-- The decision is deliberately not taken on the same clock edge as the halt.
-- The status write is issued by the WRITE stage one or more cycles before the
-- HALT retires, but it reaches the Wishbone bus through the Memory module, so
-- it can still be in flight at that point. G_DRAIN_CYCLES gives it time to land
-- (and gives debug.vhd time to log it). Nothing else can appear on the bus
-- during the drain: the HALT is the last instruction the CPU accepts into its
-- pipeline, see p_halt_fetched in src/cpu.vhd.
--
-- Only the first write to G_STATUS_ADDR counts, so a program cannot accidentally
-- overwrite its own verdict afterwards.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use std.env.all;

entity test_monitor is
   generic (
      -- Reserved address that a test program writes its verdict to. The default
      -- is the top word of the 8 kW memory, which no test program uses.
      G_STATUS_ADDR  : std_logic_vector(15 downto 0) := X"1FFF";
      -- Cycles to wait after the halt before deciding, see above.
      G_DRAIN_CYCLES : natural                       := 32
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      -- Asserted once the CPU has retired a HALT instruction
      halt_i     : in  std_logic;

      -- Data Wishbone bus, sampled on every accepted write
      mem_we_i   : in  std_logic;
      mem_addr_i : in  std_logic_vector(15 downto 0);
      mem_data_i : in  std_logic_vector(15 downto 0)
   );
end entity test_monitor;

architecture simulation of test_monitor is

begin

   p_monitor : process
      variable status_valid : boolean := false;
      variable status       : std_logic_vector(15 downto 0) := (others => '0');
      variable drain        : natural;
   begin
      wait until rst_i = '0';

      -- Sample the bus until the CPU halts.
      halt_loop : loop
         wait until rising_edge(clk_i);
         if mem_we_i = '1' and mem_addr_i = G_STATUS_ADDR and not status_valid then
            status_valid := true;
            status       := mem_data_i;
            report "Test status 0x" & to_hstring(mem_data_i);
         end if;
         exit halt_loop when halt_i = '1';
      end loop halt_loop;

      -- Let any in-flight memory write reach the bus.
      drain := G_DRAIN_CYCLES;
      drain_loop : while drain > 0 loop
         wait until rising_edge(clk_i);
         if mem_we_i = '1' and mem_addr_i = G_STATUS_ADDR and not status_valid then
            status_valid := true;
            status       := mem_data_i;
            report "Test status 0x" & to_hstring(mem_data_i);
         end if;
         drain := drain - 1;
      end loop drain_loop;

      if not status_valid then
         report "TEST FAILED: HALT reached without a test status write to 0x" &
            to_hstring(G_STATUS_ADDR) & ". " &
            "Look at the address of the last disassembled HALT to see where.";
         stop(1);
      elsif status = X"0000" then
         report "TEST PASSED";
         finish(0);
      else
         report "TEST FAILED: status code 0x" & to_hstring(status);
         stop(1);
      end if;

      wait;
   end process p_monitor;

end architecture simulation;
