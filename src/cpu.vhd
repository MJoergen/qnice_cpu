library ieee;
use ieee.std_logic_1164.all;

entity cpu is
   generic (
      G_REGISTER_BANK_WIDTH : integer
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;

      -- Instruction Memory
      wbi_cyc_o   : out std_logic;
      wbi_stb_o   : out std_logic;
      wbi_stall_i : in  std_logic;
      wbi_addr_o  : out std_logic_vector(15 downto 0);
      wbi_ack_i   : in  std_logic;
      wbi_data_i  : in  std_logic_vector(15 downto 0);

      -- Data Memory
      wbd_cyc_o   : out std_logic;
      wbd_stb_o   : out std_logic;
      wbd_stall_i : in  std_logic;
      wbd_addr_o  : out std_logic_vector(15 downto 0);
      wbd_we_o    : out std_logic;
      wbd_dat_o   : out std_logic_vector(15 downto 0);
      wbd_ack_i   : in  std_logic;
      wbd_data_i  : in  std_logic_vector(15 downto 0)
   );
end entity cpu;

architecture synthesis of cpu is

   -- FETCH to DECODE/EXECUTE
   signal fetch2decode_valid          : std_logic;
   signal fetch2decode_ready          : std_logic;
   signal fetch2decode_double_valid   : std_logic;
   signal fetch2decode_addr           : std_logic_vector(15 downto 0);
   signal fetch2decode_data           : std_logic_vector(31 downto 0);
   signal fetch2decode_double_consume : std_logic;

   -- EXECUTE to FETCH
   signal exe2fetch_valid             : std_logic;
   signal exe2fetch_addr              : std_logic_vector(15 downto 0);

   -- DECODE/EXECUTE read from register file
   signal decode2reg_rd_en            : std_logic;
   signal decode2reg_src_reg          : std_logic_vector(3 downto 0);
   signal decode2reg_src_val          : std_logic_vector(15 downto 0);
   signal decode2reg_dst_reg          : std_logic_vector(3 downto 0);
   signal decode2reg_dst_val          : std_logic_vector(15 downto 0);
   signal reg2decode_r14              : std_logic_vector(15 downto 0);

   -- DECODE/EXECUTE write to register file
   signal exe2reg_r14_we              : std_logic;
   signal exe2reg_r14                 : std_logic_vector(15 downto 0);
   signal exe2reg_we                  : std_logic;
   signal exe2reg_addr                : std_logic_vector(3 downto 0);
   signal exe2reg_val                 : std_logic_vector(15 downto 0);

   -- DECODE/EXECUTE request to memory
   signal exe2mem_req_valid           : std_logic;
   signal exe2mem_req_ready           : std_logic;
   signal exe2mem_req_op              : std_logic_vector(2 downto 0);
   signal exe2mem_req_addr            : std_logic_vector(15 downto 0);
   signal exe2mem_req_data            : std_logic_vector(15 downto 0);

   -- DECODE/EXECUTE response from memory
   signal mem2exe_src_valid           : std_logic;
   signal mem2exe_src_ready           : std_logic;
   signal mem2exe_src_data            : std_logic_vector(15 downto 0);
   signal mem2exe_dst_valid           : std_logic;
   signal mem2exe_dst_ready           : std_logic;
   signal mem2exe_dst_data            : std_logic_vector(15 downto 0);

begin

   ------------------------------------------------------------
   -- Instruction FETCH
   ------------------------------------------------------------

   i_fetch_cache : entity work.fetch_cache
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         s_valid_i   => exe2fetch_valid,
         s_addr_i    => exe2fetch_addr,
         wbi_cyc_o   => wbi_cyc_o,
         wbi_stb_o   => wbi_stb_o,
         wbi_stall_i => wbi_stall_i,
         wbi_addr_o  => wbi_addr_o,
         wbi_ack_i   => wbi_ack_i,
         wbi_data_i  => wbi_data_i,
         m_valid_o   => fetch2decode_valid,
         m_ready_i   => fetch2decode_ready,
         m_double_o  => fetch2decode_double_valid,
         m_addr_o    => fetch2decode_addr,
         m_data_o    => fetch2decode_data,
         m_double_i  => fetch2decode_double_consume
      ); -- i_fetch_cache


   ------------------------------------------------------------
   -- CPU MAIN
   ------------------------------------------------------------

   i_cpu_main : entity work.cpu_main
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         fetch_valid_i    => fetch2decode_valid,
         fetch_ready_o    => fetch2decode_ready,
         fetch_double_i   => fetch2decode_double_valid,
         fetch_addr_i     => fetch2decode_addr,
         fetch_data_i     => fetch2decode_data,
         fetch_double_o   => fetch2decode_double_consume,
         reg_rd_en_o      => decode2reg_rd_en,
         reg_src_reg_o    => decode2reg_src_reg,
         reg_src_val_i    => decode2reg_src_val,
         reg_dst_reg_o    => decode2reg_dst_reg,
         reg_dst_val_i    => decode2reg_dst_val,
         reg_r14_i        => reg2decode_r14,
         mem_req_valid_o  => exe2mem_req_valid,
         mem_req_ready_i  => exe2mem_req_ready,
         mem_req_op_o     => exe2mem_req_op,
         mem_req_addr_o   => exe2mem_req_addr,
         mem_req_data_o   => exe2mem_req_data,
         mem_src_valid_i  => mem2exe_src_valid,
         mem_src_ready_o  => mem2exe_src_ready,
         mem_src_data_i   => mem2exe_src_data,
         mem_dst_valid_i  => mem2exe_dst_valid,
         mem_dst_ready_o  => mem2exe_dst_ready,
         mem_dst_data_i   => mem2exe_dst_data,
         fetch_valid_o    => exe2fetch_valid,
         fetch_addr_o     => exe2fetch_addr,
         reg_r14_we_o     => exe2reg_r14_we,
         reg_r14_o        => exe2reg_r14,
         reg_we_o         => exe2reg_we,
         reg_addr_o       => exe2reg_addr,
         reg_val_o        => exe2reg_val
      ); -- i_cpu_main


   ------------------------------------------------------------
   -- Register file
   ------------------------------------------------------------

   i_registers : entity work.registers
      generic map (
         G_REGISTER_BANK_WIDTH => G_REGISTER_BANK_WIDTH
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         rd_en_i     => decode2reg_rd_en,
         src_reg_i   => decode2reg_src_reg,
         src_val_o   => decode2reg_src_val,
         dst_reg_i   => decode2reg_dst_reg,
         dst_val_o   => decode2reg_dst_val,
         r14_o       => reg2decode_r14,
         wr_r14_en_i => exe2reg_r14_we,
         wr_r14_i    => exe2reg_r14,
         wr_en_i     => exe2reg_we,
         wr_addr_i   => exe2reg_addr,
         wr_val_i    => exe2reg_val
      ); -- i_registers


   ------------------------------------------------------------
   -- Memory interface
   ------------------------------------------------------------

   i_memory : entity work.memory
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         mreq_valid_i => exe2mem_req_valid,
         mreq_ready_o => exe2mem_req_ready,
         mreq_op_i    => exe2mem_req_op,
         mreq_addr_i  => exe2mem_req_addr,
         mreq_data_i  => exe2mem_req_data,
         msrc_valid_o => mem2exe_src_valid,
         msrc_ready_i => mem2exe_src_ready,
         msrc_data_o  => mem2exe_src_data,
         mdst_valid_o => mem2exe_dst_valid,
         mdst_ready_i => mem2exe_dst_ready,
         mdst_data_o  => mem2exe_dst_data,
         wb_cyc_o     => wbd_cyc_o,
         wb_stb_o     => wbd_stb_o,
         wb_stall_i   => wbd_stall_i,
         wb_addr_o    => wbd_addr_o,
         wb_we_o      => wbd_we_o,
         wb_dat_o     => wbd_dat_o,
         wb_ack_i     => wbd_ack_i,
         wb_data_i    => wbd_data_i
      ); -- i_memory


-- pragma synthesis_off
   i_debug : entity work.debug
      generic map (
         G_FILE_NAME => "test/writes.txt"
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         reg_we_i   => exe2reg_we,
         reg_addr_i => exe2reg_addr,
         reg_data_i => exe2reg_val,
         mem_we_i   => std_logic(wbd_stb_o and wbd_we_o and not wbd_stall_i),
         mem_addr_i => wbd_addr_o,
         mem_data_i => wbd_dat_o
      ); -- i_debug
-- pragma synthesis_on

end architecture synthesis;

