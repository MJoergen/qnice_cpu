library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity execute is
   port (
      clk_i            : in  std_logic;
      rst_i            : in  std_logic;

      -- From decode
      dec_valid_i      : in  std_logic;
      dec_ready_o      : out std_logic;
      dec_microcodes_i : in  std_logic_vector(11 downto 0);
      dec_addr_i       : in  std_logic_vector(15 downto 0);
      dec_inst_i       : in  std_logic_vector(15 downto 0);
      dec_immediate_i  : in  std_logic_vector(15 downto 0);
      dec_src_addr_i   : in  std_logic_vector(3 downto 0);
      dec_src_mode_i   : in  std_logic_vector(1 downto 0);
      dec_src_val_i    : in  std_logic_vector(15 downto 0);
      dec_src_imm_i    : in  std_logic;
      dec_dst_addr_i   : in  std_logic_vector(3 downto 0);
      dec_dst_mode_i   : in  std_logic_vector(1 downto 0);
      dec_dst_val_i    : in  std_logic_vector(15 downto 0);
      dec_dst_imm_i    : in  std_logic;
      dec_res_reg_i    : in  std_logic_vector(3 downto 0);
      dec_r14_i        : in  std_logic_vector(15 downto 0);

      -- Memory
      mem_req_valid_o  : out std_logic;                        -- combinatorial
      mem_req_ready_i  : in  std_logic;
      mem_req_op_o     : out std_logic_vector(2 downto 0);     -- combinatorial
      mem_req_addr_o   : out std_logic_vector(15 downto 0);    -- combinatorial
      mem_req_data_o   : out std_logic_vector(15 downto 0);    -- combinatorial

      mem_src_valid_i  : in  std_logic;
      mem_src_ready_o  : out std_logic;                        -- combinatorial
      mem_src_data_i   : in  std_logic_vector(15 downto 0);
      mem_dst_valid_i  : in  std_logic;
      mem_dst_ready_o  : out std_logic;                        -- combinatorial
      mem_dst_data_i   : in  std_logic_vector(15 downto 0);

      -- Register file
      reg_r14_we_o     : out std_logic;
      reg_r14_o        : out std_logic_vector(15 downto 0);
      reg_we_o         : out std_logic;
      reg_addr_o       : out std_logic_vector(3 downto 0);
      reg_val_o        : out std_logic_vector(15 downto 0);
      fetch_valid_o    : out std_logic;
      fetch_addr_o     : out std_logic_vector(15 downto 0);

      inst_done_o      : out std_logic
   );
end entity execute;

architecture synthesis of execute is

   signal wait_for_mem_req : std_logic;
   signal wait_for_mem_src : std_logic;
   signal wait_for_mem_dst : std_logic;

   signal alu_oper      : std_logic_vector(3 downto 0);
   signal alu_ctrl      : std_logic_vector(5 downto 0);
   signal alu_flags     : std_logic_vector(15 downto 0);
   signal alu_src_val   : std_logic_vector(15 downto 0);
   signal alu_dst_val   : std_logic_vector(15 downto 0);
   signal alu_res_val   : std_logic_vector(16 downto 0);
   signal alu_res_flags : std_logic_vector(15 downto 0);

   signal update_reg    : std_logic;

begin

   ------------------------------------------------------------
   -- Get values read from memory
   ------------------------------------------------------------

   wait_for_mem_req <= dec_valid_i and or(dec_microcodes_i(2 downto 0)) and not mem_req_ready_i;
   wait_for_mem_src <= dec_valid_i and dec_microcodes_i(C_MEM_WAIT_SRC) and not mem_src_valid_i;
   wait_for_mem_dst <= dec_valid_i and dec_microcodes_i(C_MEM_WAIT_DST) and not mem_dst_valid_i;


   ------------------------------------------------------------
   -- Back-pressure
   ------------------------------------------------------------

   mem_src_ready_o <= dec_valid_i and dec_microcodes_i(C_MEM_WAIT_SRC) and not wait_for_mem_dst;
   mem_dst_ready_o <= dec_valid_i and dec_microcodes_i(C_MEM_WAIT_DST) and not wait_for_mem_src;
   dec_ready_o <= not (wait_for_mem_req or wait_for_mem_src or wait_for_mem_dst);


   ------------------------------------------------------------
   -- ALU
   ------------------------------------------------------------

   alu_oper    <= dec_inst_i(R_OPCODE);
   alu_ctrl    <= dec_inst_i(R_CTRL_CMD);
   alu_flags   <= dec_r14_i;
   alu_src_val <= dec_immediate_i when dec_src_imm_i else
                  mem_src_data_i when dec_microcodes_i(C_MEM_WAIT_SRC) = '1' else
                  dec_addr_i+1 when dec_src_addr_i = C_REG_PC else
                  dec_src_val_i;
   alu_dst_val <= dec_immediate_i when dec_dst_imm_i else
                  mem_dst_data_i when dec_microcodes_i(C_MEM_WAIT_DST) = '1' else
                  dec_dst_val_i;

   -- TBD: Possible timing optimization: Put registers on inputs to ALU.
   -- Potential improvement: Large

   i_alu_data : entity work.alu_data
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         opcode_i   => alu_oper,
         sr_i       => alu_flags,
         src_data_i => alu_src_val,
         dst_data_i => alu_dst_val,
         res_data_o => alu_res_val
      ); -- i_alu_data

   i_alu_flags : entity work.alu_flags
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         opcode_i   => alu_oper,
         ctrl_i     => alu_ctrl,
         sr_i       => alu_flags,
         src_data_i => alu_src_val,
         dst_data_i => alu_dst_val,
         res_data_i => alu_res_val,
         sr_o       => alu_res_flags
      ); -- i_alu_flags


   inst_done_o <= dec_valid_i and dec_ready_o and dec_microcodes_i(C_LAST);

-- pragma synthesis_off
   p_debug : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if inst_done_o then
            disassemble(dec_addr_i, dec_inst_i, dec_immediate_i);
         end if;
      end if;
   end process p_debug;
-- pragma synthesis_on


   ------------------------------------------------------------
   -- Update status register
   ------------------------------------------------------------

   reg_r14_o    <= alu_res_flags;
   reg_r14_we_o <= dec_valid_i and dec_ready_o and dec_microcodes_i(C_LAST);


   ------------------------------------------------------------
   -- Update register (combinatorial)
   ------------------------------------------------------------

   update_reg <= dec_r14_i(to_integer(dec_inst_i(R_JMP_COND))) xor dec_inst_i(R_JMP_NEG)
                 when dec_inst_i(R_OPCODE) = C_OPCODE_JMP
              else '1';

   p_reg : process (all)
   begin
      reg_addr_o <= (others => '0');
      reg_val_o  <= (others => '0');
      reg_we_o   <= '0';

      if dec_valid_i and dec_ready_o and update_reg then
         -- Handle pre- and post increment here.
         if dec_microcodes_i(C_REG_MOD_SRC) = '1' and
            (dec_src_mode_i = C_MODE_POST or dec_src_mode_i = C_MODE_PRE) then
            reg_addr_o <= dec_src_addr_i;
            if dec_src_mode_i = C_MODE_POST then
               reg_val_o <= dec_src_val_i + 1;
            else
               reg_val_o <= dec_src_val_i - 1;
            end if;
            reg_we_o   <= '1';
         end if;

         if dec_microcodes_i(C_REG_MOD_DST) = '1' and
            (dec_dst_mode_i = C_MODE_POST or dec_dst_mode_i = C_MODE_PRE) then
            reg_addr_o <= dec_dst_addr_i;
            if dec_dst_mode_i = C_MODE_POST then
               reg_val_o <= dec_dst_val_i + 1;
            else
               reg_val_o <= dec_dst_val_i - 1;
            end if;
            reg_we_o   <= '1';
         end if;

         -- Handle ordinary register writes here.
         if dec_microcodes_i(C_REG_WRITE) then
            reg_addr_o <= dec_res_reg_i;
            reg_val_o  <= alu_res_val(15 downto 0);
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
   -- Update memory
   ------------------------------------------------------------

   -- Writes to R15 are forwarded back to the fetch stage as well.
   fetch_valid_o <= and(reg_addr_o) and reg_we_o;
   fetch_addr_o  <= reg_val_o;


   ------------------------------------------------------------
   -- Update memory
   ------------------------------------------------------------

   mem_req_valid_o <= dec_valid_i and not wait_for_mem_src and not wait_for_mem_dst and or(mem_req_op_o);
   mem_req_op_o    <= dec_microcodes_i(2 downto 0);
   mem_req_data_o  <= dec_addr_i + 2 when mem_req_op_o /= 0 and dec_inst_i(R_OPCODE) = C_OPCODE_JMP and
                      (dec_src_imm_i = '1' or dec_dst_imm_i = '1') else
                      dec_addr_i + 1 when mem_req_op_o /= 0 and dec_inst_i(R_OPCODE) = C_OPCODE_JMP else
                      alu_res_val(15 downto 0);
   mem_req_addr_o  <= dec_src_val_i-1 when dec_microcodes_i(C_MEM_READ_SRC) = '1' and dec_src_mode_i = C_MODE_PRE else
                      dec_src_val_i   when dec_microcodes_i(C_MEM_READ_SRC) = '1' else
                      dec_dst_val_i-1 when dec_microcodes_i(C_MEM_READ_SRC) = '0' and dec_dst_mode_i = C_MODE_PRE else
                      dec_dst_val_i;

end architecture synthesis;

