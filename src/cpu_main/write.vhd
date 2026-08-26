library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.cpu_constants.all;

entity write is
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;

      -- From PREPARE
      prep_valid_i    : in  std_logic;
      prep_ready_o    : out std_logic;
      prep_stage_i    : in  t_stage;

      -- Memory
      mem_req_valid_o : out std_logic;                        -- combinatorial
      mem_req_ready_i : in  std_logic;
      mem_req_op_o    : out std_logic_vector(2 downto 0);     -- combinatorial
      mem_req_addr_o  : out std_logic_vector(15 downto 0);    -- combinatorial
      mem_req_data_o  : out std_logic_vector(15 downto 0);    -- combinatorial

      -- Register file
      reg_r14_we_o    : out std_logic;
      reg_r14_o       : out std_logic_vector(15 downto 0);
      reg_we_o        : out std_logic;
      reg_addr_o      : out std_logic_vector(3 downto 0);
      reg_val_o       : out std_logic_vector(15 downto 0);
      fetch_valid_o   : out std_logic;
      fetch_addr_o    : out std_logic_vector(15 downto 0);

      inst_done_o     : out std_logic;

      -- Asserted for one clock cycle when a HALT instruction retires.
      halt_o          : out std_logic                        -- combinatorial
   );
end entity write;

architecture synthesis of write is

   signal alu_res_val   : std_logic_vector(15 downto 0);
   signal alu_res_flags : std_logic_vector(15 downto 0);
   signal update_reg    : std_logic;

   signal mem_addr    : std_logic_vector(15 downto 0);
   signal mem_data    : std_logic_vector(15 downto 0);
   signal mem_valid   : std_logic;

   signal next_pc     : std_logic_vector(15 downto 0);
   signal wr_r15      : std_logic;
   signal is_crb      : std_logic;
   signal smc_delta   : std_logic_vector(15 downto 0);
   signal smc_hit     : std_logic;


begin

   prep_ready_o <= mem_req_ready_i when or(mem_req_op_o) = '1' else '1';

   -- NOTE: prep_stage_i.r14 is used directly, with no bypass of this stage's own
   -- Status Register writes. There used to be one (a p_bypass process holding a
   -- one-cycle-delayed copy of everything written to the Register module, and a
   -- priority mux in front of prep_stage_i.r14). It was removed as dead code: a
   -- probe on it never fired once in 8286 accepted beats of test/prog.asm, and
   -- removing it left every test program passing with the golden writes logs
   -- (test/*.writes.golden) byte-identical.
   --
   -- The reason is structural. registers.vhd forwards BOTH Status Register
   -- write ports combinationally onto sr_val_o; DECODE passes reg_r14_i through
   -- as a live, unregistered signal; and this stage only ever issues a register
   -- write on a cycle where PREPARE is simultaneously latching a fresh beat. So
   -- the value arriving here has already absorbed the write this stage made.


   ------------------------------------------------------------
   -- Instantiate ALU
   ------------------------------------------------------------

   i_alu : entity work.alu
      port map (
         clk_i           => clk_i,
         rst_i           => rst_i,
         alu_oper_i      => prep_stage_i.alu_oper,
         alu_ctrl_i      => prep_stage_i.alu_ctrl,
         alu_src_val_i   => prep_stage_i.alu_src_val,
         alu_dst_val_i   => prep_stage_i.alu_dst_val,
         alu_flags_i     => prep_stage_i.alu_flags,
         alu_res_val_o   => alu_res_val,
         alu_res_flags_o => alu_res_flags
      ); -- i_alu


-- pragma synthesis_off
   p_debug : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if inst_done_o = '1' then
            disassemble(prep_stage_i.addr, prep_stage_i.inst, prep_stage_i.immediate);
         end if;
      end if;
   end process p_debug;


   -- An unimplemented instruction must not execute silently.
   --
   -- DECODE classifies every CTRL instruction as no source operand, no
   -- destination operand, neither read from nor written to, so microcode_addr
   -- is 0 and the ROM returns entry 0 -- three bare C_VAL_LAST, i.e. a single
   -- micro-op that does nothing at all. alu_flags acts only on INCRB/DECRB and
   -- leaves the Status Register alone otherwise (its "when others => null").
   -- The result is that RTI, INT and EXC currently RETIRE AS NO-OPS, and the
   -- assembler emits them without complaint: "RTI" assembles to 0xE040 and
   -- executes as nothing whatsoever.
   --
   -- That is the worst behaviour to have while interrupts are being written,
   -- because a half-finished implementation looks like it works -- the
   -- instruction that should have failed instead does nothing, quietly, and the
   -- test program passes. Reserved opcode 0xD is the same story: alu_data has
   -- no case for it, so it falls through that mux's MOVE-like default and
   -- executes as a MOVE.
   --
   -- Simulation only, and deliberately so. QNICE defines no illegal-instruction
   -- exception, so there is nothing for synthesised hardware to do here that
   -- the ISA would sanction; this is a development aid, not a feature. As each
   -- instruction gains a real implementation, drop it from the list below.
   p_unimplemented : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if inst_done_o = '1' and rst_i = '0' then

            assert not (prep_stage_i.inst(R_OPCODE) = C_OPCODE_CTRL and
                        prep_stage_i.inst(R_CTRL_CMD) /= C_CTRL_HALT and
                        prep_stage_i.inst(R_CTRL_CMD) /= C_CTRL_INCRB and
                        prep_stage_i.inst(R_CTRL_CMD) /= C_CTRL_DECRB)
               report "UNIMPLEMENTED instruction at address 0x" &
                      to_hstring(prep_stage_i.addr) & ": control command " &
                      to_hstring(prep_stage_i.inst(R_CTRL_CMD)) & " (" &
                      ctrl_str(prep_stage_i.inst(R_CTRL_CMD)) & "). " &
                      "It is not decoded anywhere and would otherwise retire " &
                      "as a no-op."
               severity failure;

            assert prep_stage_i.inst(R_OPCODE) /= C_OPCODE_RES
               report "RESERVED opcode 0xD at address 0x" &
                      to_hstring(prep_stage_i.addr) & ". " &
                      "It has no ISA definition and would otherwise execute " &
                      "as a MOVE."
               severity failure;

         end if;
      end if;
   end process p_unimplemented;
-- pragma synthesis_on


   ------------------------------------------------------------
   -- Update register (combinatorial)
   ------------------------------------------------------------

   update_reg <= prep_stage_i.r14(to_integer(prep_stage_i.inst(R_JMP_COND))) xor prep_stage_i.inst(R_JMP_NEG)
                 when prep_stage_i.inst(R_OPCODE) = C_OPCODE_JMP
              else '1';

   p_reg : process (all)
   begin
      reg_addr_o <= (others => '0');
      reg_val_o  <= (others => '0');
      reg_we_o   <= '0';

      if prep_valid_i and prep_ready_o and update_reg then
         -- Handle pre- and post increment here.
         if prep_stage_i.microcodes(C_REG_MOD_SRC) = '1' and
            (prep_stage_i.src_mode = C_MODE_POST or prep_stage_i.src_mode = C_MODE_PRE) then
            reg_addr_o <= prep_stage_i.src_addr;
            if prep_stage_i.src_mode = C_MODE_POST then
               reg_val_o <= prep_stage_i.src_val + 1;
            else
               reg_val_o <= prep_stage_i.src_val - 1;
            end if;
            reg_we_o   <= '1';
         end if;

         if prep_stage_i.microcodes(C_REG_MOD_DST) = '1' and
            (prep_stage_i.dst_mode = C_MODE_POST or prep_stage_i.dst_mode = C_MODE_PRE) then
            reg_addr_o <= prep_stage_i.dst_addr;
            if prep_stage_i.dst_mode = C_MODE_POST then
               reg_val_o <= prep_stage_i.dst_val + 1;
            else
               reg_val_o <= prep_stage_i.dst_val - 1;
            end if;
            reg_we_o   <= '1';
         end if;

         -- Handle ordinary register writes here.
         if prep_stage_i.microcodes(C_REG_WRITE) then
            reg_addr_o <= prep_stage_i.res_reg;
            reg_val_o  <= alu_res_val;
            reg_we_o   <= '1';
         end if;
      end if;

      if rst_i = '1' then
         reg_addr_o <= to_stdlogicvector(C_REG_PC, 4);
         reg_val_o  <= (others => '0');
         reg_we_o   <= '1';
      end if;
   end process p_reg;


   ------------------------------------------------------------
   -- Writes to R15 are forwarded back to the fetch stage as well.
   -- So is a register bank switch, see below.
   ------------------------------------------------------------

   wr_r15 <= and(reg_addr_o) and reg_we_o;

   fetch_addr_o  <= reg_val_o when wr_r15 = '1' else
                    next_pc;


   ------------------------------------------------------------
   -- Register bank switch
   ------------------------------------------------------------

   -- The upper eight bits of R14 select which of the 256 pages of R0-R7 the
   -- register file presents (see src/registers/registers.vhd). Changing them
   -- is a control transfer in disguise, and has to be treated as one.
   --
   -- DECODE issues a register read two stages ahead of WRITE, so by the time
   -- INCRB's new bank reaches the register file, the read for the instruction
   -- after it has ALREADY been issued -- against the old bank. Forwarding the
   -- bank into the read address does not help: the address was applied to the
   -- RAM a full cycle before the new bank existed. Measured on the instruction
   -- pair "DECRB / MOVE R0, R9", the read goes out one cycle before the SR
   -- write lands.
   --
   -- So a bank switch is flushed exactly the way a taken branch is: redirect
   -- FETCH to the following instruction, which resets DECODE and PREPARE (see
   -- the note at the top of cpu_main.vhd). The instruction that comes back has
   -- its register read issued long after reg_sr has caught up. The cost is a
   -- branch penalty on INCRB/DECRB, which is what the ISA uses to enter and
   -- leave a subroutine -- rare, and cheaper than getting the wrong registers.
   --
   -- The trigger is deliberately SYNTACTIC -- "this instruction writes R14, or
   -- it is INCRB/DECRB" -- and not a comparison of the new bank against the
   -- old one. The obvious version,
   --
   --    r14_next    <= reg_val_o when reg_we_o = '1' and reg_addr_o = 14 else
   --                   alu_res_flags;
   --    bank_switch <= inst_done_o when r14_next(15 downto 8) /=
   --                                    prep_stage_i.r14(15 downto 8) else '0';
   --
   -- is more precise -- it leaves "MOVE ST____C_, R14" free of a flush -- but
   -- it costs the whole timing margin, and it is worth understanding why
   -- before anyone reaches for it again. fetch_valid_o is not just a signal to
   -- FETCH: cpu_main.vhd resets DECODE and PREPARE with "rst_i or
   -- fetch_valid_o", so it drives the reset pin of every flip-flop in two
   -- stages. Feeding it from reg_val_o puts the ALU result, an 8-bit
   -- comparator and two more levels of logic in front of that high-fanout net.
   -- Measured at commit b987964: WNS +0.344 ns -> +0.010 ns and +44 LUTs, with
   -- the worst path landing on i_prepare/wr_stage_o_reg[alu_src_val]. The
   -- syntactic version below gives +0.246 ns and 4 LUTs FEWER than baseline.
   --
   -- Everything below comes from stage REGISTERS instead -- prep_stage_i.inst
   -- for the opcode, and reg_addr_o/reg_we_o, which p_reg builds out of
   -- prep_stage_i.src_addr/dst_addr/res_reg and the microcodes. None of it
   -- depends on the ALU, so the flush condition is ready early in the cycle.
   --
   -- The price is that any write to R14 flushes, even one that leaves the bank
   -- alone. That covers "MOVE ST____C_, R14" and friends; they cost a branch
   -- penalty now. Since p_reg is combinational and drives reg_addr_o for the
   -- pre/post-increment write-backs as well as for ordinary results -- on every
   -- micro-op, not just the last -- this also covers R14 used as a POINTER,
   -- e.g. "MOVE @R14++, R0".
   --
   -- f_flush_on_bank_change in formal/cpu_main.psl is what checks that this
   -- syntactic trigger really does cover every change of the bank bits: it
   -- compares the value landing in R14 against prep_stage_i.r14, which the RTL
   -- here never does. Narrow the term below and that property objects.

   ------------------------------------------------------------
   -- Self-modifying code
   ------------------------------------------------------------

   -- Instruction and data memory are the same physical RAM, so a store can
   -- land on an instruction that FETCH, the Icache, DECODE or PREPARE has
   -- already read. Nothing downstream would ever notice: the stale copy is
   -- decoded and executed exactly as if the store had not happened. The fix is
   -- the same flush used for a taken branch -- discard everything already read
   -- and re-fetch from the next address, by which time the write has reached
   -- the RAM (it is a true dual-port memory, and the re-fetch cannot get back
   -- to the bus in the same cycle).
   --
   -- Doing that on EVERY store is correct but far too expensive: it puts a
   -- branch penalty on every "MOVE R0, @R1". Measured, it costs +8.5% of the
   -- run time of test/prog.asm and +64% of test/prog_interleave.asm, the
   -- store-heavy one. So the flush is restricted to stores that can actually
   -- hit something already read.
   --
   -- Everything already read lies in [next_pc, next_pc + 8):
   --
   --    PREPARE and DECODE hold one instruction each, <= 2 words apiece, so
   --    the word at the Icache output is at most next_pc + 4.
   --    The Icache holds 2 words and FETCH at most C_MAX_PENDING = 2 more
   --    (see src/fetch/README.md), so the highest address ever requested is
   --    at most 4 beyond that.
   --
   -- The second half is not just an upper bound on paper: probing
   -- wbi_addr_o - icache2decode_addr at every accepted handshake over the
   -- whole of prog.asm gives a maximum of exactly 4.
   --
   -- A store that lands outside the window is safe for the opposite reason:
   -- nothing has read that address yet, so the fetch that eventually reaches
   -- it sees the new value. Only the boundary needs a margin. Both sides of it
   -- are probed by test/prog_self_modifying.asm -- T1-T5 and T7 from inside,
   -- T3 from outside.
   --
   -- The comparison subtracts two RAW stage registers, prep_stage_i.dst_val
   -- and prep_stage_i.addr, rather than the values actually used for the store
   -- and the re-fetch address. That matters a lot. Writing the exact form,
   --
   --    smc_delta <= mem_req_addr_o - next_pc;
   --    smc_hit   <= '1' when smc_delta(15 downto 4) = X"000" else '0';
   --
   -- puts a four-way mux (mem_addr) and an adder (next_pc) in FRONT of the
   -- subtract, and all of it lands on fetch_valid_o, which is the reset pin of
   -- every flip-flop in DECODE and PREPARE. Measured: WNS -0.042 ns with 8
   -- failing endpoints, i.e. it does not build. Subtracting the raw registers
   -- starts the carry chain at a register output instead.
   --
   -- The price is that the difference is off by a small constant. The store
   -- address is dst_val or dst_val-1 (pre-decrement), and the re-fetch address
   -- is addr+1 or addr+2, so
   --
   --    mem_addr - next_pc  =  (dst_val - addr) - k,   k in {1,2,3}
   --
   -- and a store that really is within 8 of next_pc has dst_val - addr in
   -- [1,11). Testing "< 32" covers that with room to spare, and being a power
   -- of two it is an 11-bit zero-test rather than a magnitude comparison.
   -- Over-approximating is free of correctness risk -- it can only cause a
   -- flush that was not needed - which is also why R15 as a store pointer is
   -- simply forced to hit rather than handled: dst_val is the register file's
   -- stale R15 copy in that case, so the subtraction would be meaningless.

   smc_delta <= prep_stage_i.dst_val - prep_stage_i.addr;
   smc_hit   <= '1' when smc_delta(15 downto 5) = "00000000000" or
                         prep_stage_i.dst_addr = to_stdlogicvector(C_REG_PC, 4) else
                '0';


   ------------------------------------------------------------
   -- Register bank switch, continued
   ------------------------------------------------------------

   is_crb <= '1' when prep_stage_i.inst(R_OPCODE) = C_OPCODE_CTRL and
                      (prep_stage_i.inst(R_CTRL_CMD) = C_CTRL_INCRB or
                       prep_stage_i.inst(R_CTRL_CMD) = C_CTRL_DECRB) else
             '0';

   -- Note that R14 and R15 share reg_addr_o(3 downto 1) = "111", so the two
   -- register-write terms collapse into one, and the whole expression fits a
   -- single 6-input LUT: reg_we_o, three address bits, inst_done_o, is_crb.
   fetch_valid_o <= (reg_we_o and and(reg_addr_o(3 downto 1))) or
                    (inst_done_o and is_crb) or
                    (inst_done_o and prep_stage_i.microcodes(C_MEM_WRITE) and smc_hit);


   ------------------------------------------------------------
   -- Update status register
   ------------------------------------------------------------

   reg_r14_o    <= alu_res_flags;
   reg_r14_we_o <= prep_valid_i and prep_ready_o and prep_stage_i.microcodes(C_LAST);


   ------------------------------------------------------------
   -- Update memory
   ------------------------------------------------------------

   mem_addr  <= prep_stage_i.src_val-1 when prep_stage_i.microcodes(C_MEM_READ_SRC) = '1' and prep_stage_i.src_mode = C_MODE_PRE else
                prep_stage_i.src_val   when prep_stage_i.microcodes(C_MEM_READ_SRC) = '1' else
                prep_stage_i.dst_val-1 when prep_stage_i.microcodes(C_MEM_READ_SRC) = '0' and prep_stage_i.dst_mode = C_MODE_PRE else
                prep_stage_i.dst_val;
   -- The address of the instruction following this one: the return address that
   -- ASUB/RSUB pushes, and the address a bank switch re-fetches from.
   next_pc   <= prep_stage_i.addr + 2 when (prep_stage_i.src_imm = '1' or prep_stage_i.dst_imm = '1') else
                prep_stage_i.addr + 1;
   mem_data  <= next_pc;
   mem_valid <= '1' when or(prep_stage_i.microcodes(2 downto 0)) = '1' and prep_stage_i.inst(R_OPCODE) = C_OPCODE_JMP else
                '0';


   mem_req_valid_o <= prep_valid_i and or(mem_req_op_o);
   mem_req_op_o    <= prep_stage_i.microcodes(2 downto 0);
   mem_req_data_o  <= mem_data when mem_valid = '1' else
                      alu_res_val;
   mem_req_addr_o  <= mem_addr;


   ------------------------------------------------------------
   -- Instruction retired
   ------------------------------------------------------------

   -- One pulse per instruction, on its LAST micro-op. Used by the debug log,
   -- by halt_o, and by the bank-switch flush above.
   inst_done_o <= prep_valid_i and prep_ready_o and prep_stage_i.microcodes(C_LAST);


   ------------------------------------------------------------
   -- Halt
   ------------------------------------------------------------

   -- HALT has no architectural side effects of its own; all it does is tell the
   -- outside world that the program has run to completion. cpu.vhd latches this
   -- pulse and stops feeding the pipeline, and the testbench uses it as the
   -- end-of-test event.
   halt_o <= inst_done_o when prep_stage_i.inst(R_OPCODE) = C_OPCODE_CTRL and
                              prep_stage_i.inst(R_CTRL_CMD) = C_CTRL_HALT
             else '0';

end architecture synthesis;

