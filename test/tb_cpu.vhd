library ieee;
use ieee.std_logic_1164.all;

use std.env.all;

entity tb_cpu is
   generic (
      G_REGISTER_BANK_WIDTH : integer;
      G_ROM : string;
      -- Simulation only: file to log every register and memory write to.
      -- An empty string (the default) disables the logging entirely.
      G_WRITES_FILE : string := "";
      -- A test program that has not halted by now is considered hung. The
      -- longest of the current test programs (prog.asm) halts at about 840 us.
      G_TIMEOUT : time := 2 ms
   );
end entity tb_cpu;

architecture simulation of tb_cpu is

   signal clk  : std_logic;
   signal rstn : std_logic;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 5 ns;
      wait for 10 ns; -- 100 MHz
   end process p_clk;

   p_rstn : process
   begin
      rstn <= '0';
      wait for 100 ns;
      wait until clk = '1';
      rstn <= '1';
      wait;
   end process p_rstn;

   -- The run is ended by i_test_monitor inside i_system, which turns the test
   -- program's own verdict into an exit code. This watchdog only covers the
   -- case where that never happens, and must therefore fail the run: without
   -- it a CPU that hangs and never reaches its HALT would simply run until the
   -- end of the simulation and look exactly like a pass.
   p_watchdog : process
   begin
      wait for G_TIMEOUT;
      report "TEST FAILED: no HALT within " & integer'image(G_TIMEOUT / 1 us) & " us";
      stop(1);
      wait;
   end process p_watchdog;

   i_system : entity work.system
      generic map (
         G_REGISTER_BANK_WIDTH => G_REGISTER_BANK_WIDTH,
         G_ROM => G_ROM,
         G_WRITES_FILE => G_WRITES_FILE
      )
      port map (
         clk_i  => clk,
         rstn_i => rstn
      ); -- i_cpu

end architecture simulation;

