library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.cpu_constants.all;

entity prepare is
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;

      -- From SEQUENCER (instantiated alongside this module in cpu_main.vhd):
      -- one beat per micro-operation, where DECODE emits one beat per
      -- instruction.
      seq_valid_i     : in  std_logic;
      seq_ready_o     : out std_logic;
      seq_stage_i     : in  t_seq2prep;

      -- MEMORY
      mem_src_valid_i : in  std_logic;
      mem_src_ready_o : out std_logic;                        -- combinatorial
      mem_src_data_i  : in  std_logic_vector(15 downto 0);
      mem_dst_valid_i : in  std_logic;
      mem_dst_ready_o : out std_logic;                        -- combinatorial
      mem_dst_data_i  : in  std_logic_vector(15 downto 0);

      -- To WRITE
      wr_valid_o      : out std_logic;
      wr_ready_i      : in  std_logic;
      wr_stage_o      : out t_prep2wr
   );
end entity prepare;

architecture synthesis of prepare is

   signal wait_for_mem_req : std_logic;
   signal wait_for_mem_src : std_logic;
   signal wait_for_mem_dst : std_logic;

   signal alu_oper    : std_logic_vector(3 downto 0);
   signal alu_ctrl    : std_logic_vector(5 downto 0);
   signal alu_src_val : std_logic_vector(15 downto 0);
   signal alu_dst_val : std_logic_vector(15 downto 0);

   -- Operand register values with the Program Counter substituted for R15.
   signal src_val_pc : std_logic_vector(15 downto 0);
   signal dst_val_pc : std_logic_vector(15 downto 0);

begin

   ------------------------------------------------------------
   -- Get values read from memory
   ------------------------------------------------------------

   wait_for_mem_req <= seq_valid_i and or(seq_stage_i.microcode(2 downto 0)) and not wr_ready_i;
   wait_for_mem_src <= seq_valid_i and seq_stage_i.microcode(C_MEM_WAIT_SRC) and
                       not mem_src_valid_i;
   wait_for_mem_dst <= seq_valid_i and seq_stage_i.microcode(C_MEM_WAIT_DST) and
                       not mem_dst_valid_i;


   ------------------------------------------------------------
   -- Back-pressure
   ------------------------------------------------------------

   mem_src_ready_o <= seq_valid_i and seq_stage_i.microcode(C_MEM_WAIT_SRC) and
                      not wait_for_mem_dst;
   mem_dst_ready_o <= seq_valid_i and seq_stage_i.microcode(C_MEM_WAIT_DST) and
                      not wait_for_mem_src;
   seq_ready_o     <= wr_ready_i and not (wait_for_mem_req or wait_for_mem_src or wait_for_mem_dst);


   ------------------------------------------------------------
   -- ALU
   ------------------------------------------------------------

   alu_oper <= seq_stage_i.inst(R_OPCODE);
   alu_ctrl <= seq_stage_i.inst(R_CTRL_CMD);
   -- Reading R15 as an ordinary operand.
   --
   -- The working Program Counter lives in FETCH; the register file's R15 copy
   -- is only written when an instruction actually targets R15, so it is stale
   -- during sequential execution and must never be used as an operand value.
   -- src_val_pc/dst_val_pc substitute the real PC, and are then used for BOTH
   -- the ALU inputs below and the copies latched into the stage record -- the
   -- latter matters because WRITE derives the memory address and the
   -- pre/post-increment write-back from src_val_pc/dst_val_pc, so @R15,
   -- @--R15, and R15 as a plain operand all have to agree.
   --
   -- The value is the address of the next word to be fetched at the point the
   -- operand is read, matching the reference implementation (qnice.c advances
   -- PC immediately after the instruction fetch, then reads both operands
   -- through the same read_register(PC)):
   --
   --   * source R15      -> addr+1 always. If the instruction carries an
   --                        immediate it belongs to the destination, and is
   --                        fetched only after the source has been read.
   --   * destination R15 -> addr+2 when the source was an immediate (that
   --                        fetch has already advanced the PC), else addr+1.
   --
   -- This is the value of the register itself, so it applies in every
   -- addressing mode. @R15++ never reaches here: DECODE flags it as an
   -- immediate and FETCH supplies the value inline.
   src_val_pc <= seq_stage_i.addr+1 when seq_stage_i.src_addr = C_REG_PC else
                 seq_stage_i.src_reg_val;
   dst_val_pc <= seq_stage_i.addr+2 when seq_stage_i.dst_addr = C_REG_PC and
                                         seq_stage_i.src_imm = '1'       else
                 seq_stage_i.addr+1 when seq_stage_i.dst_addr = C_REG_PC else
                 seq_stage_i.dst_reg_val;

   alu_src_val <= seq_stage_i.immediate when seq_stage_i.src_imm = '1'                   else
                  mem_src_data_i        when seq_stage_i.microcode(C_MEM_WAIT_SRC) = '1' else
                  src_val_pc;
   alu_dst_val <= seq_stage_i.immediate when seq_stage_i.dst_imm = '1'                   else
                  mem_dst_data_i        when seq_stage_i.microcode(C_MEM_WAIT_DST) = '1' else
                  dst_val_pc;


   ------------------------------------------------------------
   -- Output registers
   ------------------------------------------------------------

   p_output : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- Next stage has consumed output data
         if wr_ready_i = '1' then
            wr_valid_o <= '0';
         end if;

         -- Ready to send new data to next stage
         if seq_valid_i and seq_ready_o then
            wr_valid_o <= seq_valid_i;

            -- Forwarded unchanged. One assignment per element: the input and
            -- output records are different types, so that this stage cannot
            -- hand on an operand value it has not resolved.
            wr_stage_o.microcode <= seq_stage_i.microcode;
            wr_stage_o.addr      <= seq_stage_i.addr;
            wr_stage_o.inst      <= seq_stage_i.inst;
            wr_stage_o.immediate <= seq_stage_i.immediate;
            wr_stage_o.src_addr  <= seq_stage_i.src_addr;
            wr_stage_o.src_mode  <= seq_stage_i.src_mode;
            wr_stage_o.src_imm   <= seq_stage_i.src_imm;
            wr_stage_o.dst_addr  <= seq_stage_i.dst_addr;
            wr_stage_o.dst_mode  <= seq_stage_i.dst_mode;
            wr_stage_o.dst_imm   <= seq_stage_i.dst_imm;
            wr_stage_o.res_reg   <= seq_stage_i.res_reg;
            wr_stage_o.is_crb    <= seq_stage_i.is_crb;
            wr_stage_o.early_jmp <= seq_stage_i.early_jmp;
            wr_stage_o.r14       <= seq_stage_i.r14;

            -- Resolved here. src_val_pc/dst_val_pc are the register values with
            -- the real Program Counter substituted for R15, which is why they
            -- do not carry the names they had on the way in.
            wr_stage_o.src_val_pc  <= src_val_pc;
            wr_stage_o.dst_val_pc  <= dst_val_pc;
            wr_stage_o.alu_oper    <= alu_oper;
            wr_stage_o.alu_ctrl    <= alu_ctrl;
            wr_stage_o.alu_src_val <= alu_src_val;
            wr_stage_o.alu_dst_val <= alu_dst_val;
         end if;

         if rst_i = '1' then
            wr_valid_o <= '0';
         end if;
      end if;
   end process p_output;

end architecture synthesis;

