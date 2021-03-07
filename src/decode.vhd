library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity decode is
   port (
      clk_i            : in  std_logic;
      rst_i            : in  std_logic;

      -- From Instruction fetch
      fetch_valid_i    : in  std_logic;
      fetch_ready_o    : out std_logic;                     -- combinatorial
      fetch_double_i   : in  std_logic;
      fetch_addr_i     : in  std_logic_vector(15 downto 0);
      fetch_data_i     : in  std_logic_vector(31 downto 0);
      fetch_double_o   : out std_logic;                     -- combinatorial

      -- Register file. Value arrives on the next clock cycle
      reg_src_addr_o   : out std_logic_vector(3 downto 0);  -- combinatorial
      reg_dst_addr_o   : out std_logic_vector(3 downto 0);  -- combinatorial
      reg_src_val_i    : in  std_logic_vector(15 downto 0);
      reg_dst_val_i    : in  std_logic_vector(15 downto 0);
      reg_r14_i        : in  std_logic_vector(15 downto 0);

      -- To Execute stage
      exe_valid_o      : out std_logic;
      exe_ready_i      : in  std_logic;
      exe_microcodes_o : out std_logic_vector(23 downto 0);
      exe_immediate_o  : out std_logic_vector(15 downto 0);
      exe_oper_o       : out std_logic_vector(3 downto 0);
      exe_ctrl_o       : out std_logic_vector(5 downto 0);
      exe_src_addr_o   : out std_logic_vector(3 downto 0);
      exe_src_val_o    : out std_logic_vector(15 downto 0);
      exe_src_mode_o   : out std_logic_vector(1 downto 0);
      exe_src_imm_o    : out std_logic;
      exe_dst_addr_o   : out std_logic_vector(3 downto 0);
      exe_dst_val_o    : out std_logic_vector(15 downto 0);
      exe_dst_mode_o   : out std_logic_vector(1 downto 0);
      exe_dst_imm_o    : out std_logic
   );
end entity decode;

architecture synthesis of decode is

   ------------------------------------------------------------
   -- Instruction format decoding
   ------------------------------------------------------------

   constant C_HAS_SRC_OPERAND : std_logic_vector(15 downto 0) := (
      C_OPCODE_CTRL => '0',
      others        => '1');

   constant C_HAS_DST_OPERAND : std_logic_vector(15 downto 0) := (
      C_OPCODE_JMP  => '0',
      others        => '1');

   constant C_READS_FROM_DST : std_logic_vector(15 downto 0) := (
      C_OPCODE_MOVE => '0',
      C_OPCODE_SWAP => '0',
      C_OPCODE_NOT  => '0',
      C_OPCODE_CTRL => '0',
      C_OPCODE_JMP  => '0',
      others        => '1');

   constant C_WRITES_TO_DST : std_logic_vector(15 downto 0) := (
      C_OPCODE_CMP  => '0',
      C_OPCODE_CTRL => '0',
      C_OPCODE_JMP  => '0',
      others        => '1');


   signal has_src_operand : std_logic;
   signal has_dst_operand : std_logic;
   signal reads_from_dst  : std_logic;
   signal writes_to_dst   : std_logic;
   signal src_memory      : std_logic;
   signal dst_memory      : std_logic;
   signal immediate_src   : std_logic;
   signal immediate_dst   : std_logic;

   -- microcode address bitmap:
   signal microcode_addr  : std_logic_vector(3 downto 0);
   signal microcode_value : std_logic_vector(23 downto 0);

begin

   ------------------------------------------------------------
   -- Instruction format decoding
   ------------------------------------------------------------

   has_src_operand <= C_HAS_SRC_OPERAND(to_integer(fetch_data_i(R_OPCODE)));
   has_dst_operand <= C_HAS_DST_OPERAND(to_integer(fetch_data_i(R_OPCODE)));
   reads_from_dst  <= C_READS_FROM_DST (to_integer(fetch_data_i(R_OPCODE)));
   writes_to_dst   <= C_WRITES_TO_DST  (to_integer(fetch_data_i(R_OPCODE)));
   src_memory      <= '0' when fetch_data_i(R_SRC_MODE) = C_MODE_REG else has_src_operand;
   dst_memory      <= '0' when fetch_data_i(R_DST_MODE) = C_MODE_REG else has_dst_operand;

   -- Special case when src = @PC++
   immediate_src <= has_src_operand when
                    fetch_data_i(R_SRC_REG)  = C_REG_PC and
                    fetch_data_i(R_SRC_MODE) = C_MODE_POST
               else '0';

   -- Special case when dst = @PC++
   immediate_dst <= has_dst_operand when
                    fetch_data_i(R_DST_REG)  = C_REG_PC and
                    fetch_data_i(R_DST_MODE) = C_MODE_POST
               else '0';


   ------------------------------------------------------------
   -- Back-pressure to Fetch module
   ------------------------------------------------------------

   fetch_double_o <= immediate_src or immediate_dst;
   fetch_ready_o <= '0' when fetch_double_o and not fetch_double_i else -- Wait for immediate value
                    exe_ready_i;


   microcode_addr(C_READ_DST)  <= reads_from_dst;
   microcode_addr(C_WRITE_DST) <= writes_to_dst;
   microcode_addr(C_MEM_SRC)   <= src_memory;
   microcode_addr(C_MEM_DST)   <= dst_memory;

   i_microcode : entity work.microcode
      port map (
         addr_i  => microcode_addr,
         value_o => microcode_value
      ); -- i_microcode


   ------------------------------------------------------------
   -- Generate combinatorial output values
   ------------------------------------------------------------

   reg_src_addr_o <= fetch_data_i(R_SRC_REG);
   reg_dst_addr_o <= fetch_data_i(R_DST_REG);

   exe_src_val_o  <= reg_src_val_i; -- One clock cycle after reg_src_addr_o
   exe_dst_val_o  <= reg_dst_val_i; -- One clock cycle after reg_dst_addr_o


   ------------------------------------------------------------
   -- Generate registered output values
   ------------------------------------------------------------

   p_output2exe : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if exe_ready_i = '1' then
            exe_valid_o <= '0';
         end if;

         exe_valid_o      <= fetch_valid_i and fetch_ready_o;
         exe_microcodes_o <= microcode_value;
         exe_immediate_o  <= fetch_data_i(R_IMMEDIATE);
         exe_oper_o       <= fetch_data_i(R_OPCODE);
         exe_ctrl_o       <= fetch_data_i(R_CTRL_CMD);
         exe_src_addr_o   <= reg_src_addr_o;
         exe_src_mode_o   <= fetch_data_i(R_SRC_MODE);
         exe_src_imm_o    <= immediate_src;
         exe_dst_addr_o   <= reg_dst_addr_o;
         exe_dst_mode_o   <= fetch_data_i(R_DST_MODE);
         exe_dst_imm_o    <= immediate_dst;

         if rst_i = '1' then
            exe_valid_o <= '0';
         end if;
      end if;
   end process p_output2exe;

end architecture synthesis;

