library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity sequencer is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      dec_valid_i  : in  std_logic;
      dec_ready_o  : out std_logic;
      dec_stage_i  : in  t_stage;
      prep_valid_o : out std_logic;
      prep_ready_i : in  std_logic;
      prep_stage_o : out t_stage
   );
end entity sequencer;

architecture synthesis of sequencer is

   signal index : integer range 0 to 3 := 0;

begin

   dec_ready_o <= '0' when dec_valid_i = '1' and prep_stage_o.microcodes(C_LAST) = '0' else prep_ready_i;

   p_index : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if prep_valid_o and prep_ready_i then
            if dec_ready_o then
               index <= 0;
            else
               index <= index + 1;
            end if;
         end if;

         if rst_i then
            index <= 0;
         end if;
      end if;
   end process p_index;

   p_output : process (all)
   begin
      prep_valid_o <= dec_valid_i;
      prep_stage_o <= dec_stage_i;
      prep_stage_o.microcodes(11 downto 0) <= dec_stage_i.microcodes((index+1)*12-1 downto index*12);
   end process p_output;

end architecture synthesis;

