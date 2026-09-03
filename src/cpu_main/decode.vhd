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

      -- Early redirect to FETCH, for an unconditional branch with an immediate
      -- target. See "Early redirect" below.
      early_valid_o  : out std_logic;                     -- combinatorial
      early_addr_o   : out std_logic_vector(15 downto 0); -- combinatorial

      -- Register file. Value arrives on the next clock cycle
      reg_rd_en_o    : out std_logic;
      reg_src_addr_o : out std_logic_vector(3 downto 0);  -- combinatorial
      reg_dst_addr_o : out std_logic_vector(3 downto 0);  -- combinatorial
      reg_src_val_i  : in  std_logic_vector(15 downto 0);
      reg_dst_val_i  : in  std_logic_vector(15 downto 0);
      reg_r14_i      : in  std_logic_vector(15 downto 0);

      -- Register bank switch. See "Register bank switch" in write.vhd.
      bank_switch_i  : in  std_logic;
      bank_stale_o   : out std_logic;                     -- combinatorial

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

-- Deliberate compact tables: each maps an opcode straight to a single bit,
-- with "others" as the fall-through. vsg's constant_012 wants every
-- association reindented to the open-paren column (66+ spaces deep here).
-- vsg_off constant_012 constant_400 element_association_100
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
-- vsg_on constant_012 constant_400 element_association_100


   signal has_src_operand : std_logic; -- Does the instruction have a source operand?
   signal has_dst_operand : std_logic; -- Does the instruction have a destination operand?
   signal immediate_src   : std_logic; -- Is the source operand an immediate value, i.e. @PC++?
   signal immediate_dst   : std_logic; -- Is the destination operand an immediate value, i.e. @PC++?
   signal reads_from_dst  : std_logic; -- Does instruction read from destination operand?
   signal writes_to_dst   : std_logic; -- Does instruction write to destination operand?
   signal src_memory      : std_logic; -- Does source operand involve memory?
   signal dst_memory      : std_logic; -- Does destination operand involve memory?

   -- Does the instruction consume a value read out of the banked registers?
   signal uses_bank   : std_logic; -- The instruction at this stage's input
   signal uses_bank_d : std_logic; -- The instruction in the output register
   signal is_crb      : std_logic; -- Is the instruction at the input INCRB/DECRB?

   -- Is the instruction at the input an unconditional branch with an immediate
   -- target, i.e. one whose redirect this stage can issue itself?
   signal early_jmp : std_logic;

   -- microcode address bitmap:
   signal microcode_addr  : std_logic_vector(3 downto 0);
   signal microcode_value : std_logic_vector(35 downto 0);

begin

   ------------------------------------------------------------
   -- Back-pressure to Fetch module
   ------------------------------------------------------------

   fetch_double_o <= immediate_src or immediate_dst;
   fetch_ready_o  <= '0' when fetch_double_o and not fetch_double_i else -- Wait for immediate value
                     '0' when bank_switch_i and uses_bank           else -- Wait for the new bank
                     prep_ready_i;


   ------------------------------------------------------------
   -- Generate combinatorial output values
   ------------------------------------------------------------

   reg_rd_en_o    <= prep_ready_i; -- Read when next stage is ready to process data.
   reg_src_addr_o <= fetch_data_i(R_SRC_REG);
   reg_dst_addr_o <= to_stdlogicvector(C_REG_SP, 4) when fetch_data_i(R_OPCODE) = C_OPCODE_JMP else
                     fetch_data_i(R_DST_REG);

   prep_stage_o.src_val <= reg_src_val_i; -- One clock cycle after reg_src_addr_o
   prep_stage_o.dst_val <= reg_dst_val_i; -- One clock cycle after reg_dst_addr_o
   prep_stage_o.r14     <= reg_r14_i;


   ------------------------------------------------------------
   -- Instruction format decoding
   ------------------------------------------------------------

   has_src_operand <= C_HAS_SRC_OPERAND(to_integer(fetch_data_i(R_OPCODE)));
   has_dst_operand <= C_HAS_DST_OPERAND(to_integer(fetch_data_i(R_OPCODE)));


   -- Special case when src = @PC++. The two conditions of each chain align
   -- their `=` signs, which whitespace_100 would compact away.
-- vsg_off whitespace_100
   immediate_src <= has_src_operand when
                    fetch_data_i(R_SRC_REG)  = C_REG_PC and
                    fetch_data_i(R_SRC_MODE) = C_MODE_POST else
                    '0';

   -- Special case when dst = @PC++
   immediate_dst <= has_dst_operand when
                    fetch_data_i(R_DST_REG)  = C_REG_PC and
                    fetch_data_i(R_DST_MODE) = C_MODE_POST else
                    '0';
-- vsg_on whitespace_100

   reads_from_dst <= C_READS_FROM_DST (to_integer(fetch_data_i(R_OPCODE)));
   writes_to_dst  <= C_WRITES_TO_DST  (to_integer(fetch_data_i(R_OPCODE)));
   src_memory     <= '0' when (fetch_data_i(R_SRC_MODE) = C_MODE_REG or immediate_src = '1') else has_src_operand;
   dst_memory     <= '0' when (fetch_data_i(R_DST_MODE) = C_MODE_REG or immediate_dst = '1') else has_dst_operand;


   ------------------------------------------------------------
   -- Register bank switch
   ------------------------------------------------------------

   -- Does this instruction consume a value that came out of the BANKED half of
   -- the register file, R0-R7? Only such a value goes stale when INCRB/DECRB
   -- moves the bank underneath an already-issued read; see the long comment in
   -- write.vhd. Writing R0-R7 is not affected -- the write leaves this stage
   -- as a register NUMBER and is applied against whatever bank is current when
   -- it retires, which is the new one, i.e. the right one.
   --
   -- Both operands are always read from the register file. What differs is
   -- whether the value read is used:
   --
   --   * the source value always is, when the instruction has a source operand
   --     -- as an ALU input in register mode, as an address in every other;
   --   * the destination value only when the instruction reads from the
   --     destination, or the destination lives in memory and the value is
   --     therefore a pointer. "MOVE R8, R0" uses neither, which is the whole
   --     point of this signal: it is the standard way to pass an argument into
   --     a freshly entered register bank, and it is not a hazard.
   --
   -- reads_from_dst is '0' for exactly those opcodes that have no destination
   -- operand at all (JMP) or ignore its previous value (MOVE/SWAP/NOT/CTRL --
   -- their flags come from the result alone, see alu_flags.vhd), so it needs
   -- no separate has_dst_operand term. reg_dst_addr_o rather than the raw
   -- instruction field, because JMP substitutes R13 there.
   uses_bank <= (has_src_operand and not reg_src_addr_o(3)) or
                ((reads_from_dst or dst_memory) and not reg_dst_addr_o(3));

   -- Is this a bank switch? Decoded here and carried down the pipeline in
   -- t_stage rather than re-derived from prep_stage_i.inst in WRITE: it lands
   -- on fetch_valid_o, and that net cannot afford a ten-bit compare in front
   -- of it. See "Register bank switch" in write.vhd.
   is_crb <= '1' when fetch_data_i(R_OPCODE) = C_OPCODE_CTRL and
                      (fetch_data_i(R_CTRL_CMD) = C_CTRL_INCRB or
                       fetch_data_i(R_CTRL_CMD) = C_CTRL_DECRB) else
             '0';

   -- The instruction in this stage's output register read its operands one
   -- cycle before it got here, i.e. strictly before the bank switch now
   -- retiring in WRITE could reach the register file. If it uses a banked
   -- value, that value is from the outgoing bank and only a flush can undo it.
   bank_stale_o <= prep_valid_o and uses_bank_d;


   ------------------------------------------------------------
   -- Early redirect
   ------------------------------------------------------------

   -- A branch is normally resolved in WRITE, two stages further on, and the
   -- redirect it sends to FETCH costs four cycles: one to register the new PC,
   -- one for the instruction memory's read latency, one in the Icache, and one
   -- because the pipeline behind it is empty. For ONE class of branch none of
   -- that has to wait, because everything the redirect needs is already here:
   --
   --   * "taken" is unconditional -- the condition field selects SR bit 0,
   --     which reads as 1 always, and is not negated. No flags, so no
   --     dependency on instructions still in flight ahead of this one.
   --   * the target is an immediate, so it is the word FETCH has already
   --     supplied alongside the instruction. No register read, no memory read.
   --
   -- That is "ABRA/ASUB/RBRA/RSUB <label>, 1", which is the bulk of real QNICE
   -- code: RSUB is every subroutine call and RBRA ..., 1 every unconditional
   -- jump. Issuing the redirect here rather than in WRITE cuts the penalty from
   -- four cycles to two, and to one for ASUB/RSUB, whose second micro-op keeps
   -- the branch in this stage's output register for an extra cycle and so
   -- overlaps one more cycle of the refill.
   --
   -- WHAT THE EARLY REDIRECT MUST NOT FLUSH. It resets FETCH and the Icache
   -- only, never this stage or PREPARE. The branch is in this stage's output
   -- register by the end of the cycle and everything downstream of it is
   -- OLDER, so the only wrong-path instructions in the machine are the ones
   -- FETCH and the Icache are holding. That is also why the Icache needs a
   -- soft flush rather than its ordinary reset -- see contract (d) in
   -- icache.vhd; the ordinary one would withdraw the very handshake that
   -- raises this signal.
   --
   -- WRITE must then NOT redirect again when the branch retires, or it would
   -- discard the correctly fetched target. prep_stage_o.early_jmp carries that
   -- down the pipeline; see "Writes to R15" in write.vhd.
   --
   -- prep_ready_i rather than fetch_ready_o, although the condition being
   -- tested is "this stage accepts the instruction this cycle" and that is
   -- fetch_valid_i and fetch_ready_o. The two are EQUAL for this instruction
   -- class: fetch_ready_o's first term needs fetch_double_o and not
   -- fetch_double_i, and fetch_double_i is required below; its second needs
   -- uses_bank, which is '0' here because the source register is R15 and JMP
   -- has no destination operand. Using fetch_ready_o instead would put the
   -- Icache's own output data in front of FETCH's address register, through
   -- this stage's whole ready cone -- the longest path in the design after the
   -- ALU. prep_ready_i comes from PREPARE's registers and the Memory module,
   -- so both legs of the AND below start at a flip-flop.
   early_jmp <= '1' when fetch_data_i(R_OPCODE) = C_OPCODE_JMP and
                         fetch_data_i(R_JMP_COND) = "000" and
                         fetch_data_i(R_JMP_NEG) = '0' and
                         immediate_src = '1' else
                '0';

   -- fetch_double_i is what makes fetch_data_i(R_IMMEDIATE) meaningful: it says
   -- the Icache is offering the second word, not just the instruction. It is
   -- implied by the handshake for this class (fetch_ready_o holds the stage off
   -- until the operand arrives), but the target address is built from that word
   -- below, so it is named explicitly rather than left to be inferred.
   early_valid_o <= early_jmp and fetch_valid_i and fetch_double_i and prep_ready_i;

   -- The same target p_output computes for prep_stage_o.immediate, which is
   -- where the branch would otherwise have picked it up two stages later: an
   -- absolute mode branches to the operand, a relative one to the operand plus
   -- the address of the word after it.
   early_addr_o <= fetch_data_i(R_IMMEDIATE) + fetch_addr_i + 2
                       when fetch_data_i(R_JMP_MODE) = C_JMP_RBRA or
                            fetch_data_i(R_JMP_MODE) = C_JMP_RSUB else
                    fetch_data_i(R_IMMEDIATE);


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
         if prep_ready_i = '1' then
            prep_valid_o <= '0';
         end if;

         -- Ready to send new data to next stage
         if fetch_valid_i and fetch_ready_o then
            prep_valid_o            <= '1';
            prep_stage_o.microcodes <= microcode_value;
            prep_stage_o.addr       <= fetch_addr_i;
            prep_stage_o.immediate  <= fetch_data_i(R_IMMEDIATE);
            prep_stage_o.inst       <= fetch_data_i(R_INSTRUCTION);
            prep_stage_o.src_addr   <= reg_src_addr_o;
            prep_stage_o.src_mode   <= fetch_data_i(R_SRC_MODE);
            prep_stage_o.src_imm    <= immediate_src;
            prep_stage_o.dst_addr   <= reg_dst_addr_o;
            prep_stage_o.dst_mode   <= fetch_data_i(R_DST_MODE);
            prep_stage_o.dst_imm    <= immediate_dst;
            prep_stage_o.res_reg    <= reg_dst_addr_o;
            prep_stage_o.is_crb     <= is_crb;
            prep_stage_o.early_jmp  <= early_jmp;
            uses_bank_d             <= uses_bank;

            -- Treat jumps as a special case
            if fetch_data_i(R_OPCODE) = C_OPCODE_JMP then
               -- Write new address to PC
               prep_stage_o.res_reg <= to_stdlogicvector(C_REG_PC, 4);
               if src_memory = '0' then
                  prep_stage_o.microcodes <= std_logic_vector'(
                                      C_VAL_LAST &
                                      C_VAL_LAST &
                                      (C_VAL_LAST or C_VAL_REG_WRITE));
               else
                  prep_stage_o.microcodes <= std_logic_vector'(
                                      C_VAL_LAST &
                                      (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_REG_WRITE) &
                                      (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC));
               end if;

               -- Subroutine call
               if fetch_data_i(R_JMP_MODE) = C_JMP_ASUB or fetch_data_i(R_JMP_MODE) = C_JMP_RSUB then
                  -- Artifically introduce a MOVE R15, @--R13
                  prep_stage_o.dst_addr <= to_stdlogicvector(C_REG_SP, 4);
                  prep_stage_o.dst_mode <= to_stdlogicvector(C_MODE_PRE, 2);
                  if src_memory = '0' then
                     prep_stage_o.microcodes <= std_logic_vector'(
                                         C_VAL_LAST &
                                         (C_VAL_LAST or C_VAL_REG_WRITE) &
                                         (C_VAL_REG_MOD_DST or C_VAL_MEM_WRITE));
                  else
                     prep_stage_o.microcodes <= std_logic_vector'(
                                         (C_VAL_LAST or C_VAL_MEM_WAIT_SRC or C_VAL_REG_WRITE) &
                                         (C_VAL_MEM_READ_SRC or C_VAL_REG_MOD_SRC) &
                                         (C_VAL_REG_MOD_DST or C_VAL_MEM_WRITE));
                  end if;
               end if;

               -- Relative jump
               if immediate_src = '1' and
                  (fetch_data_i(R_JMP_MODE) = C_JMP_RBRA or fetch_data_i(R_JMP_MODE) = C_JMP_RSUB) then
                  prep_stage_o.immediate <= fetch_data_i(R_IMMEDIATE) + fetch_addr_i + 2;
               end if;
            end if;
         end if;

         if rst_i = '1' then
            prep_valid_o <= '0';
         end if;
      end if;
   end process p_output;

end architecture synthesis;

