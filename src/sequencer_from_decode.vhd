library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

entity sequencer_from_decode is
   port (
      clk_i               : in  std_logic;
      rst_i               : in  std_logic;

      -- From decode
      decode_valid_i      : in  std_logic;
      decode_ready_o      : out std_logic;
      decode_microcodes_i : in  std_logic_vector(23 downto 0);
      decode_immediate_i  : in  std_logic_vector(15 downto 0);
      decode_oper_i       : in  std_logic_vector(3 downto 0);
      decode_src_addr_i   : in  std_logic_vector(3 downto 0);
      decode_src_val_i    : in  std_logic_vector(15 downto 0);
      decode_src_mode_i   : in  std_logic_vector(1 downto 0);
      decode_dst_addr_i   : in  std_logic_vector(3 downto 0);
      decode_dst_val_i    : in  std_logic_vector(15 downto 0);
      decode_dst_mode_i   : in  std_logic_vector(1 downto 0);

      -- To Execute stage
      exe_valid_o         : out std_logic;
      exe_ready_i         : in  std_logic;
      exe_microcodes_o    : out std_logic_vector(7 downto 0);
      exe_immediate_o     : out std_logic_vector(15 downto 0);
      exe_oper_o          : out std_logic_vector(3 downto 0);
      exe_src_addr_o      : out std_logic_vector(3 downto 0);
      exe_src_val_o       : out std_logic_vector(15 downto 0);
      exe_src_mode_o      : out std_logic_vector(1 downto 0);
      exe_dst_addr_o      : out std_logic_vector(3 downto 0);
      exe_dst_val_o       : out std_logic_vector(15 downto 0);
      exe_dst_mode_o      : out std_logic_vector(1 downto 0)
   );
end entity sequencer_from_decode;

architecture synthesis of sequencer_from_decode is

   signal index : integer range 0 to 3 := 0;

begin

   decode_ready_o <= '1' when exe_microcodes_o(7) = '0' else '0';

   p_index : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if decode_ready_o then
            index <= 0;
         end if;

         if exe_ready_i then
            index <= index + 1;
         end if;
      end if;
   end process p_index;


   exe_microcodes_o <= decode_microcodes_i(8*index+7 downto 8*index);
   exe_immediate_o  <= decode_immediate_i;
   exe_oper_o       <= decode_oper_i;
   exe_src_addr_o   <= decode_src_addr_i;
   exe_src_val_o    <= decode_src_val_i;
   exe_src_mode_o   <= decode_src_mode_i;
   exe_dst_addr_o   <= decode_dst_addr_i;
   exe_dst_val_o    <= decode_dst_val_i;
   exe_dst_mode_o   <= decode_dst_mode_i;

end architecture synthesis;

