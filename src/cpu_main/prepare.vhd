library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.cpu_constants.all;

entity prepare is
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;

      -- From the SEQUENCER (instantiated alongside this module in
      -- cpu_main.vhd): one beat per micro-operation, where DECODE emits one
      -- beat per instruction.
      seq_valid_i     : in  std_logic;
      seq_ready_o     : out std_logic;
      seq_stage_i     : in  t_stage;

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
      wr_stage_o      : out t_stage
   );
end entity prepare;

architecture synthesis of prepare is

   signal wait_for_mem_req : std_logic;
   signal wait_for_mem_src : std_logic;
   signal wait_for_mem_dst : std_logic;

   signal alu_oper    : std_logic_vector(3 downto 0);
   signal alu_ctrl    : std_logic_vector(5 downto 0);
   signal alu_flags   : std_logic_vector(15 downto 0);
   signal alu_src_val : std_logic_vector(15 downto 0);
   signal alu_dst_val : std_logic_vector(15 downto 0);

   -- Operand register values with the Program Counter substituted for R15.
   signal src_val_pc : std_logic_vector(15 downto 0);
   signal dst_val_pc : std_logic_vector(15 downto 0);

begin

   ------------------------------------------------------------
   -- Get values read from memory
   ------------------------------------------------------------

   wait_for_mem_req <= seq_valid_i and or(seq_stage_i.microcodes(2 downto 0)) and not wr_ready_i;
   wait_for_mem_src <= seq_valid_i and seq_stage_i.microcodes(C_MEM_WAIT_SRC) and
                       not mem_src_valid_i;
   wait_for_mem_dst <= seq_valid_i and seq_stage_i.microcodes(C_MEM_WAIT_DST) and
                       not mem_dst_valid_i;


   ------------------------------------------------------------
   -- Back-pressure
   ------------------------------------------------------------

   mem_src_ready_o <= seq_valid_i and seq_stage_i.microcodes(C_MEM_WAIT_SRC) and
                      not wait_for_mem_dst;
   mem_dst_ready_o <= seq_valid_i and seq_stage_i.microcodes(C_MEM_WAIT_DST) and
                      not wait_for_mem_src;
   seq_ready_o     <= wr_ready_i and not (wait_for_mem_req or wait_for_mem_src or wait_for_mem_dst);


   ------------------------------------------------------------
   -- ALU
   ------------------------------------------------------------

   alu_oper  <= seq_stage_i.inst(R_OPCODE);
   alu_ctrl  <= seq_stage_i.inst(R_CTRL_CMD);
   alu_flags <= seq_stage_i.r14;
   -- Reading R15 as an ordinary operand.
   --
   -- The working Program Counter lives in the FETCH stage; the register file's
   -- R15 copy is only written when an instruction actually targets R15, so it
   -- is stale during sequential execution and must never be used as an operand
   -- value. src_val_pc/dst_val_pc substitute the real PC, and are then used for
   -- BOTH the ALU inputs below and the copies latched into the stage record --
   -- the latter matters because the WRITE stage derives the memory address and
   -- the pre/post-increment write-back from src_val/dst_val, so @R15, @--R15
   -- and R15 as a plain operand all have to agree.
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
                 seq_stage_i.src_val;
   dst_val_pc <= seq_stage_i.addr+2 when seq_stage_i.dst_addr = C_REG_PC and
                                         seq_stage_i.src_imm = '1'       else
                 seq_stage_i.addr+1 when seq_stage_i.dst_addr = C_REG_PC else
                 seq_stage_i.dst_val;

   alu_src_val <= seq_stage_i.immediate when seq_stage_i.src_imm = '1'                      else
                  mem_src_data_i        when seq_stage_i.microcodes(C_MEM_WAIT_SRC) = '1' else
                  src_val_pc;
   alu_dst_val <= seq_stage_i.immediate when seq_stage_i.dst_imm = '1'                      else
                  mem_dst_data_i        when seq_stage_i.microcodes(C_MEM_WAIT_DST) = '1' else
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
            wr_valid_o             <= seq_valid_i;
            wr_stage_o             <= seq_stage_i;
            wr_stage_o.src_val     <= src_val_pc;
            wr_stage_o.dst_val     <= dst_val_pc;
            wr_stage_o.alu_oper    <= alu_oper;
            wr_stage_o.alu_ctrl    <= alu_ctrl;
            wr_stage_o.alu_flags   <= alu_flags;
            wr_stage_o.alu_src_val <= alu_src_val;
            wr_stage_o.alu_dst_val <= alu_dst_val;
         end if;

         if rst_i = '1' then
            wr_valid_o <= '0';
         end if;
      end if;
   end process p_output;

end architecture synthesis;

