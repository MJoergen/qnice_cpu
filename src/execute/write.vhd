library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity write is
   port (
      clk_i             : in  std_logic;
      rst_i             : in  std_logic;

      -- From prepare
      prep_valid_i      : in  std_logic;
      prep_ready_o      : out std_logic;
      prep_microcodes_i : in  std_logic_vector(11 downto 0);
      prep_addr_i       : in  std_logic_vector(15 downto 0);
      prep_inst_i       : in  std_logic_vector(15 downto 0);
      prep_immediate_i  : in  std_logic_vector(15 downto 0);
      prep_src_addr_i   : in  std_logic_vector(3 downto 0);
      prep_src_mode_i   : in  std_logic_vector(1 downto 0);
      prep_src_val_i    : in  std_logic_vector(15 downto 0);
      prep_src_imm_i    : in  std_logic;
      prep_dst_addr_i   : in  std_logic_vector(3 downto 0);
      prep_dst_mode_i   : in  std_logic_vector(1 downto 0);
      prep_dst_val_i    : in  std_logic_vector(15 downto 0);
      prep_dst_imm_i    : in  std_logic;
      prep_res_reg_i    : in  std_logic_vector(3 downto 0);
      prep_r14_i        : in  std_logic_vector(15 downto 0);

      alu_oper_i        : in  std_logic_vector(3 downto 0);
      alu_ctrl_i        : in  std_logic_vector(5 downto 0);
      alu_flags_i       : in  std_logic_vector(15 downto 0);
      alu_src_val_i     : in  std_logic_vector(15 downto 0);
      alu_dst_val_i     : in  std_logic_vector(15 downto 0);
      update_reg_i      : in  std_logic;

      -- Memory
      mem_req_valid_o   : out std_logic;                        -- combinatorial
      mem_req_ready_i   : in  std_logic;
      mem_req_op_o      : out std_logic_vector(2 downto 0);     -- combinatorial
      mem_req_addr_o    : out std_logic_vector(15 downto 0);    -- combinatorial
      mem_req_data_o    : out std_logic_vector(15 downto 0);    -- combinatorial

      -- Register file
      reg_r14_we_o      : out std_logic;
      reg_r14_o         : out std_logic_vector(15 downto 0);
      reg_we_o          : out std_logic;
      reg_addr_o        : out std_logic_vector(3 downto 0);
      reg_val_o         : out std_logic_vector(15 downto 0);
      fetch_valid_o     : out std_logic;
      fetch_addr_o      : out std_logic_vector(15 downto 0);

      inst_done_o       : out std_logic
   );
end entity write;

architecture synthesis of write is

   signal alu_res_val   : std_logic_vector(16 downto 0);
   signal alu_res_flags : std_logic_vector(15 downto 0);

begin

   prep_ready_o <= '1';

   i_alu_data : entity work.alu_data
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         opcode_i   => alu_oper_i,
         sr_i       => alu_flags_i,
         src_data_i => alu_src_val_i,
         dst_data_i => alu_dst_val_i,
         res_data_o => alu_res_val
      ); -- i_alu_data

   i_alu_flags : entity work.alu_flags
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         opcode_i   => alu_oper_i,
         ctrl_i     => alu_ctrl_i,
         sr_i       => alu_flags_i,
         src_data_i => alu_src_val_i,
         dst_data_i => alu_dst_val_i,
         res_data_i => alu_res_val,
         sr_o       => alu_res_flags
      ); -- i_alu_flags


   inst_done_o <= prep_valid_i and prep_ready_o and prep_microcodes_i(C_LAST);

-- pragma synthesis_off
   p_debug : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if inst_done_o then
            disassemble(prep_addr_i, prep_inst_i, prep_immediate_i);
         end if;
      end if;
   end process p_debug;
-- pragma synthesis_on


   ------------------------------------------------------------
   -- Update status register
   ------------------------------------------------------------

   reg_r14_o    <= alu_res_flags;
   reg_r14_we_o <= prep_valid_i and prep_ready_o and prep_microcodes_i(C_LAST);


   ------------------------------------------------------------
   -- Update register (combinatorial)
   ------------------------------------------------------------

   p_reg : process (all)
   begin
      reg_addr_o <= (others => '0');
      reg_val_o  <= (others => '0');
      reg_we_o   <= '0';

      if prep_valid_i and prep_ready_o and update_reg_i then
         -- Handle pre- and post increment here.
         if prep_microcodes_i(C_REG_MOD_SRC) = '1' and
            (prep_src_mode_i = C_MODE_POST or prep_src_mode_i = C_MODE_PRE) then
            reg_addr_o <= prep_src_addr_i;
            if prep_src_mode_i = C_MODE_POST then
               reg_val_o <= prep_src_val_i + 1;
            else
               reg_val_o <= prep_src_val_i - 1;
            end if;
            reg_we_o   <= '1';
         end if;

         if prep_microcodes_i(C_REG_MOD_DST) = '1' and
            (prep_dst_mode_i = C_MODE_POST or prep_dst_mode_i = C_MODE_PRE) then
            reg_addr_o <= prep_dst_addr_i;
            if prep_dst_mode_i = C_MODE_POST then
               reg_val_o <= prep_dst_val_i + 1;
            else
               reg_val_o <= prep_dst_val_i - 1;
            end if;
            reg_we_o   <= '1';
         end if;

         -- Handle ordinary register writes here.
         if prep_microcodes_i(C_REG_WRITE) then
            reg_addr_o <= prep_res_reg_i;
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

   mem_req_valid_o <= prep_valid_i and or(mem_req_op_o);
   mem_req_op_o    <= prep_microcodes_i(2 downto 0);
   mem_req_data_o  <= prep_addr_i + 2 when mem_req_op_o /= 0 and prep_inst_i(R_OPCODE) = C_OPCODE_JMP and
                      (prep_src_imm_i = '1' or prep_dst_imm_i = '1') else
                      prep_addr_i + 1 when mem_req_op_o /= 0 and prep_inst_i(R_OPCODE) = C_OPCODE_JMP else
                      alu_res_val(15 downto 0);
   mem_req_addr_o  <= prep_src_val_i-1 when prep_microcodes_i(C_MEM_READ_SRC) = '1' and prep_src_mode_i = C_MODE_PRE else
                      prep_src_val_i   when prep_microcodes_i(C_MEM_READ_SRC) = '1' else
                      prep_dst_val_i-1 when prep_microcodes_i(C_MEM_READ_SRC) = '0' and prep_dst_mode_i = C_MODE_PRE else
                      prep_dst_val_i;

end architecture synthesis;

