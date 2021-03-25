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

      -- Register writes
      reg_we_i   : in  std_logic;
      reg_addr_i : in  std_logic_vector(3 downto 0);
      reg_data_i : in  std_logic_vector(15 downto 0);

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

         if reg_we_i then
            write(l, "Write value 0x" & to_hstring(reg_data_i) & " to register " & to_hstring(reg_addr_i));
            writeline(tf, l);
         end if;

         if mem_we_i then
            write(l, "Write value 0x" & to_hstring(mem_data_i) & " to memory 0x" & to_hstring(mem_addr_i));
            writeline(tf, l);
         end if;
      end loop main_loop;

      file_close(tf);
   end process p_debug;

end architecture simulation;

