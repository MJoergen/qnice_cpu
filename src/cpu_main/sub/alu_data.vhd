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
         -- The four arms below all fall through to res_other's default of
         -- "0" & src_data_i. They used to be marked TBD; they are not
         -- unfinished. Each was checked by forcing res_other to a different
         -- value in that arm alone and re-running the whole test suite:
         --
         --   CMP  -- don't care. The microcode issues neither REG_WRITE nor
         --           MEM_WRITE for a CMP, so res_data is never consumed. Only
         --           the flags matter, and those come from alu_flags.
         --   CTRL -- don't care, for the same reason: entry 0 of the microcode
         --           ROM writes nothing. INCRB/DECRB reach R14 through
         --           alu_flags, and HALT writes nothing at all.
         --   JMP  -- LOAD-BEARING. Do not give this arm a value of its own.
         --           DECODE rewrites a JMP's microcode to carry REG_WRITE with
         --           res_reg = R15 (see the C_OPCODE_JMP special case in
         --           decode.vhd), so WRITE stores alu_res_val into the PC --
         --           and the default above is precisely what makes that the
         --           branch target. Forcing anything else here breaks every
         --           branch in the CPU: the test suite stops reaching HALT at
         --           all and dies on the watchdog.
         --   RES  -- reserved opcode 0xD, and the only genuinely open one.
         --           DECODE classifies it like ADD, so it reads the
         --           destination and then writes the source over it: MOVE's
         --           effect with ADD's micro-op sequence. Nothing in the ISA
         --           sanctions that; it is just what falls out of the default.
         --           Rather than freeze it as behaviour, p_unimplemented in
         --           write.vhd traps it in simulation so no program can come to
         --           depend on it. The suite passing with this arm changed
         --           proves only that nothing exercises 0xD.
         when C_OPCODE_CMP  => null;
         when C_OPCODE_RES  => null;
         when C_OPCODE_CTRL => null;
         when C_OPCODE_JMP  => null;
         when others    => null;
      end case;
   end process p_res_other;

   res_data <= res_sum when is_sum = '1' else
               res_other;

   res_data_o <= res_data;

end architecture synthesis;

