library ieee;
   use ieee.std_logic_1164.all;

   use std.env.all;

entity tb_cpu is
   generic (
      G_REGISTER_BANK_WIDTH : integer;
      G_ROM                 : string;
      -- Simulation only: file to log every register and memory write to.
      -- An empty string (the default) disables the logging entirely.
      G_WRITES_FILE         : string := "";
      -- Simulation only: file to write the run statistics to (cycle count and
      -- memory request counts). An empty string (the default) disables them.
      G_STATS_FILE          : string := "";
      -- A test program that has not halted by now is considered hung. The
      -- longest of the current test programs (prog_mandel_perf.asm) halts at
      -- about 1683 us, so this leaves roughly a factor of six of headroom.
      -- That margin is deliberate: prog_mandel_perf exists to measure
      -- performance, so a slowdown is exactly what it is expected to show, and
      -- a watchdog set close to its runtime would report a regression as a
      -- hang instead of as the stats-golden diff it should be. Note this
      -- generic cannot be overridden from the ghdl command line (it is of type
      -- "time"), so raising it means editing this line.
      G_TIMEOUT             : time := 10 ms;
      -- Wishbone slave latency injected by the memory model, per port. These
      -- exist to run the whole suite against a slave that is slow in each of
      -- the two ways a pipelined Wishbone slave can be -- see
      -- test/wb_dp_mem.vhd's header, and "make test_slow". The defaults are
      -- the zero-latency behaviour that every *.golden file was recorded
      -- against, so overriding them changes cycle counts and the interleaving
      -- of the write log; only the programs' own pass/fail verdicts are
      -- meaningful then.
      G_A_STALL_DELAY       : natural  := 0;
      G_B_STALL_DELAY       : natural  := 0;
      G_A_ACK_DELAY         : positive := 1;
      G_B_ACK_DELAY         : positive := 1
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
         G_ROM                 => G_ROM,
         G_WRITES_FILE         => G_WRITES_FILE,
         G_STATS_FILE          => G_STATS_FILE,
         G_A_STALL_DELAY       => G_A_STALL_DELAY,
         G_B_STALL_DELAY       => G_B_STALL_DELAY,
         G_A_ACK_DELAY         => G_A_ACK_DELAY,
         G_B_ACK_DELAY         => G_B_ACK_DELAY,
         G_SIMULATION          => true
      )
      port map (
         clk_i  => clk,
         rstn_i => rstn
      ); -- i_cpu

end architecture simulation;

