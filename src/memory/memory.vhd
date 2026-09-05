-- This module multiplexes one request channel and two readback channels into a
-- single Wishbone Master interface. The Wishbone slave is expected to follow:
-- * Requests are ack'ed in the same order.
-- * Responses (ACKs) return at least one clock cycle later. No zero-latency
--   ACKs.
-- * A reset (or equivalently a mid-transaction rst_i pulse, which drops
--   wb_cyc_o and so aborts any in-flight Wishbone cycle -- see wb_cyc_o
--   below) is not followed by a stray wb_ack_i for the aborted request. This
--   module's own bookkeeping (i_two_stage_fifo_mem) is wiped by the same
--   rst_i, so a late ack for an already-forgotten request cannot be
--   correctly attributed to anything.
--
-- WISHBONE ACKs carry no identifying information -- wb_ack_i is just a pulse,
-- not tagged with which request it completes or what kind it was. This
-- module recovers that information itself via i_two_stage_fifo_mem, which
-- records the op-type (mreq_op_i) of every accepted-but-unacked request, in
-- issue order. Each wb_ack_i is matched to the OLDEST outstanding request
-- (the FIFO's head, tsf_req_out_data) and that head is popped -- so this
-- relies entirely on the "ack'ed in the same order" contract above; if a
-- Wishbone slave ever completed requests out of order, this scheme (and the
-- src/dst read-response routing built on it, see below) would silently
-- misattribute data. This is safe here because wbd_* (see cpu.vhd) connects
-- to a single physical memory device with no internal reordering path.
--
-- mreq_op_i is a one-hot encoding of the request:
-- * WRITE: This writes mreq_data_i to mreq_addr_i
-- * READ_SRC: This reads from mreq_addr_i to msrc_data_o
-- * READ_DST: This reads from mreq_addr_i to mdst_data_o
--
-- At most two outstanding mreq's are allowed.
-- Hence at most two outstanding Wishbone requests are required to be supported.
--
-- WRITE (the requester) must follow the usual valid/ready producer contract:
-- once mreq_valid_i='1' and mreq_ready_o='0', mreq_valid_i/mreq_op_i/
-- mreq_addr_i/mreq_data_i must all remain stable until mreq_ready_o='1' is
-- observed. This is assumed, not checked, by this module (see f_mreq_stable
-- in formal/memory.psl) and is relied upon by the mreq_accept subtlety noted
-- below.

library ieee;
   use ieee.std_logic_1164.all;

   use work.cpu_constants.C_MEM_READ_SRC;
   use work.cpu_constants.C_MEM_READ_DST;
   use work.cpu_constants.C_MEM_WRITE;

entity memory is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- From WRITE
      mreq_valid_i : in  std_logic;
      mreq_ready_o : out std_logic;
      mreq_op_i    : in  std_logic_vector(2 downto 0);
      mreq_addr_i  : in  std_logic_vector(15 downto 0);
      mreq_data_i  : in  std_logic_vector(15 downto 0);

      -- To PREPARE
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

   signal tsb_src_in_valid : std_logic;
   signal tsb_src_in_ready : std_logic;
   signal tsb_src_fill     : natural range 0 to 2;
   signal tsb_dst_in_valid : std_logic;
   signal tsb_dst_in_ready : std_logic;
   signal tsb_dst_fill     : natural range 0 to 2;

begin

   ------------------------------------------------------------
   -- Apply back-pressure to incoming requests and buffer outgoing
   -- requests until accepted (wb_stall_i = '0').
   ------------------------------------------------------------

   -- Accept request, EXCEPT when any one of:
   -- * SRC read data is already stored
   -- * DST read data is already stored
   --
   -- EVERY TERM HERE COMES OFF A FLIP-FLOP, AND THAT IS DELIBERATE.
   -- mreq_accept feeds mreq_valid, hence wb_stb_o, so anything here that
   -- depends on wb_ack_i -- however indirectly -- splices the response path
   -- onto the front of the request path. tsb_*_fill come from the response
   -- buffers' own m_valid_r registers, so they cannot.
   --
   -- Two more precise forms were tried and are worse:
   --
   -- * msrc_valid_o / mdst_valid_o. These cut through combinationally from
   --   tsb_*_in_valid, hence straight from wb_ack_i.
   --
   -- * msrc_ready_i / mdst_ready_i, as a "...and not being consumed this
   --   cycle" refinement. Those come from PREPARE, whose wait_for_mem_dst
   --   makes SRC-ready depend on DST-valid, which depends on wb_ack_i through
   --   the buffer above -- so this one reaches back to the ack as well, just
   --   outside this file. It is also worth nothing: dropping it left the
   --   cycle count of every test program of the time (nine of them)
   --   bit-identical, while the synthesised CPU got SMALLER (929 -> 903
   --   LUTs, this module 57 -> 56, with FETCH, ICACHE, DECODE, PREPARE and
   --   WRITE all shrinking as the shorter path lets synthesis simplify)
   --   and 0.18 ns faster at the 8.50 ns constraint.
   --
   -- Both forms are also combinational LOOPS against a zero-latency slave --
   -- one that acks in the cycle it accepts the request. This module does not
   -- support such a slave for other reasons too (the type-tracking FIFO's
   -- output is registered, so it has no type to route the response by), and
   -- the header says so; removing these two terms is necessary but not
   -- sufficient. doc/README.md's Optimizations section records why that road
   -- was not taken.
   --
   -- Accepting only into an EMPTY buffer is the conservative choice and is
   -- what keeps the bound -- see the "total outstanding per channel never
   -- exceeds 2" argument in src/memory/README.md, and f_src_total_max /
   -- f_dst_total_max in formal/memory.psl which state it.
   mreq_accept <= '0' when mreq_op_i(C_MEM_READ_SRC) = '1' and tsb_src_fill /= 0 else
                  '0' when mreq_op_i(C_MEM_READ_DST) = '1' and tsb_dst_fill /= 0 else
                  tsf_req_in_ready;

   -- Block incoming memory request until ready
   --
   -- NOTE ON mreq_valid'S STABILITY: mreq_accept (and hence mreq_valid) can
   -- legitimately drop from '1' to '0' across a clock edge even while
   -- mreq_valid_i stays asserted throughout -- e.g. if a SRC response lands
   -- in i_two_stage_buffer_src (raising tsb_src_fill) in the very cycle
   -- i_one_stage_buffer_wb becomes ready. This looks like it violates that buffer's own "s_valid_i
   -- must stay stable until accepted" contract (formally confirmed reachable
   -- by BMC), but it is NOT a functional bug:
   -- * mreq_ready_o = mreq_ready and mreq_accept, so WRITE is never told
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


   ------------------------------------------------------------
   -- Store the incoming memory request
   ------------------------------------------------------------

   tsf_req_in_valid <= mreq_valid_i and mreq_ready_o;


   -- This is the type-tagging FIFO described in the header: it exists purely
   -- to recover, on each anonymous wb_ack_i, WHICH kind of request (WRITE /
   -- READ_SRC / READ_DST) is being completed -- see tsf_req_out_ready and
   -- tsb_src_in_valid/tsb_dst_in_valid below, which are what actually consume
   -- that information. Two-word FIFO with registered output.
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

   -- Every wb_ack_i is matched to the OLDEST outstanding request (the FIFO
   -- head, tsf_req_out_data) and pops it -- this is the "acks return in
   -- issue order" assumption from the header, applied. Gating with wb_cyc_o
   -- additionally protects against ever popping on a stray ack that arrives
   -- while nothing is genuinely outstanding (e.g. right after a
   -- reset/abort) -- see the reset/abort note in the header.
   tsf_req_out_ready <= wb_cyc_o and wb_ack_i;


   ------------------------------------------------------------
   -- Buffer outgoing Wishbone request until accepted
   ------------------------------------------------------------

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
   --
   -- Note: wb_cyc_o can drop for a cycle between two logically separate
   -- transactions that happen not to overlap (nothing staged, nothing
   -- outstanding) even while more mreq's are still to come. This is
   -- intentional -- CYC spans one Wishbone bus cycle, not the whole
   -- lifetime of this module -- and is fine under pipelined Wishbone B4, but
   -- worth knowing if this signal looks "flickery" on a waveform.
   wb_cyc_o <= '1' when (wb_stb_o = '1' or tsf_req_out_valid = '1') and rst_i = '0' else
               '0';


   ------------------------------------------------------------
   -- Store the response for the SRC output
   ------------------------------------------------------------

   -- wb_data_i itself doesn't say which read it belongs to -- this reads the
   -- type recovered above (tsf_req_out_data, the FIFO head) to decide the ack
   -- just received is for a READ_SRC and should be routed here. A WRITE ack
   -- (tsf_req_out_data(C_MEM_READ_SRC)='0') correctly produces neither this
   -- nor the DST valid below, and wb_data_i is simply ignored for it.
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


   ------------------------------------------------------------
   -- Store the response for the DST output
   ------------------------------------------------------------

   -- Mirror of tsb_src_in_valid above, for READ_DST.
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

