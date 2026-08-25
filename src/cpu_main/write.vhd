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
         if inst_done_o then
            disassemble(prep_stage_i.addr, prep_stage_i.inst, prep_stage_i.immediate);
         end if;
      end if;
   end process p_debug;
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
   -- penalty now. Since reg_addr_o also carries pre/post-increment writes, it
   -- happens to cover R14 used as a POINTER as well, as long as the increment
   -- lands on the instruction's last micro-op.

   is_crb <= '1' when prep_stage_i.inst(R_OPCODE) = C_OPCODE_CTRL and
                      (prep_stage_i.inst(R_CTRL_CMD) = C_CTRL_INCRB or
                       prep_stage_i.inst(R_CTRL_CMD) = C_CTRL_DECRB) else
             '0';

   -- Note that R14 and R15 share reg_addr_o(3 downto 1) = "111", so the two
   -- register-write terms collapse into one, and the whole expression fits a
   -- single 6-input LUT: reg_we_o, three address bits, inst_done_o, is_crb.
   fetch_valid_o <= (reg_we_o and and(reg_addr_o(3 downto 1))) or
                    (inst_done_o and is_crb);


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
   mem_valid <= '1' when or(prep_stage_i.microcodes(2 downto 0)) /= '0' and prep_stage_i.inst(R_OPCODE) = C_OPCODE_JMP else
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

