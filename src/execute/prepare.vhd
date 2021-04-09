library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity prepare is
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
      mem_src_valid_i  : in  std_logic;
      mem_src_ready_o  : out std_logic;                        -- combinatorial
      mem_src_data_i   : in  std_logic_vector(15 downto 0);
      mem_dst_valid_i  : in  std_logic;
      mem_dst_ready_o  : out std_logic;                        -- combinatorial
      mem_dst_data_i   : in  std_logic_vector(15 downto 0);

      -- To Execute stage
      exe_valid_o      : out std_logic;
      exe_ready_i      : in  std_logic;
      exe_microcodes_o : out std_logic_vector(11 downto 0);
      exe_addr_o       : out std_logic_vector(15 downto 0);
      exe_inst_o       : out std_logic_vector(15 downto 0);
      exe_immediate_o  : out std_logic_vector(15 downto 0);
      exe_src_addr_o   : out std_logic_vector(3 downto 0);
      exe_src_mode_o   : out std_logic_vector(1 downto 0);
      exe_src_val_o    : out std_logic_vector(15 downto 0);
      exe_src_imm_o    : out std_logic;
      exe_dst_addr_o   : out std_logic_vector(3 downto 0);
      exe_dst_mode_o   : out std_logic_vector(1 downto 0);
      exe_dst_val_o    : out std_logic_vector(15 downto 0);
      exe_dst_imm_o    : out std_logic;
      exe_res_reg_o    : out std_logic_vector(3 downto 0);
      exe_r14_o        : out std_logic_vector(15 downto 0);
      alu_oper_o       : out std_logic_vector(3 downto 0);
      alu_ctrl_o       : out std_logic_vector(5 downto 0);
      alu_flags_o      : out std_logic_vector(15 downto 0);
      alu_src_val_o    : out std_logic_vector(15 downto 0);
      alu_dst_val_o    : out std_logic_vector(15 downto 0);
      update_reg_o     : out std_logic
   );
end entity prepare;

architecture synthesis of prepare is

   signal wait_for_mem_req : std_logic;
   signal wait_for_mem_src : std_logic;
   signal wait_for_mem_dst : std_logic;

   signal alu_oper         : std_logic_vector(3 downto 0);
   signal alu_ctrl         : std_logic_vector(5 downto 0);
   signal alu_flags        : std_logic_vector(15 downto 0);
   signal alu_src_val      : std_logic_vector(15 downto 0);
   signal alu_dst_val      : std_logic_vector(15 downto 0);
   signal update_reg       : std_logic;

begin

   ------------------------------------------------------------
   -- Get values read from memory
   ------------------------------------------------------------

   wait_for_mem_req <= dec_valid_i and or(dec_microcodes_i(2 downto 0)) and not exe_ready_i;
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

   update_reg <= dec_r14_i(to_integer(dec_inst_i(R_JMP_COND))) xor dec_inst_i(R_JMP_NEG)
                 when dec_inst_i(R_OPCODE) = C_OPCODE_JMP
              else '1';


   ------------------------------------------------------------
   -- Output registers
   ------------------------------------------------------------

   p_output : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if exe_ready_i = '1' then
            exe_valid_o <= '0';
         end if;

         if dec_valid_i and dec_ready_o then
            exe_valid_o      <= dec_valid_i;
            exe_microcodes_o <= dec_microcodes_i;
            exe_addr_o       <= dec_addr_i;
            exe_inst_o       <= dec_inst_i;
            exe_immediate_o  <= dec_immediate_i;
            exe_src_addr_o   <= dec_src_addr_i;
            exe_src_mode_o   <= dec_src_mode_i;
            exe_src_val_o    <= dec_src_val_i;
            exe_src_imm_o    <= dec_src_imm_i;
            exe_dst_addr_o   <= dec_dst_addr_i;
            exe_dst_mode_o   <= dec_dst_mode_i;
            exe_dst_val_o    <= dec_dst_val_i;
            exe_dst_imm_o    <= dec_dst_imm_i;
            exe_res_reg_o    <= dec_res_reg_i;
            exe_r14_o        <= dec_r14_i;
            alu_oper_o       <= alu_oper;
            alu_ctrl_o       <= alu_ctrl;
            alu_flags_o      <= alu_flags;
            alu_src_val_o    <= alu_src_val;
            alu_dst_val_o    <= alu_dst_val;
            update_reg_o     <= update_reg;
         end if;
      end if;
   end process p_output;

end architecture synthesis;

