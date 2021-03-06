library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity microcode is
   port (
      addr_i  : in  std_logic_vector(3 downto 0);
      value_o : out std_logic_vector(35 downto 0)
   );
end entity microcode;

architecture synthesis of microcode is

   type microcode_t is array (0 to 15) of std_logic_vector(35 downto 0);
   constant C_MICROCODE : microcode_t := (
      -- For control and jump instructions that neither reads from nor writes to destination:

      -- JMP R, R
      std_logic_vector'(
      C_VAL_LAST &
      C_VAL_LAST &
      C_VAL_LAST),

      -- JMP R, @R
      std_logic_vector'(
      C_VAL_LAST &
      C_VAL_LAST &
      C_VAL_LAST),

      -- JMP @R, R
      std_logic_vector'(
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC) &
      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC)),

      -- JMP @R, @R
      std_logic_vector'(
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC) &
      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC)),


      -- For `MOVE`-like instructions (that writes to but does not read from destination):

      -- MOVE R, R
      std_logic_vector'(
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_REG_WRITE)),

      -- MOVE R, @R
      std_logic_vector'(
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_REG_MOD_DST or C_VAL_MEM_WRITE)),

      -- MOVE @R, R
      std_logic_vector'(
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_REG_WRITE) &
      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC)),

      -- MOVE @R, @R
      std_logic_vector'(
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_REG_MOD_DST or C_VAL_MEM_WAIT_SRC or C_VAL_MEM_WRITE) &
      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC)),


      -- For `CMP`-like instructions (that reads from but does not write to destination):

      -- CMP R, R
      std_logic_vector'(
      C_VAL_LAST &
      C_VAL_LAST &
      C_VAL_LAST),

      -- CMP R, @R
      std_logic_vector'(
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_DST) &
      (C_VAL_MEM_READ_DST or C_VAL_REG_MOD_DST)),

      -- CMP @R, R
      std_logic_vector'(
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC) &
      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC)),

      -- CMP @R, @R
      std_logic_vector'(
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_MEM_WAIT_DST) &
      (C_VAL_MEM_READ_DST or C_VAL_REG_MOD_DST) &
      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC)),


      -- For `ADD`-like instructions (that reads from and writes to destination):

      -- ADD R, R
      std_logic_vector'(
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_REG_WRITE)),

      -- ADD R, @R
      std_logic_vector'(
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_REG_MOD_DST or C_VAL_MEM_WAIT_DST or C_VAL_MEM_WRITE) &
      C_VAL_MEM_READ_DST),

      -- ADD @R, R
      std_logic_vector'(
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_REG_WRITE) &
      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC)),

      -- ADD @R, @R
      std_logic_vector'(
      (C_VAL_LAST or C_VAL_REG_MOD_DST or C_VAL_MEM_WAIT_SRC or C_VAL_MEM_WAIT_DST or C_VAL_MEM_WRITE) &
      (C_VAL_MEM_READ_DST) &
      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC))
   );

begin

   value_o <= C_MICROCODE(to_integer(addr_i));

end architecture synthesis;

