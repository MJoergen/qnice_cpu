library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.cpu_constants.all;

entity alu is
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;
      alu_oper_i      : in  std_logic_vector(3 downto 0);
      alu_ctrl_i      : in  std_logic_vector(5 downto 0);
      alu_src_val_i   : in  std_logic_vector(15 downto 0);
      alu_dst_val_i   : in  std_logic_vector(15 downto 0);
      alu_flags_i     : in  std_logic_vector(15 downto 0);
      alu_res_val_o   : out std_logic_vector(15 downto 0);
      alu_res_flags_o : out std_logic_vector(15 downto 0)
   );
end entity alu;

architecture synthesis of alu is

   signal alu_res_val : std_logic_vector(16 downto 0);

begin

   i_alu_data : entity work.alu_data
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         opcode_i   => alu_oper_i,
         sr_i       => alu_flags_i,
         src_data_i => alu_src_val_i,
         dst_data_i => alu_dst_val_i,
         res_data_o => alu_res_val
      ); -- i_alu_data

   i_alu_flags : entity work.alu_flags
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         opcode_i   => alu_oper_i,
         ctrl_i     => alu_ctrl_i,
         sr_i       => alu_flags_i,
         src_data_i => alu_src_val_i,
         dst_data_i => alu_dst_val_i,
         res_data_i => alu_res_val,
         sr_o       => alu_res_flags_o
      ); -- i_alu_flags

   alu_res_val_o <= alu_res_val(15 downto 0);

end architecture synthesis;

