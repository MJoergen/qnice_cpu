-- Simulation-only monitor that turns a test program's own verdict into an exit
-- code, so that "make test" can run unattended in CI. It also collects the
-- per-run statistics described further down.
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
--
--
-- STATISTICS
--
-- When G_STATS_FILE names a file, four counters are written to it just before
-- the run ends:
--
--    cycles                       clock cycles from the release of reset up to
--                                 and including the cycle the HALT retires
--    instruction memory requests  accepted beats on the instruction Wishbone
--    data memory requests         accepted beats on the data Wishbone
--    simultaneous requests        cycles in which BOTH buses accepted a beat
--
-- A "request" is an accepted beat, i.e. cyc and stb and not stall -- the cycle
-- in which the slave takes the request, not the cycle the data comes back.
--
-- The cycle count exists so that a change in the CPU's performance shows up in
-- the same way a change in its behaviour does: the counters are compared
-- against a committed reference copy by "make check", see test/README.md.
-- Nothing here fails a run on its own; a program that got slower still passes,
-- it just produces a diff that has to be explained.
--
-- The last counter is the one that quantifies the Harvard split. Instruction
-- and data memory are separate interfaces backed by one dual-port RAM, so those
-- cycles are exactly the ones a single-ported design would have had to
-- serialise -- a lower bound on what the split buys, since it counts only the
-- collisions that actually happened in a machine built not to have to avoid
-- them.
--
-- The counters stop at the HALT, so the drain cycles are never counted, and
-- they are deliberately raw counts rather than ratios: a ratio computed here
-- would need rounding rules, and rounding makes a reference file argue with
-- itself.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;
use std.textio.all;

use std.env.all;

entity test_monitor is
   generic (
      -- Reserved address that a test program writes its verdict to. The default
      -- is the top word of the 8 kW memory, which no test program uses.
      G_STATUS_ADDR  : std_logic_vector(15 downto 0) := X"1FFF";
      -- Cycles to wait after the halt before deciding, see above.
      G_DRAIN_CYCLES : natural                       := 32;
      -- File to write the run statistics to. Empty disables them entirely.
      G_STATS_FILE   : string                        := ""
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      -- Asserted once the CPU has retired a HALT instruction
      halt_i     : in  std_logic;

      -- Data Wishbone bus, sampled on every accepted write
      mem_we_i   : in  std_logic;
      mem_addr_i : in  std_logic_vector(15 downto 0);
      mem_data_i : in  std_logic_vector(15 downto 0);

      -- Accepted request beats on each of the two Wishbone buses, i.e.
      -- cyc and stb and not stall. Used for the statistics only.
      wbi_req_i  : in  std_logic;
      wbd_req_i  : in  std_logic
   );
end entity test_monitor;

architecture simulation of test_monitor is

   signal halted    : std_logic := '0';
   signal cycles    : natural   := 0;
   signal wbi_reqs  : natural   := 0;
   signal wbd_reqs  : natural   := 0;
   signal both_reqs : natural   := 0;

begin

   -- Counting runs from the release of reset until the HALT retires. 'halted'
   -- is the registered flag, so the cycle carrying halt_i is itself counted and
   -- the drain cycles after it are not.
   p_count : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rst_i = '0' and halted = '0' then
            cycles <= cycles + 1;

            if wbi_req_i = '1' then
               wbi_reqs <= wbi_reqs + 1;
            end if;

            if wbd_req_i = '1' then
               wbd_reqs <= wbd_reqs + 1;
            end if;

            if wbi_req_i = '1' and wbd_req_i = '1' then
               both_reqs <= both_reqs + 1;
            end if;

            if halt_i = '1' then
               halted <= '1';
            end if;
         end if;

         if rst_i = '1' then
            halted    <= '0';
            cycles    <= 0;
            wbi_reqs  <= 0;
            wbd_reqs  <= 0;
            both_reqs <= 0;
         end if;
      end if;
   end process p_count;


   p_monitor : process
      variable status_valid : boolean := false;
      variable status       : std_logic_vector(15 downto 0) := (others => '0');
      variable drain        : natural;

      -- Written just before the run ends, so the counters are final. Called on
      -- the failure paths too: a failing run's statistics are worth having, and
      -- "make check" has already failed on the exit code by then anyway.
      procedure write_stats is
         file     sf : text;
         variable l  : line;
      begin
         if G_STATS_FILE = "" then
            return;
         end if;

         file_open(sf, G_STATS_FILE, write_mode);
         write(l, "cycles: " & integer'image(cycles));
         writeline(sf, l);
         write(l, "instruction memory requests: " & integer'image(wbi_reqs));
         writeline(sf, l);
         write(l, "data memory requests: " & integer'image(wbd_reqs));
         writeline(sf, l);
         write(l, "simultaneous requests: " & integer'image(both_reqs));
         writeline(sf, l);
         file_close(sf);

         report "Statistics: " & integer'image(cycles) & " cycles, " &
            integer'image(wbi_reqs) & " instruction and " &
            integer'image(wbd_reqs) & " data memory requests, " &
            integer'image(both_reqs) & " of them simultaneous";
      end procedure write_stats;

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

      write_stats;

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
