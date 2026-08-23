library ieee;
use ieee.std_logic_1164.all;

-- The FETCH module consists of a simpler one-word-at-a-time file fetch.vhd and
-- a simple instruction cache icache.vhd.

entity fetch_cache is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;

      -- From EXECUTE stage
      s_valid_i   : in  std_logic;
      s_addr_i    : in  std_logic_vector(15 downto 0);

      -- Instruction Memory
      wbi_cyc_o   : out std_logic;
      wbi_stb_o   : out std_logic;
      wbi_stall_i : in  std_logic;
      wbi_addr_o  : out std_logic_vector(15 downto 0);
      wbi_ack_i   : in  std_logic;
      wbi_data_i  : in  std_logic_vector(15 downto 0);

      -- To DECODE stage
      m_valid_o   : out std_logic;
      m_ready_i   : in  std_logic;
      m_double_o  : out std_logic;
      m_addr_o    : out std_logic_vector(15 downto 0);
      m_data_o    : out std_logic_vector(31 downto 0);
      m_double_i  : in  std_logic
   );
end entity fetch_cache;

architecture synthesis of fetch_cache is

   -- Fetch to pause
   signal fetch2pause_valid  : std_logic;
   signal fetch2pause_ready  : std_logic;
   signal fetch2pause_addr   : std_logic_vector(15 downto 0);
   signal fetch2pause_data   : std_logic_vector(15 downto 0);

   -- Pause to icache
   signal pause2icache_valid : std_logic;
   signal pause2icache_ready : std_logic;
   signal pause2icache_addr  : std_logic_vector(15 downto 0);
   signal pause2icache_data  : std_logic_vector(15 downto 0);

   signal icache_rst         : std_logic;

begin

   icache_rst <= rst_i or s_valid_i;

   i_fetch : entity work.fetch
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         wb_cyc_o   => wbi_cyc_o,
         wb_stb_o   => wbi_stb_o,
         wb_stall_i => wbi_stall_i,
         wb_addr_o  => wbi_addr_o,
         wb_ack_i   => wbi_ack_i,
         wb_data_i  => wbi_data_i,
         dc_valid_o => fetch2pause_valid,
         dc_ready_i => fetch2pause_ready,
         dc_addr_o  => fetch2pause_addr,
         dc_data_o  => fetch2pause_data,
         dc_valid_i => s_valid_i,
         dc_addr_i  => s_addr_i
      ); -- i_fetch


   -- WORKAROUND, NOT A DEBUG AID. G_PAUSE_SIZE = -8 throttles the instruction
   -- stream to one word every eight clock cycles. That drains the pipeline
   -- between instructions, so two instructions are never close enough together
   -- for a data hazard to occur and the bypass logic is never exercised.
   --
   -- The correct value is 0 (full throughput, no pauses). The bug that
   -- originally forced this workaround -- a missing write-before-read forward
   -- of the dedicated SR write port in registers.vhd, which made test/prog.asm
   -- fail at 0x04A8 -- has been fixed, and all five test programs now pass at
   -- both -8 and 0.
   --
   -- It is kept at -8 anyway: passing the current test programs does not prove
   -- that no other pipeline bug remains, and this throttle is what has been
   -- masking that whole class of bug. Flipping it to 0 is a deliberate decision.
   --
   -- See src/fetch/README.md#Instruction-stream-throttle.
   i_axi_pause : entity work.axi_pause
      generic map (
         G_TDATA_SIZE => 32,
         G_PAUSE_SIZE => -8
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         s_tvalid_i => fetch2pause_valid,
         s_tready_o => fetch2pause_ready,
         s_tdata_i(31 downto 16)  => fetch2pause_addr,
         s_tdata_i(15 downto 0)   => fetch2pause_data,
         m_tvalid_o => pause2icache_valid,
         m_tready_i => pause2icache_ready,
         m_tdata_o(31 downto 16)  => pause2icache_addr,
         m_tdata_o(15 downto 0)   => pause2icache_data
      ); -- i_axi_pause


   i_icache : entity work.icache
      generic map (
         G_ADDR_SIZE => 16,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i      => clk_i,
         rst_i      => icache_rst,
         s_valid_i  => pause2icache_valid,
         s_ready_o  => pause2icache_ready,
         s_addr_i   => pause2icache_addr,
         s_data_i   => pause2icache_data,
         m_valid_o  => m_valid_o,
         m_ready_i  => m_ready_i,
         m_double_o => m_double_o,
         m_addr_o   => m_addr_o,
         m_data_o   => m_data_o,
         m_double_i => m_double_i
      ); -- i_icache

end architecture synthesis;

