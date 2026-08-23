library ieee;
use ieee.std_logic_1164.all;

use work.cpu_constants.C_MEM_READ_SRC;
use work.cpu_constants.C_MEM_READ_DST;
use work.cpu_constants.C_MEM_WRITE;

-- This module multiplexes one request channel and two readback channels into a
-- single Wishbone Master interface. The Wishbone slave is expected to follow:
-- * Requests are ack'ed in the same order.
-- * Responses (ACKs) return at least one clock cycle later. No zero-latency
--   ACKs.
--
-- mreq_op_i is a one-hot encoding of the request:
-- * WRITE: This writes mreq_data_i to mreq_addr_i
-- * READ_SRC: This reads from mreq_addr_i to msrc_data_o
-- * READ_DST: This reads from mreq_addr_i to mdst_data_o
--
-- At most two outstanding mreq's are allowed.
-- Hence at most two outstanding Wishbone requests are required to be supported.
--
-- EXECUTE (the requester) must follow the usual valid/ready producer contract:
-- once mreq_valid_i='1' and mreq_ready_o='0', mreq_valid_i/mreq_op_i/
-- mreq_addr_i/mreq_data_i must all remain stable until mreq_ready_o='1' is
-- observed. This is assumed, not checked, by this module (see f_mreq_stable
-- in formal/memory.psl) and is relied upon by the mreq_accept subtlety noted
-- below.

entity memory is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- From EXECUTE
      mreq_valid_i : in  std_logic;
      mreq_ready_o : out std_logic;
      mreq_op_i    : in  std_logic_vector(2 downto 0);
      mreq_addr_i  : in  std_logic_vector(15 downto 0);
      mreq_data_i  : in  std_logic_vector(15 downto 0);

      -- To EXECUTE
      msrc_valid_o : out std_logic;
      msrc_ready_i : in  std_logic;
      msrc_data_o  : out std_logic_vector(15 downto 0);
      mdst_valid_o : out std_logic;
      mdst_ready_i : in  std_logic;
      mdst_data_o  : out std_logic_vector(15 downto 0);

      -- Wishbone Master interface to external memory
      wb_cyc_o     : out std_logic;
      wb_stb_o     : out std_logic;
      wb_stall_i   : in  std_logic;
      wb_addr_o    : out std_logic_vector(15 downto 0);
      wb_we_o      : out std_logic;
      wb_dat_o     : out std_logic_vector(15 downto 0);
      wb_ack_i     : in  std_logic;
      wb_data_i    : in  std_logic_vector(15 downto 0)
   );
end entity memory;

architecture synthesis of memory is

   constant C_WB_WE : natural := 32;
   subtype  R_WB_DATA is natural range 31 downto 16;
   subtype  R_WB_ADDR is natural range 15 downto 0;

   signal mreq_accept : std_logic;
   signal mreq_valid  : std_logic;
   signal mreq_ready  : std_logic;

   signal tsf_req_in_valid  : std_logic;
   signal tsf_req_in_ready  : std_logic;
   signal tsf_req_fill      : natural range 0 to 2;
   signal tsf_req_out_valid : std_logic;
   signal tsf_req_out_ready : std_logic;
   signal tsf_req_out_data  : std_logic_vector(2 downto 0);

   signal tsb_src_in_valid  : std_logic;
   signal tsb_src_in_ready  : std_logic;
   signal tsb_src_fill      : natural range 0 to 2;
   signal tsb_dst_in_valid  : std_logic;
   signal tsb_dst_in_ready  : std_logic;
   signal tsb_dst_fill      : natural range 0 to 2;

begin

   ------------------------------------------------------------------------
   -- Apply back-pressure to incoming requests and buffer outgoing
   -- requests until accepted (wb_stall_i = '0').
   ------------------------------------------------------------------------

   -- Accept request, EXCEPT when any one of:
   -- * SRC read data is presented, but not yet accepted
   -- * DST read data is presented, but not yet accepted
   mreq_accept <= '0' when (mreq_op_i(C_MEM_READ_SRC) and msrc_valid_o and not msrc_ready_i) = '1' else
                  '0' when (mreq_op_i(C_MEM_READ_DST) and mdst_valid_o and not mdst_ready_i) = '1' else
                  tsf_req_in_ready;

   -- Block incoming Memory request until ready
   --
   -- NOTE ON mreq_valid'S STABILITY: mreq_accept (and hence mreq_valid) can
   -- legitimately drop from '1' to '0' across a clock edge even while
   -- mreq_valid_i stays asserted throughout -- e.g. if msrc_valid_o newly
   -- asserts with msrc_ready_i='0' in the very cycle i_one_stage_buffer_wb
   -- becomes ready. This looks like it violates that buffer's own "s_valid_i
   -- must stay stable until accepted" contract (formally confirmed reachable
   -- by BMC), but it is NOT a functional bug:
   -- * mreq_ready_o = mreq_ready and mreq_accept, so EXECUTE is never told
   --   "accepted" while mreq_accept='0' -- it keeps holding mreq_valid_i and
   --   the payload stable per its own contract (see header), so no data is
   --   ever lost, just possibly delayed by one extra cycle.
   -- * i_one_stage_buffer_wb's s_data_i is wired directly to mreq_op_i /
   --   mreq_addr_i / mreq_data_i (NOT gated by mreq_accept), so it stays
   --   correct throughout regardless of mreq_valid's glitching.
   -- * tsf_req_in_valid (below) is gated by this exact same mreq_ready_o, so
   --   the WB-request buffer and the op-type-tracking FIFO always push (or
   --   don't) together -- they cannot desync.
   -- Do not "fix" this by feeding i_one_stage_buffer_wb an ungated
   -- mreq_valid_i directly: that would let it latch a request that
   -- tsf_req_in_valid did NOT also push, desyncing the two.
   mreq_valid   <= mreq_valid_i and mreq_accept;
   mreq_ready_o <= mreq_ready and mreq_accept;


   ------------------------------------------------------------------------
   -- Store the incoming memory request
   ------------------------------------------------------------------------

   tsf_req_in_valid <= mreq_valid_i and mreq_ready_o;

   -- Two-word FIFO with registered output
   i_two_stage_fifo_mem : entity work.two_stage_fifo
      generic map (
         G_DATA_SIZE => 3
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         s_valid_i => tsf_req_in_valid,
         s_ready_o => tsf_req_in_ready,
         s_data_i  => mreq_op_i,
         s_fill_o  => tsf_req_fill,
         m_valid_o => tsf_req_out_valid,
         m_ready_i => tsf_req_out_ready,
         m_data_o  => tsf_req_out_data
      ); -- i_two_stage_fifo_mem

   tsf_req_out_ready <= wb_cyc_o and wb_ack_i;


   ------------------------------------------------------------------------
   -- Buffer outgoing Wishbone request until accepted
   ------------------------------------------------------------------------

   i_one_stage_buffer_wb : entity work.one_stage_buffer
      generic map (
         G_DATA_SIZE => 33
      )
      port map (
         clk_i               => clk_i,
         rst_i               => rst_i,
         s_valid_i           => mreq_valid,
         s_ready_o           => mreq_ready,
         s_data_i(C_WB_WE)   => mreq_op_i(C_MEM_WRITE),
         s_data_i(R_WB_DATA) => mreq_data_i,
         s_data_i(R_WB_ADDR) => mreq_addr_i,
         m_valid_o           => wb_stb_o,
         m_ready_i           => not wb_stall_i,
         m_data_o(C_WB_WE)   => wb_we_o,
         m_data_o(R_WB_DATA) => wb_dat_o,
         m_data_o(R_WB_ADDR) => wb_addr_o
      ); -- i_one_stage_buffer_wb

   -- Hold wishbone buffer while waiting for response
   wb_cyc_o <= '1' when (wb_stb_o = '1' or tsf_req_out_valid = '1') and rst_i = '0' else
               '0';


   ------------------------------------------------------------------------
   -- Store the response for the SRC output
   ------------------------------------------------------------------------

   tsb_src_in_valid <= '1' when wb_ack_i = '1' and tsf_req_out_valid = '1' and
                                tsf_req_out_data(C_MEM_READ_SRC) = '1' else
                       '0';

   -- Two-word FIFO with zero-latency forwarding
   i_two_stage_buffer_src : entity work.two_stage_buffer
      generic map (
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         s_valid_i => tsb_src_in_valid,
         s_ready_o => tsb_src_in_ready,
         s_data_i  => wb_data_i,
         s_fill_o  => tsb_src_fill,
         m_valid_o => msrc_valid_o,
         m_ready_i => msrc_ready_i,
         m_data_o  => msrc_data_o
      ); -- i_two_stage_buffer_src


   ------------------------------------------------------------------------
   -- Store the response for the DST output
   ------------------------------------------------------------------------

   tsb_dst_in_valid <= '1' when wb_ack_i = '1' and tsf_req_out_valid = '1' and
                                tsf_req_out_data(C_MEM_READ_DST) = '1' else
                       '0';

   -- Two-word FIFO with zero-latency forwarding
   i_two_stage_buffer_dst : entity work.two_stage_buffer
      generic map (
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         s_valid_i => tsb_dst_in_valid,
         s_ready_o => tsb_dst_in_ready,
         s_data_i  => wb_data_i,
         s_fill_o  => tsb_dst_fill,
         m_valid_o => mdst_valid_o,
         m_ready_i => mdst_ready_i,
         m_data_o  => mdst_data_o
      ); -- i_two_stage_buffer_dst

end architecture synthesis;

