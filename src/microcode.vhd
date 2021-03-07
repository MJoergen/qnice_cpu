library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity microcode is
   port (
      addr_i  : in  std_logic_vector(3 downto 0);
      value_o : out std_logic_vector(23 downto 0)
   );
end entity microcode;

architecture synthesis of microcode is

   type microcode_t is array (0 to 15) of std_logic_vector(23 downto 0);
   constant C_MICROCODE : microcode_t := (
      -- reads_from_dst = 0
      -- writes_to_dst  = 0

      -- JMP R, R
      C_VAL_LAST &
      C_VAL_LAST &
      C_VAL_LAST,

      -- JMP R, @R
      C_VAL_LAST &
      C_VAL_LAST &
      C_VAL_LAST,

      -- JMP @R, R
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC),

      -- JMP @R, @R
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC),


      -- reads_from_dst = 0
      -- writes_to_dst  = 1

      -- MOVE R, R
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_REG_WRITE),

      -- MOVE R, @R
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WRITE),

      -- MOVE @R, R
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_REG_WRITE) &
      (C_VAL_MEM_READ_SRC),

      -- MOVE @R, @R
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_MEM_WRITE),


      -- reads_from_dst = 1
      -- writes_to_dst  = 0

      -- CMP R, R
      C_VAL_LAST &
      C_VAL_LAST &
      C_VAL_LAST,

      -- CMP R, @R
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_DST) &
      (C_VAL_MEM_READ_DST),

      -- CMP @R, R
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC),

      -- CMP @R, @R
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_MEM_WAIT_DST) &
      (C_VAL_MEM_READ_DST) &
      (C_VAL_MEM_READ_SRC),


      -- reads_from_dst = 1
      -- writes_to_dst  = 1

      -- ADD R, R
      C_VAL_LAST &
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_REG_WRITE),

      -- ADD R, @R
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_DST or C_VAL_MEM_WRITE) &
      C_VAL_MEM_READ_DST,

      -- ADD @R, R
      C_VAL_LAST &
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_REG_WRITE) &
      (C_VAL_MEM_READ_SRC),

      -- ADD @R, @R
      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_MEM_WAIT_DST or C_VAL_MEM_WRITE) &
      (C_VAL_MEM_READ_DST) &
      (C_VAL_MEM_READ_SRC)
   );

begin

   value_o <= C_MICROCODE(to_integer(addr_i));

end architecture synthesis;

