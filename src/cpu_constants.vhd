library ieee;
use ieee.std_logic_1164.all;

package cpu_constants is

   -- Instruction format is as follows
   subtype R_IMMEDIATE   is natural range 31 downto 16;
   subtype R_INSTRUCTION is natural range 15 downto  0;
   subtype R_OPCODE      is natural range 15 downto 12;
   subtype R_SRC_REG     is natural range 11 downto  8;
   subtype R_SRC_MODE    is natural range  7 downto  6;
   subtype R_DST_REG     is natural range  5 downto  2;
   subtype R_DST_MODE    is natural range  1 downto  0;
   subtype R_JMP_MODE    is natural range  5 downto  4;
   constant R_JMP_NEG    : integer := 3;
   subtype R_JMP_COND    is natural range  2 downto  0;
   subtype R_CTRL_CMD    is natural range 11 downto  6;

   -- Decode status bits
   constant C_SR_V : integer := 5;
   constant C_SR_N : integer := 4;
   constant C_SR_Z : integer := 3;
   constant C_SR_C : integer := 2;
   constant C_SR_X : integer := 1;
   constant C_SR_1 : integer := 0;

   -- Opcodes
   constant C_OPCODE_MOVE : integer := 0;
   constant C_OPCODE_ADD  : integer := 1;
   constant C_OPCODE_ADDC : integer := 2;
   constant C_OPCODE_SUB  : integer := 3;
   constant C_OPCODE_SUBC : integer := 4;
   constant C_OPCODE_SHL  : integer := 5;
   constant C_OPCODE_SHR  : integer := 6;
   constant C_OPCODE_SWAP : integer := 7;
   constant C_OPCODE_NOT  : integer := 8;
   constant C_OPCODE_AND  : integer := 9;
   constant C_OPCODE_OR   : integer := 10;
   constant C_OPCODE_XOR  : integer := 11;
   constant C_OPCODE_CMP  : integer := 12;
   constant C_OPCODE_RES  : integer := 13;
   constant C_OPCODE_CTRL : integer := 14;
   constant C_OPCODE_JMP  : integer := 15;

   -- Control instructions
   constant C_CTRL_HALT  : integer := 0;
   constant C_CTRL_RTI   : integer := 1;
   constant C_CTRL_INT   : integer := 2;
   constant C_CTRL_INCRB : integer := 3;
   constant C_CTRL_DECRB : integer := 4;

   -- Addressing modes
   constant C_MODE_REG  : integer := 0;   -- R
   constant C_MODE_MEM  : integer := 1;   -- @R
   constant C_MODE_POST : integer := 2;   -- @R++
   constant C_MODE_PRE  : integer := 3;   -- @--R

   -- Special registers
   constant C_REG_PC : integer := 15;
   constant C_REG_SR : integer := 14;
   constant C_REG_SP : integer := 13;

   -- Branch modes
   constant C_JMP_ABRA : integer := 0;
   constant C_JMP_ASUB : integer := 1;
   constant C_JMP_RBRA : integer := 2;
   constant C_JMP_RSUB : integer := 3;

   -- Microcode address
   constant C_READ_DST    : integer := 3;   -- reads_from_dst
   constant C_WRITE_DST   : integer := 2;   -- writes_to_dst
   constant C_MEM_SRC     : integer := 1;   -- src_memory
   constant C_MEM_DST     : integer := 0;   -- dst_memory

   -- Microcode value
   constant C_LAST         : integer := 11;
   constant C_REG_MOD_SRC  : integer := 7;   -- modify source register
   constant C_REG_MOD_DST  : integer := 6;   -- modify destination register
   constant C_MEM_WAIT_SRC : integer := 5;   -- wait from source from memory
   constant C_MEM_WAIT_DST : integer := 4;   -- wait from destination from memory
   constant C_REG_WRITE    : integer := 3;   -- write to register
   constant C_MEM_READ_SRC : integer := 2;   -- memory to source
   constant C_MEM_READ_DST : integer := 1;   -- memory to destination
   constant C_MEM_WRITE    : integer := 0;   -- write to memory

   constant C_VAL_LAST         : std_logic_vector(11 downto 0) := (C_LAST         => '1', others => '0');
   constant C_VAL_REG_MOD_SRC  : std_logic_vector(11 downto 0) := (C_REG_MOD_SRC  => '1', others => '0');
   constant C_VAL_REG_MOD_DST  : std_logic_vector(11 downto 0) := (C_REG_MOD_DST  => '1', others => '0');
   constant C_VAL_MEM_WAIT_SRC : std_logic_vector(11 downto 0) := (C_MEM_WAIT_SRC => '1', others => '0');
   constant C_VAL_MEM_WAIT_DST : std_logic_vector(11 downto 0) := (C_MEM_WAIT_DST => '1', others => '0');
   constant C_VAL_REG_WRITE    : std_logic_vector(11 downto 0) := (C_REG_WRITE    => '1', others => '0');
   constant C_VAL_MEM_READ_SRC : std_logic_vector(11 downto 0) := (C_MEM_READ_SRC => '1', others => '0');
   constant C_VAL_MEM_READ_DST : std_logic_vector(11 downto 0) := (C_MEM_READ_DST => '1', others => '0');
   constant C_VAL_MEM_WRITE    : std_logic_vector(11 downto 0) := (C_MEM_WRITE    => '1', others => '0');

   procedure disassemble(pc : std_logic_vector; inst : std_logic_vector; operand : std_logic_vector);

end cpu_constants;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;
use ieee.std_logic_textio.all;
use std.textio.all;

package body cpu_constants is

   procedure disassemble(pc : std_logic_vector; inst : std_logic_vector; operand : std_logic_vector) is
      function to_hstring(slv : std_logic_vector) return string is
         variable l : line;
      begin
         hwrite(l, slv);
         return l.all;
      end function to_hstring;

      function inst_str(slv : std_logic_vector) return string is
      begin
         case to_integer(slv) is
            when C_OPCODE_MOVE => return "MOVE";
            when C_OPCODE_ADD  => return "ADD";
            when C_OPCODE_ADDC => return "ADDC";
            when C_OPCODE_SUB  => return "SUB";
            when C_OPCODE_SUBC => return "SUBC";
            when C_OPCODE_SHL  => return "SHL";
            when C_OPCODE_SHR  => return "SHR";
            when C_OPCODE_SWAP => return "SWAP";
            when C_OPCODE_NOT  => return "NOT";
            when C_OPCODE_AND  => return "AND";
            when C_OPCODE_OR   => return "OR";
            when C_OPCODE_XOR  => return "XOR";
            when C_OPCODE_CMP  => return "CMP";
            when C_OPCODE_RES  => return "???";
            when C_OPCODE_CTRL => return "CTRL";
            when C_OPCODE_JMP  => return "BRA";
            when others => return "???";
         end case;
         return "???";
      end function inst_str;

      function reg_str(reg : std_logic_vector;
                       mode : std_logic_vector;
                       oper : std_logic_vector) return string is
      begin
         if to_integer(reg) = C_REG_PC and to_integer(mode) = C_MODE_POST then
            return "0x" & to_hstring(oper);
         else
            case to_integer(mode) is
               when C_MODE_REG  => return "R" & integer'image(to_integer(reg));
               when C_MODE_MEM  => return "@R" & integer'image(to_integer(reg));
               when C_MODE_POST => return "@R" & integer'image(to_integer(reg)) & "++";
               when C_MODE_PRE  => return "@--R" & integer'image(to_integer(reg));
               when others => return "???";
            end case;
         end if;
         return "???";
      end function reg_str;

      function mode_str(mode : std_logic_vector) return string is
      begin
         case to_integer(mode) is
            when C_JMP_ABRA => return "ABRA";
            when C_JMP_ASUB => return "ASUB";
            when C_JMP_RBRA => return "RBRA";
            when C_JMP_RSUB => return "RSUB";
            when others => return "???";
         end case;
         return "???";
      end function mode_str;

      function ctrl_str(cmd : std_logic_vector) return string is
      begin
         case to_integer(cmd) is
            when C_CTRL_HALT  => return "HALT";
            when C_CTRL_RTI   => return "RTI";
            when C_CTRL_INT   => return "INT";
            when C_CTRL_INCRB => return "INCRB";
            when C_CTRL_DECRB => return "DECRB";
            when others => return "???";
         end case;
         return "???";
      end function ctrl_str;

      function neg_str(neg : std_logic) return string is
      begin
         if neg = '1' then
            return "!";
         else
            return "";
         end if;
      end function neg_str;

      function cond_str(condition : std_logic_vector) return string is
      begin
         case to_integer(condition) is
            when C_SR_V => return "V";
            when C_SR_N => return "N";
            when C_SR_Z => return "Z";
            when C_SR_C => return "C";
            when C_SR_X => return "X";
            when C_SR_1 => return "1";
            when others => return "?";
         end case;
         return "?";
      end function cond_str;

   begin
      if to_integer(inst(R_OPCODE)) = C_OPCODE_CTRL then
         if to_integer(inst(R_CTRL_CMD)) = C_CTRL_INT then
            report to_hstring(pc) & " " &
               "(" & to_hstring(inst) & ") " &
               ctrl_str(inst(R_CTRL_CMD)) & " " &
               reg_str(inst(R_DST_REG), inst(R_DST_MODE), operand);
         else
            report to_hstring(pc) & " " &
               "(" & to_hstring(inst) & ") " &
               ctrl_str(inst(R_CTRL_CMD));
         end if;
      elsif to_integer(inst(R_OPCODE)) = C_OPCODE_JMP then
         report to_hstring(pc) & " " &
               "(" & to_hstring(inst) & ") " &
               mode_str(inst(R_JMP_MODE)) & " " &
               reg_str(inst(R_SRC_REG), inst(R_SRC_MODE), operand) & ", " &
               neg_str(inst(R_JMP_NEG)) &
               cond_str(inst(R_JMP_COND));
      else
         report to_hstring(pc) & " " &
               "(" & to_hstring(inst) & ") " &
               inst_str(inst(R_OPCODE)) & " " &
               reg_str(inst(R_SRC_REG), inst(R_SRC_MODE), operand) & ", " &
               reg_str(inst(R_DST_REG), inst(R_DST_MODE), operand);
      end if;

      if to_integer(inst(R_OPCODE)) = C_OPCODE_CTRL and to_integer(inst(R_CTRL_CMD)) = C_CTRL_HALT then
         report "HALT" severity failure;
      end if;
   end procedure disassemble;

end cpu_constants;

