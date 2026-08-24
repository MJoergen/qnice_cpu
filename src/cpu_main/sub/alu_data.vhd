library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.cpu_constants.all;

entity alu_data is
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      opcode_i   : in  std_logic_vector(3 downto 0);
      src_data_i : in  std_logic_vector(15 downto 0);
      dst_data_i : in  std_logic_vector(15 downto 0);
      sr_i       : in  std_logic_vector(15 downto 0);
      res_data_o : out std_logic_vector(16 downto 0)
   );
end entity alu_data;

architecture synthesis of alu_data is

   signal res_data  : std_logic_vector(16 downto 0);
   signal res_sum   : std_logic_vector(16 downto 0);
   signal res_other : std_logic_vector(16 downto 0);
   signal res_shr   : std_logic_vector(16 downto 0);
   signal res_shl   : std_logic_vector(16 downto 0);

   signal is_sum : std_logic;
   signal addend : std_logic_vector(16 downto 0);
   signal carry  : std_logic;

begin

   -- dst << src, fill with X, shift to C
   p_shift_left : process (src_data_i, dst_data_i, sr_i)
      variable tmp   : std_logic_vector(32 downto 0);
      variable res   : std_logic_vector(16 downto 0);
      variable shift : natural range 0 to 16;
   begin
      -- Prepare for shift
      tmp(32)           := sr_i(C_SR_C);  -- Old value of C
      tmp(31 downto 16) := dst_data_i;
      tmp(15 downto 0)  := (15 downto 0 => sr_i(C_SR_X));  -- Fill with X

      -- The shift amount is constrained to 0 to 16 and sliced from the low five
      -- bits INSIDE the guard, not derived from the full 16-bit operand. Both
      -- forms are functionally identical, but indexing tmp with an unconstrained
      -- integer makes the synthesiser build a far wider barrel shifter than the
      -- 17 positions that are actually reachable: doing it this way took
      -- alu_data from 230 to 194 LUTs.
      if unsigned(src_data_i) <= 16 then
         shift := to_integer(unsigned(src_data_i(4 downto 0)));
         res   := tmp(32-shift downto 16-shift);
      else
         res := (others => sr_i(C_SR_X));
      end if;

      res_shl <= res;
   end process p_shift_left;


   -- dst >> src, fill with C, shift to X
   p_shift_right : process (src_data_i, dst_data_i, sr_i)
      variable tmp   : std_logic_vector(32 downto 0);
      variable res   : std_logic_vector(16 downto 0);
      variable shift : natural range 0 to 16;
   begin
      -- Prepare for shift
      tmp(32 downto 17) := (32 downto 17 => sr_i(C_SR_C));  -- Fill with C
      tmp(16 downto 1)  := dst_data_i;
      tmp(0)            := sr_i(C_SR_X);  -- Old value of X

      -- See the note in p_shift_left about the constrained shift amount.
      if unsigned(src_data_i) <= 16 then
         shift := to_integer(unsigned(src_data_i(4 downto 0)));
         res   := tmp(shift+16 downto shift);
      else
         res := (others => sr_i(C_SR_C));
      end if;

      res_shr <= res;
   end process p_shift_right;


   addend <= "1" & not src_data_i when unsigned(opcode_i) = C_OPCODE_SUB or unsigned(opcode_i) = C_OPCODE_SUBC else
             "0" & src_data_i;
   carry <= sr_i(C_SR_C) when unsigned(opcode_i) = C_OPCODE_ADDC else
            not sr_i(C_SR_C) when unsigned(opcode_i) = C_OPCODE_SUBC else
            '1' when unsigned(opcode_i) = C_OPCODE_SUB else
            '0';

   -- The result mux is deliberately split in two, rather than written as one
   -- case over every opcode.
   --
   -- The addition is by far the slowest input to that mux -- it carries a
   -- 16-bit ripple -- while every other operation is a shift, a permutation or
   -- a bitwise function of signals that are already stable. Selecting over all
   -- of them at once puts the whole 16-way mux, three levels of logic, in
   -- series with the adder. Worse, the Zero flag is a 16-bit reduction of this
   -- result (see alu_flags.vhd), so those levels land on the CPU's critical
   -- path: ALU -> Status Register -> back into the PREPARE stage's r14, which
   -- must close in one cycle.
   --
   -- Muxing everything else first, in parallel with the addition, and then
   -- selecting between just those two leaves the adder facing a single 2:1 mux.
   -- See doc/README.md, "The critical path".

   res_sum <= std_logic_vector(("0" & unsigned(dst_data_i)) + unsigned(addend) + unsigned'('0'&carry));

   is_sum  <= '1' when unsigned(opcode_i) = C_OPCODE_ADD or
                       unsigned(opcode_i) = C_OPCODE_ADDC or
                       unsigned(opcode_i) = C_OPCODE_SUB or
                       unsigned(opcode_i) = C_OPCODE_SUBC else
              '0';

   p_res_other : process (src_data_i, dst_data_i, opcode_i, sr_i, res_shl, res_shr)
   begin
      res_other <= ("0" & src_data_i);  -- Default value to avoid latches
      case to_integer(unsigned(opcode_i)) is
         when C_OPCODE_MOVE => res_other <= "0" & src_data_i;
         when C_OPCODE_SHL  => res_other <= res_shl(16) & (res_shl(15 downto 0));
         when C_OPCODE_SHR  => res_other <= res_shr(0) & (res_shr(16 downto 1));
         when C_OPCODE_SWAP => res_other <= "0" & (src_data_i(7 downto 0) & src_data_i(15 downto 8));
         when C_OPCODE_NOT  => res_other <= "0" & (not src_data_i);
         when C_OPCODE_AND  => res_other <= "0" & (dst_data_i and src_data_i);
         when C_OPCODE_OR   => res_other <= "0" & (dst_data_i or src_data_i);
         when C_OPCODE_XOR  => res_other <= "0" & (dst_data_i xor src_data_i);
         when C_OPCODE_CMP  => null; -- TBD
         when C_OPCODE_RES  => null; -- TBD
         when C_OPCODE_CTRL => null; -- TBD
         when C_OPCODE_JMP  => null; -- TBD
         when others    => null;
      end case;
   end process p_res_other;

   res_data <= res_sum when is_sum = '1' else
               res_other;

   res_data_o <= res_data;

end architecture synthesis;

