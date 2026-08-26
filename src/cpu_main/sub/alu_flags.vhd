library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

   use work.cpu_constants.all;

entity alu_flags is
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      opcode_i   : in  std_logic_vector(3 downto 0);
      ctrl_i     : in  std_logic_vector(5 downto 0);
      src_data_i : in  std_logic_vector(15 downto 0);
      dst_data_i : in  std_logic_vector(15 downto 0);
      sr_i       : in  std_logic_vector(15 downto 0);
      res_data_i : in  std_logic_vector(16 downto 0);
      sr_o       : out std_logic_vector(15 downto 0)
   );
end entity alu_flags;

architecture synthesis of alu_flags is

   signal cmp_n : std_logic;
   signal cmp_v : std_logic;
   signal cmp_z : std_logic;

   signal zero     : std_logic;
   signal carry    : std_logic;
   signal negative : std_logic;
   signal overflow : std_logic;

begin

   zero     <= '1' when res_data_i(15 downto 0) = X"0000" else
               '0';
   carry    <= res_data_i(16);
   negative <= res_data_i(15);


   -- Overflow is true if adding/subtracting two negative numbers yields a positive
   -- number or if adding/subtracting two positive numbers yields a negative number
   -- Deliberate two-row alignment: the `not`s line up so the two cases read as
   -- one table. whitespace_005 wants the padding after the open paren removed.
-- vsg_off whitespace_005
   overflow <= (not src_data_i(15) and not dst_data_i(15) and     res_data_i(15)) or
               (    src_data_i(15) and     dst_data_i(15) and not res_data_i(15));
-- vsg_on whitespace_005

   cmp_n <= '1' when unsigned(src_data_i) > unsigned(dst_data_i) else
            '0';

   cmp_v <= '1' when signed(src_data_i) > signed(dst_data_i) else
            '0';

   cmp_z <= '1' when src_data_i = dst_data_i else
            '0';

   p_sr : process (all)
   begin
      sr_o <= sr_i or X"0001";  -- Default value to preserve bits that are not changed.

-- Deliberate one-line-per-opcode table: the alignment is the point (see
-- CODING_STYLE.md's "one statement per line" exception for this file).
-- vsg_off case_005 case_012 case_201 sequential_007
      case to_integer(unsigned(opcode_i)) is
         when C_OPCODE_MOVE =>                           sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero;
         when C_OPCODE_ADD  => sr_o(C_SR_V) <= overflow; sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero; sr_o(C_SR_C) <= carry;
         when C_OPCODE_ADDC => sr_o(C_SR_V) <= overflow; sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero; sr_o(C_SR_C) <= carry;
         when C_OPCODE_SUB  => sr_o(C_SR_V) <= overflow; sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero; sr_o(C_SR_C) <= carry;
         when C_OPCODE_SUBC => sr_o(C_SR_V) <= overflow; sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero; sr_o(C_SR_C) <= carry;
         when C_OPCODE_SHL  => sr_o(C_SR_C) <= carry;    sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero;
         when C_OPCODE_SHR  => sr_o(C_SR_X) <= carry;    sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero;
         when C_OPCODE_SWAP =>                           sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero;
         when C_OPCODE_NOT  =>                           sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero;
         when C_OPCODE_AND  =>                           sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero;
         when C_OPCODE_OR   =>                           sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero;
         when C_OPCODE_XOR  =>                           sr_o(C_SR_N) <= negative; sr_o(C_SR_Z) <= zero;
         when C_OPCODE_CMP  => sr_o(C_SR_V) <= cmp_v;    sr_o(C_SR_N) <= cmp_n;    sr_o(C_SR_Z) <= cmp_z;
         when C_OPCODE_RES  => null; -- No status bits are changed
         when C_OPCODE_CTRL =>
            case to_integer(unsigned(ctrl_i)) is
               when C_CTRL_INCRB => sr_o <= std_logic_vector(unsigned(sr_i or X"0001") + X"0100");
               when C_CTRL_DECRB => sr_o <= std_logic_vector(unsigned(sr_i or X"0001") - X"0100");
               when others       => null;
            end case;
         when C_OPCODE_JMP  => null; -- No status bits are changed
         when others    => null;
      end case;
-- vsg_on case_005 case_012 case_201 sequential_007
   end process p_sr;

end architecture synthesis;

