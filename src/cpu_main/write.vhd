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

      inst_done_o     : out std_logic
   );
end entity write;

architecture synthesis of write is

   signal alu_res_val   : std_logic_vector(15 downto 0);
   signal alu_res_flags : std_logic_vector(15 downto 0);
   signal update_reg    : std_logic;

   signal mem_addr    : std_logic_vector(15 downto 0);
   signal mem_data    : std_logic_vector(15 downto 0);
   signal mem_valid   : std_logic;

begin

   prep_ready_o <= mem_req_ready_i when or(mem_req_op_o) = '1' else '1';


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
   ------------------------------------------------------------

   fetch_valid_o <= and(reg_addr_o) and reg_we_o;
   fetch_addr_o  <= reg_val_o;


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
   mem_data  <= prep_stage_i.addr + 2 when (prep_stage_i.src_imm = '1' or prep_stage_i.dst_imm = '1') else
                prep_stage_i.addr + 1;
   mem_valid <= '1' when or(prep_stage_i.microcodes(2 downto 0)) /= '0' and prep_stage_i.inst(R_OPCODE) = C_OPCODE_JMP else
                '0';


   mem_req_valid_o <= prep_valid_i and or(mem_req_op_o);
   mem_req_op_o    <= prep_stage_i.microcodes(2 downto 0);
   mem_req_data_o  <= mem_data when mem_valid = '1' else
                      alu_res_val;
   mem_req_addr_o  <= mem_addr;


   ------------------------------------------------------------
   -- Debug
   ------------------------------------------------------------

   inst_done_o <= prep_valid_i and prep_ready_o and prep_stage_i.microcodes(C_LAST);

end architecture synthesis;

