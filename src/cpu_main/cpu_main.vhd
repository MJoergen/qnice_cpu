library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity cpu_main is
   port (
      clk_i            : in  std_logic;
      rst_i            : in  std_logic;

      -- From Fetch
      fetch_valid_i    : in  std_logic;
      fetch_ready_o    : out std_logic;
      fetch_double_i   : in  std_logic;
      fetch_addr_i     : in  std_logic_vector(15 downto 0);
      fetch_data_i     : in  std_logic_vector(31 downto 0); -- 2 words from instruction memory
      fetch_double_o   : out std_logic;

      -- WRITE to Fetch
      fetch_valid_o    : out std_logic;
      fetch_addr_o     : out std_logic_vector(15 downto 0);

      -- DECODE to Register
      reg_rd_en_o      : out std_logic;
      reg_src_reg_o    : out std_logic_vector(3 downto 0);
      reg_src_val_i    : in  std_logic_vector(15 downto 0);
      reg_dst_reg_o    : out std_logic_vector(3 downto 0);
      reg_dst_val_i    : in  std_logic_vector(15 downto 0);
      reg_r14_i        : in  std_logic_vector(15 downto 0);

      -- Memory to PREPARE
      mem_src_valid_i  : in  std_logic;
      mem_src_ready_o  : out std_logic;
      mem_src_data_i   : in  std_logic_vector(15 downto 0);
      mem_dst_valid_i  : in  std_logic;
      mem_dst_ready_o  : out std_logic;
      mem_dst_data_i   : in  std_logic_vector(15 downto 0);

      -- WRITE to Memory
      mem_req_valid_o  : out std_logic;
      mem_req_ready_i  : in  std_logic;
      mem_req_op_o     : out std_logic_vector(2 downto 0);
      mem_req_addr_o   : out std_logic_vector(15 downto 0);
      mem_req_data_o   : out std_logic_vector(15 downto 0);

      -- WRITE to Register
      reg_r14_we_o     : out std_logic;
      reg_r14_o        : out std_logic_vector(15 downto 0);
      reg_we_o         : out std_logic;
      reg_addr_o       : out std_logic_vector(3 downto 0);
      reg_val_o        : out std_logic_vector(15 downto 0);

      -- Debug
      inst_done_o      : out std_logic
   );
end entity cpu_main;

architecture synthesis of cpu_main is

   -- DECODE to SEQUENCER
   signal dec2seq_valid  : std_logic;
   signal dec2seq_ready  : std_logic;
   signal dec2seq_stage  : t_stage;

   -- SEQUENCER to PREPARE
   signal seq2prep_valid : std_logic;
   signal seq2prep_ready : std_logic;
   signal seq2prep_stage : t_stage;

   -- PREPARE to WRITE
   signal prep2wr_valid  : std_logic;
   signal prep2wr_ready  : std_logic;
   signal prep2wr_stage  : t_stage;

begin

   ------------------------------------------------------------
   -- DECODE
   ------------------------------------------------------------

   i_decode : entity work.decode
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         fetch_valid_i  => fetch_valid_i,
         fetch_ready_o  => fetch_ready_o,
         fetch_double_i => fetch_double_i,
         fetch_addr_i   => fetch_addr_i,
         fetch_data_i   => fetch_data_i,
         fetch_double_o => fetch_double_o,
         reg_rd_en_o    => reg_rd_en_o,
         reg_src_addr_o => reg_src_reg_o,
         reg_src_val_i  => reg_src_val_i,
         reg_dst_addr_o => reg_dst_reg_o,
         reg_dst_val_i  => reg_dst_val_i,
         reg_r14_i      => reg_r14_i,
         seq_valid_o    => dec2seq_valid,
         seq_ready_i    => dec2seq_ready,
         seq_stage_o    => dec2seq_stage
      ); -- i_decode


   ------------------------------------------------------------
   -- SEQUENCER
   ------------------------------------------------------------

   i_sequencer : entity work.sequencer
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         dec_valid_i  => dec2seq_valid,
         dec_ready_o  => dec2seq_ready,
         dec_stage_i  => dec2seq_stage,
         prep_valid_o => seq2prep_valid,
         prep_ready_i => seq2prep_ready,
         prep_stage_o => seq2prep_stage
      ); -- i_sequencer


   ------------------------------------------------------------
   -- PREPARE
   ------------------------------------------------------------

   i_prepare : entity work.prepare
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         seq_valid_i      => seq2prep_valid and not fetch_valid_o,
         seq_ready_o      => seq2prep_ready,
         seq_stage_i      => seq2prep_stage,
         mem_src_valid_i  => mem_src_valid_i,
         mem_src_ready_o  => mem_src_ready_o,
         mem_src_data_i   => mem_src_data_i,
         mem_dst_valid_i  => mem_dst_valid_i,
         mem_dst_ready_o  => mem_dst_ready_o,
         mem_dst_data_i   => mem_dst_data_i,
         wr_valid_o       => prep2wr_valid,
         wr_ready_i       => prep2wr_ready,
         wr_stage_o       => prep2wr_stage
      ); -- i_prepare


   ------------------------------------------------------------
   -- WRITE
   ------------------------------------------------------------

   i_write : entity work.write
      port map (
         clk_i           => clk_i,
         rst_i           => rst_i,
         prep_valid_i    => prep2wr_valid,
         prep_ready_o    => prep2wr_ready,
         prep_stage_i    => prep2wr_stage,
         mem_req_valid_o => mem_req_valid_o,
         mem_req_ready_i => mem_req_ready_i,
         mem_req_op_o    => mem_req_op_o,
         mem_req_addr_o  => mem_req_addr_o,
         mem_req_data_o  => mem_req_data_o,
         reg_r14_we_o    => reg_r14_we_o,
         reg_r14_o       => reg_r14_o,
         reg_we_o        => reg_we_o,
         reg_addr_o      => reg_addr_o,
         reg_val_o       => reg_val_o,
         fetch_valid_o   => fetch_valid_o,
         fetch_addr_o    => fetch_addr_o,
         inst_done_o     => inst_done_o
      ); -- i_write

end architecture synthesis;

