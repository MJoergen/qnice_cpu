library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity prepare is
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;

      -- From DECODE
      dec_valid_i     : in  std_logic;
      dec_ready_o     : out std_logic;
      dec_stage_i     : in  t_stage;

      -- Memory
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

begin

   ------------------------------------------------------------
   -- Get values read from memory
   ------------------------------------------------------------

   wait_for_mem_req <= dec_valid_i and or(dec_stage_i.microcodes(2 downto 0)) and not wr_ready_i;
   wait_for_mem_src <= dec_valid_i and dec_stage_i.microcodes(C_MEM_WAIT_SRC) and not mem_src_valid_i;
   wait_for_mem_dst <= dec_valid_i and dec_stage_i.microcodes(C_MEM_WAIT_DST) and not mem_dst_valid_i;


   ------------------------------------------------------------
   -- Back-pressure
   ------------------------------------------------------------

   mem_src_ready_o <= dec_valid_i and dec_stage_i.microcodes(C_MEM_WAIT_SRC) and not wait_for_mem_dst;
   mem_dst_ready_o <= dec_valid_i and dec_stage_i.microcodes(C_MEM_WAIT_DST) and not wait_for_mem_src;
   dec_ready_o <= not (wait_for_mem_req or wait_for_mem_src or wait_for_mem_dst);


   ------------------------------------------------------------
   -- ALU
   ------------------------------------------------------------

   alu_oper    <= dec_stage_i.inst(R_OPCODE);
   alu_ctrl    <= dec_stage_i.inst(R_CTRL_CMD);
   alu_flags   <= dec_stage_i.r14;
   alu_src_val <= dec_stage_i.immediate when dec_stage_i.src_imm else
                  mem_src_data_i when dec_stage_i.microcodes(C_MEM_WAIT_SRC) = '1' else
                  dec_stage_i.addr+1 when dec_stage_i.src_addr = C_REG_PC else
                  dec_stage_i.src_val;
   alu_dst_val <= dec_stage_i.immediate when dec_stage_i.dst_imm else
                  mem_dst_data_i when dec_stage_i.microcodes(C_MEM_WAIT_DST) = '1' else
                  dec_stage_i.dst_val;


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
         if dec_valid_i and dec_ready_o then
            wr_valid_o             <= dec_valid_i;
            wr_stage_o             <= dec_stage_i;
            wr_stage_o.alu_oper    <= alu_oper;
            wr_stage_o.alu_ctrl    <= alu_ctrl;
            wr_stage_o.alu_flags   <= alu_flags;
            wr_stage_o.alu_src_val <= alu_src_val;
            wr_stage_o.alu_dst_val <= alu_dst_val;
         end if;
      end if;
   end process p_output;

end architecture synthesis;
