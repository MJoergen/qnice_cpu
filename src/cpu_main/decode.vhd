library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity decode is
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      -- From Instruction fetch
      fetch_valid_i  : in  std_logic;
      fetch_ready_o  : out std_logic;                     -- combinatorial
      fetch_double_i : in  std_logic;
      fetch_addr_i   : in  std_logic_vector(15 downto 0);
      fetch_data_i   : in  std_logic_vector(31 downto 0);
      fetch_double_o : out std_logic;                     -- combinatorial

      -- Register file. Value arrives on the next clock cycle
      reg_rd_en_o    : out std_logic;
      reg_src_addr_o : out std_logic_vector(3 downto 0);  -- combinatorial
      reg_dst_addr_o : out std_logic_vector(3 downto 0);  -- combinatorial
      reg_src_val_i  : in  std_logic_vector(15 downto 0);
      reg_dst_val_i  : in  std_logic_vector(15 downto 0);
      reg_r14_i      : in  std_logic_vector(15 downto 0);

      -- To PREPARE
      prep_valid_o   : out std_logic;
      prep_ready_i   : in  std_logic;
      prep_stage_o   : out t_stage
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


   signal has_src_operand : std_logic; -- Does the instruction have a source operand?
   signal has_dst_operand : std_logic; -- Does the instruction have a destination operand?
   signal immediate_src   : std_logic; -- Is the source operand an immediate value, i.e. @PC++?
   signal immediate_dst   : std_logic; -- Is the destination operand an immediate value, i.e. @PC++?
   signal reads_from_dst  : std_logic; -- Does instruction read from destination operand?
   signal writes_to_dst   : std_logic; -- Does instruction write to destination operand?
   signal src_memory      : std_logic; -- Does source operand involve memory?
   signal dst_memory      : std_logic; -- Does destination operand involve memory?

   -- microcode address bitmap:
   signal microcode_addr  : std_logic_vector(3 downto 0);
   signal microcode_value : std_logic_vector(35 downto 0);

   signal seq_valid : std_logic;
   signal seq_ready : std_logic;
   signal seq_stage : t_stage;

begin

   ------------------------------------------------------------
   -- Back-pressure to Fetch module
   ------------------------------------------------------------

   fetch_double_o <= immediate_src or immediate_dst;
   fetch_ready_o <= '0' when fetch_double_o and not fetch_double_i else -- Wait for immediate value
                    seq_ready;


   ------------------------------------------------------------
   -- Generate combinatorial output values
   ------------------------------------------------------------

   reg_rd_en_o    <= seq_ready; -- Read when next stage is ready to process data.
   reg_src_addr_o <= fetch_data_i(R_SRC_REG);
   reg_dst_addr_o <= to_stdlogicvector(C_REG_SP, 4) when fetch_data_i(R_OPCODE) = C_OPCODE_JMP else
                     fetch_data_i(R_DST_REG);

   seq_stage.src_val <= reg_src_val_i; -- One clock cycle after reg_src_addr_o
   seq_stage.dst_val <= reg_dst_val_i; -- One clock cycle after reg_dst_addr_o
   seq_stage.r14     <= reg_r14_i;


   ------------------------------------------------------------
   -- Instruction format decoding
   ------------------------------------------------------------

   has_src_operand <= C_HAS_SRC_OPERAND(to_integer(fetch_data_i(R_OPCODE)));
   has_dst_operand <= C_HAS_DST_OPERAND(to_integer(fetch_data_i(R_OPCODE)));

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

   reads_from_dst  <= C_READS_FROM_DST (to_integer(fetch_data_i(R_OPCODE)));
   writes_to_dst   <= C_WRITES_TO_DST  (to_integer(fetch_data_i(R_OPCODE)));
   src_memory      <= '0' when (fetch_data_i(R_SRC_MODE) = C_MODE_REG or immediate_src = '1') else has_src_operand;
   dst_memory      <= '0' when (fetch_data_i(R_DST_MODE) = C_MODE_REG or immediate_dst = '1') else has_dst_operand;


   ------------------------------------------------------------
   -- Microcode generation
   ------------------------------------------------------------

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
   -- Generate registered output values
   ------------------------------------------------------------

   p_output : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- Next stage has consumed output data
         if seq_ready = '1' then
            seq_valid <= '0';
         end if;

         -- Ready to send new data to next stage
         if fetch_valid_i and fetch_ready_o then
            seq_valid <= '1';
            seq_stage.microcodes <= microcode_value;
            seq_stage.addr       <= fetch_addr_i;
            seq_stage.immediate  <= fetch_data_i(R_IMMEDIATE);
            seq_stage.inst       <= fetch_data_i(R_INSTRUCTION);
            seq_stage.src_addr   <= reg_src_addr_o;
            seq_stage.src_mode   <= fetch_data_i(R_SRC_MODE);
            seq_stage.src_imm    <= immediate_src;
            seq_stage.dst_addr   <= reg_dst_addr_o;
            seq_stage.dst_mode   <= fetch_data_i(R_DST_MODE);
            seq_stage.dst_imm    <= immediate_dst;
            seq_stage.res_reg    <= reg_dst_addr_o;

            -- Treat jumps as a special case
            if fetch_data_i(R_OPCODE) = C_OPCODE_JMP then
               -- Write new address to PC
               seq_stage.res_reg <= to_stdlogicvector(C_REG_PC, 4);
               if src_memory = '0' then
                  seq_stage.microcodes <= std_logic_vector'(
                                      C_VAL_LAST &
                                      C_VAL_LAST &
                                      (C_VAL_LAST or C_VAL_REG_WRITE));
               else
                  seq_stage.microcodes <= std_logic_vector'(
                                      C_VAL_LAST &
                                      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_REG_WRITE) &
                                      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC));
               end if;

               -- Subroutine call
               if fetch_data_i(R_JMP_MODE) = C_JMP_ASUB or fetch_data_i(R_JMP_MODE) = C_JMP_RSUB then
                  -- Artifically introduce a MOVE R15, @--R13
                  seq_stage.dst_addr <= to_stdlogicvector(C_REG_SP, 4);
                  seq_stage.dst_mode <= to_stdlogicvector(C_MODE_PRE, 2);
                  if src_memory = '0' then
                     seq_stage.microcodes <= std_logic_vector'(
                                         C_VAL_LAST &
                                         (C_VAL_LAST or C_VAL_REG_WRITE) &
                                         (C_VAL_REG_MOD_DST or C_VAL_MEM_WRITE));
                  else
                     seq_stage.microcodes <= std_logic_vector'(
                                         (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_REG_WRITE) &
                                         (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC) &
                                         (C_VAL_REG_MOD_DST or C_VAL_MEM_WRITE));
                  end if;
               end if;

               -- Relative jump
               if immediate_src = '1' and
                  (fetch_data_i(R_JMP_MODE) = C_JMP_RBRA or fetch_data_i(R_JMP_MODE) = C_JMP_RSUB) then
                  seq_stage.immediate <= fetch_data_i(R_IMMEDIATE) + fetch_addr_i + 2;
               end if;
            end if;
         end if;

         if rst_i = '1' then
            seq_valid <= '0';
         end if;
      end if;
   end process p_output;


   ------------------------------------------------------------
   -- Sequencer
   ------------------------------------------------------------

   i_sequencer : entity work.sequencer
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         dec_valid_i  => seq_valid,
         dec_ready_o  => seq_ready,
         dec_stage_i  => seq_stage,
         prep_valid_o => prep_valid_o,
         prep_ready_i => prep_ready_i,
         prep_stage_o => prep_stage_o
      ); -- i_sequencer

end architecture synthesis;

