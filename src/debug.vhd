-- Simulation-only log of every register and memory write the CPU retires, in
-- the order it retires them. "make check" diffs it against a committed
-- test/<prog>.writes.golden, and test/crosscheck.py replays it to reconstruct
-- what this CPU left in memory and in the register file, for the differential
-- tests against upstream.
--
-- A register write carries the BANK it lands in when it is one of R0-R7, and
-- not otherwise, because R8-R15 are not banked -- printing "bank 0x00" for
-- them would state something the register file does not implement. The bank
-- is what makes the log a description of the final register file rather than
-- just of the traffic: without it "to register 3" names eight different
-- registers over a program's lifetime, so nothing downstream could tell which
-- of them held the last value written.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;
   use std.textio.all;

entity debug is
   generic (
      G_FILE_NAME : string := ""
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      -- Register writes. reg_bank_i is meaningful only for R0-R7; see the
      -- header, and registers.vhd's wr_bank_o for why it is a port of its own
      -- rather than the upper byte of the status register.
      reg_we_i   : in  std_logic;
      reg_addr_i : in  std_logic_vector(3 downto 0);
      reg_data_i : in  std_logic_vector(15 downto 0);
      reg_bank_i : in  std_logic_vector(7 downto 0);

      -- Memory writes
      mem_we_i   : in  std_logic;
      mem_addr_i : in  std_logic_vector(15 downto 0);
      mem_data_i : in  std_logic_vector(15 downto 0)
   );
end entity debug;

architecture simulation of debug is

begin

   p_debug : process
      file     tf : text;
      variable l  : line;
   begin
      if G_FILE_NAME = "" then
         wait;
      end if;

      file_open(tf, G_FILE_NAME, write_mode);
      wait until rst_i = '0';

      main_loop : loop
         wait until clk_i = '1';

         if reg_we_i = '1' then
            write(l, "Write value 0x" & to_hstring(reg_data_i) & " to register " & to_hstring(reg_addr_i));
            if reg_addr_i(3) = '0' then
               write(l, " bank 0x" & to_hstring(reg_bank_i));
            end if;
            writeline(tf, l);
         end if;

         if mem_we_i = '1' then
            write(l, "Write value 0x" & to_hstring(mem_data_i) & " to memory 0x" & to_hstring(mem_addr_i));
            writeline(tf, l);
         end if;
      end loop main_loop;

      file_close(tf);
   end process p_debug;

end architecture simulation;

