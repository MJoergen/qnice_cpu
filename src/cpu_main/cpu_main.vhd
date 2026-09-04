-- NOTE: The DECODE, Sequencer and PREPARE modules are explicitly reset (using
-- fetch_valid_o) following any update to the Program Counter (as determined by
-- the WRITE module). This flushes the entire pipeline.

library ieee;
   use ieee.std_logic_1164.all;
   -- Not used by this architecture's own statements, but required by the
   -- vunit in formal/cpu_main.psl (bound to this architecture, so it shares
   -- this context clause), which subtracts two std_logic_vector signals.
   use ieee.numeric_std_unsigned.all;

   use work.cpu_constants.t_stage;

entity cpu_main is
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;

      -- From Fetch
      fetch_valid_i   : in  std_logic;
      fetch_ready_o   : out std_logic;
      fetch_double_i  : in  std_logic;
      fetch_addr_i    : in  std_logic_vector(15 downto 0);
      fetch_data_i    : in  std_logic_vector(31 downto 0); -- 2 words from instruction memory
      fetch_double_o  : out std_logic;

      -- DECODE: early redirect to Fetch, for an unconditional branch with an
      -- immediate target. Mutually exclusive with fetch_valid_o below; see
      -- "Early redirect" in decode.vhd.
      early_valid_o   : out std_logic;
      early_addr_o    : out std_logic_vector(15 downto 0);

      -- DECODE: to Register
      reg_rd_en_o     : out std_logic;
      reg_src_reg_o   : out std_logic_vector(3 downto 0);
      reg_src_val_i   : in  std_logic_vector(15 downto 0);
      reg_dst_reg_o   : out std_logic_vector(3 downto 0);
      reg_dst_val_i   : in  std_logic_vector(15 downto 0);
      reg_r14_i       : in  std_logic_vector(15 downto 0);

      -- PREPARE: from Memory
      mem_src_valid_i : in  std_logic;
      mem_src_ready_o : out std_logic;
      mem_src_data_i  : in  std_logic_vector(15 downto 0);
      mem_dst_valid_i : in  std_logic;
      mem_dst_ready_o : out std_logic;
      mem_dst_data_i  : in  std_logic_vector(15 downto 0);

      -- WRITE: to Memory
      mem_req_valid_o : out std_logic;
      mem_req_ready_i : in  std_logic;
      mem_req_op_o    : out std_logic_vector(2 downto 0);
      mem_req_addr_o  : out std_logic_vector(15 downto 0);
      mem_req_data_o  : out std_logic_vector(15 downto 0);

      -- WRITE: to Register
      reg_r14_we_o    : out std_logic;
      reg_r14_o       : out std_logic_vector(15 downto 0);
      reg_we_o        : out std_logic;
      reg_addr_o      : out std_logic_vector(3 downto 0);
      reg_val_o       : out std_logic_vector(15 downto 0);

      -- WRITE: to Fetch
      fetch_valid_o   : out std_logic;
      fetch_addr_o    : out std_logic_vector(15 downto 0);

      -- WRITE: Halt
      halt_o          : out std_logic;

      -- Debug
      inst_done_o     : out std_logic
   );
end entity cpu_main;

architecture synthesis of cpu_main is

   -- DECODE to the Sequencer: one beat per instruction, carrying the whole
   -- micro-op list.
   signal dec2seq_valid : std_logic;
   signal dec2seq_ready : std_logic;
   signal dec2seq_stage : t_stage;

   -- The Sequencer to PREPARE: one beat per micro-op.
   signal seq2prep_valid : std_logic;
   signal seq2prep_ready : std_logic;
   signal seq2prep_stage : t_stage;

   -- PREPARE to WRITE
   signal prep2wr_valid : std_logic;
   signal prep2wr_ready : std_logic;
   signal prep2wr_stage : t_stage;

   -- WRITE to DECODE and back: register bank switch. See the "Register bank
   -- switch" comment in write.vhd.
   signal bank_switch : std_logic;
   signal bank_stale  : std_logic;

begin

   ------------------------------------------------------------
   -- DECODE
   ------------------------------------------------------------

   i_decode : entity work.decode
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i or fetch_valid_o,
         fetch_valid_i  => fetch_valid_i,
         fetch_ready_o  => fetch_ready_o,
         fetch_double_i => fetch_double_i,
         fetch_addr_i   => fetch_addr_i,
         fetch_data_i   => fetch_data_i,
         fetch_double_o => fetch_double_o,
         early_valid_o  => early_valid_o,
         early_addr_o   => early_addr_o,
         reg_rd_en_o    => reg_rd_en_o,
         reg_src_addr_o => reg_src_reg_o,
         reg_src_val_i  => reg_src_val_i,
         reg_dst_addr_o => reg_dst_reg_o,
         reg_dst_val_i  => reg_dst_val_i,
         reg_r14_i      => reg_r14_i,
         bank_switch_i  => bank_switch,
         bank_stale_o   => bank_stale,
         seq_valid_o    => dec2seq_valid,
         seq_ready_i    => dec2seq_ready,
         seq_stage_o    => dec2seq_stage
      ); -- i_decode


   ------------------------------------------------------------
   -- Sequencer
   ------------------------------------------------------------

   -- DECODE emits an instruction's whole micro-op list in one beat; the
   -- Sequencer issues it one micro-op per clock cycle, holding dec2seq_ready
   -- low until the last one has been accepted. It sits between the two stages
   -- rather than inside PREPARE because that is what it is -- an elastic
   -- one-to-many adapter on the DECODE/PREPARE link, with no part in preparing
   -- the operands. It shares PREPARE's reset, so a pipeline flush abandons a
   -- half-issued list.
   i_sequencer : entity work.sequencer
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i or fetch_valid_o,
         s_valid_i => dec2seq_valid,
         s_ready_o => dec2seq_ready,
         s_stage_i => dec2seq_stage,
         m_valid_o => seq2prep_valid,
         m_ready_i => seq2prep_ready,
         m_stage_o => seq2prep_stage
      ); -- i_sequencer


   ------------------------------------------------------------
   -- PREPARE
   ------------------------------------------------------------

   i_prepare : entity work.prepare
      port map (
         clk_i           => clk_i,
         rst_i           => rst_i or fetch_valid_o,
         seq_valid_i     => seq2prep_valid,
         seq_ready_o     => seq2prep_ready,
         seq_stage_i     => seq2prep_stage,
         mem_src_valid_i => mem_src_valid_i,
         mem_src_ready_o => mem_src_ready_o,
         mem_src_data_i  => mem_src_data_i,
         mem_dst_valid_i => mem_dst_valid_i,
         mem_dst_ready_o => mem_dst_ready_o,
         mem_dst_data_i  => mem_dst_data_i,
         wr_valid_o      => prep2wr_valid,
         wr_ready_i      => prep2wr_ready,
         wr_stage_o      => prep2wr_stage
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
         bank_switch_o   => bank_switch,
         bank_stale_i    => bank_stale,
         inst_done_o     => inst_done_o,
         halt_o          => halt_o
      ); -- i_write

end architecture synthesis;

