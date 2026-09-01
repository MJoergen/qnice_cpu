-- This module multiplexes one request channel and two readback channels into a
-- single Wishbone Master interface. The Wishbone slave is expected to follow:
-- * Requests are ack'ed in the same order.
-- * An ACK may return in the SAME clock cycle in which the slave accepts the
--   request (wb_stb_o='1' and wb_stall_i='0'), but never earlier, and never
--   while nothing is outstanding. Zero-latency ACKs ARE supported; see
--   wb_ack_zero_lat below for the bookkeeping that makes them work.
-- * The slave must not derive wb_ack_i or wb_data_i combinationally from
--   anything that this module in turn derives from wb_ack_i. In practice a
--   zero-latency slave computes wb_ack_i from wb_cyc_o/wb_stb_o/wb_stall_i
--   alone. This module holds up its end of that bargain by keeping
--   wb_cyc_o, wb_stb_o and the request payload free of any combinational
--   path from wb_ack_i -- which is precisely why mreq_accept below is
--   written against REGISTERED state only. Note that this obligation cannot
--   be discharged by reading this file: a term here that depends on
--   msrc_ready_i or mdst_ready_i closes a loop through PREPARE, outside the
--   module entirely. formal/zero_latency_loop.vhd is what checks it.
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

   signal wb_req_afull    : std_logic;
   signal wb_ack_zero_lat : std_logic;
   signal wb_ack_op       : std_logic_vector(2 downto 0);
   signal wb_ack_op_valid : std_logic;

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
   -- EVERY TERM HERE IS REGISTERED, AND THAT IS THE WHOLE POINT. mreq_accept
   -- feeds mreq_valid, hence wb_stb_o; against a slave whose ACK is a
   -- combinational function of STB, anything here that depends on wb_ack_i --
   -- however indirectly -- is a combinational loop. tsb_*_fill come from the
   -- buffers' own m_valid_r registers, so they cannot.
   --
   -- Two things were tried here and are wrong. Neither is caught by any test
   -- or by any property in formal/memory.psl -- both are caught only by
   -- formal/zero_latency_loop.vhd, and its header explains why nothing else
   -- can be:
   --
   -- * msrc_valid_o / mdst_valid_o. These cut through combinationally from
   --   tsb_*_in_valid, hence straight from wb_ack_i. This is the loop
   --   one_stage_buffer's header warns about, and it closes inside this file.
   --
   -- * msrc_ready_i / mdst_ready_i, as a "...and not being consumed this
   --   cycle" refinement. This one closes OUTSIDE this file and so looks
   --   harmless from in here: standalone, this module is loop-free for any
   --   behaviour of those two inputs. In the assembled CPU they come from
   --   PREPARE, whose wait_for_mem_dst makes SRC-ready depend on DST-valid,
   --   and DST-valid depends on wb_ack_i through the buffer above. Six loops,
   --   measured. It also bought nothing: removing the refinement left the
   --   cycle count of all nine test programs bit-identical, in both READ_REG
   --   modes.
   --
   -- Accepting only into an EMPTY buffer is the conservative choice and is
   -- what keeps the bound -- see the "total outstanding per channel never
   -- exceeds 2" argument in src/memory/README.md, and f_src_total_max /
   -- f_dst_total_max in formal/memory.psl which state it.
   mreq_accept <= '0' when mreq_op_i(C_MEM_READ_SRC) = '1' and tsb_src_fill /= 0 else
                  '0' when mreq_op_i(C_MEM_READ_DST) = '1' and tsb_dst_fill /= 0 else
                  tsf_req_in_ready;

   -- Block incoming Memory request until ready
   --
   -- NOTE ON mreq_valid'S STABILITY: mreq_accept (and hence mreq_valid) can
   -- legitimately drop from '1' to '0' across a clock edge even while
   -- mreq_valid_i stays asserted throughout -- e.g. if a SRC response lands
   -- in i_two_stage_buffer_src (raising tsb_src_fill) with msrc_ready_i='0'
   -- in the very cycle i_one_stage_buffer_wb becomes ready. This looks like
   -- it violates that buffer's own "s_valid_i must stay stable until
   -- accepted" contract (formally confirmed reachable by BMC), but it is NOT
   -- a functional bug:
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
   -- Attribute each ACK to the request it completes
   ------------------------------------------------------------

   -- ZERO-LATENCY ACK. The slave is permitted to answer a request in the very
   -- cycle it accepts it (see the header). i_two_stage_fifo_mem is no help
   -- there: its output is REGISTERED, so the entry pushed for that request is
   -- not visible on tsf_req_out_valid/tsf_req_out_data until the next cycle.
   -- An empty FIFO at the moment of an ACK is exactly the signature of that
   -- case -- with nothing else outstanding, the ACK can only belong to the
   -- request going out right now.
   --
   -- Without this term the module fails in two ways at once: the response is
   -- dropped (tsb_*_in_valid below need a type, and the FIFO has none to
   -- give), and the un-popped entry then shifts every later ACK one request
   -- out of step, silently misrouting SRC data to DST and back.
   --
   -- TIMING -- do NOT add a "wb_stb_o and not wb_stall_i" term here, however
   -- much more self-evidently correct it reads. It is redundant: an empty
   -- FIFO means nothing is outstanding, so by the slave contract an ACK can
   -- only belong to a request being issued right now (asserted, not merely
   -- believed -- f_zero_lat_ack_is_issue in formal/memory.psl). And it is
   -- expensive, because it puts wb_stb_o into the cone of msrc_valid_o /
   -- mdst_valid_o, which PREPARE consumes combinationally. wb_stb_o comes
   -- from mreq_valid_i, i.e. from the Sequencer, i.e. from DECODE's
   -- registered microcodes -- so the term splices the whole request-issue
   -- path onto the front of the response path, and the join runs on into
   -- fetch_valid_o and the Icache's reset pin. Measured: WNS +0.135 ns ->
   -- -2.172 ns, 11 logic levels, on a path this module is otherwise nowhere
   -- near. As written, every operand here (wb_ack_i, tsf_req_out_valid, and
   -- mreq_op_i below, which is PREPARE's registered wr_stage_o) comes
   -- straight off a flip-flop.
   wb_ack_zero_lat <= wb_ack_i and not tsf_req_out_valid;

   -- ...and in that case the request being issued is cutting straight through
   -- i_one_stage_buffer_wb from the mreq_* inputs, so its op-type is simply
   -- mreq_op_i. The buffer cannot instead be holding a request staged in an
   -- earlier cycle here: it and the type-tracking FIFO are pushed by the
   -- identical condition (mreq_ready_o -- see the "cannot desync" note at
   -- mreq_valid above), and a FIFO entry is popped only by its own ACK. So a
   -- staged request always still has a FIFO entry, i.e. tsf_req_out_valid='0'
   -- implies the request buffer is empty. That cross-signal invariant is what
   -- the otherwise-unused wb_req_afull exists to expose, so that formal can
   -- check it rather than leaving it as an unstated assumption -- see
   -- f_wb_req_buf_empty and f_zero_lat_ack_is_pushed in formal/memory.psl.
   wb_ack_op       <= mreq_op_i when wb_ack_zero_lat = '1' else tsf_req_out_data;
   wb_ack_op_valid <= (wb_ack_i and tsf_req_out_valid) or wb_ack_zero_lat;


   ------------------------------------------------------------
   -- Store the incoming memory request
   ------------------------------------------------------------

   -- The request accepted this cycle is recorded in the type-tracking FIFO --
   -- unless the slave has already answered it in this same cycle, in which
   -- case there is nothing left to track and pushing it would leave behind a
   -- stale entry that every subsequent ACK would then be matched against.
   tsf_req_in_valid <= mreq_valid_i and mreq_ready_o and not wb_ack_zero_lat;


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
   --
   -- No special case is needed for a zero-latency ACK: there the FIFO is
   -- empty, so this pop is a no-op (two_stage_fifo ignores m_ready_i while
   -- m_valid_r='0'), and the matching push has been suppressed above instead.
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
         s_afull_o           => wb_req_afull,
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
   -- type recovered above (wb_ack_op: the FIFO head, or mreq_op_i on a
   -- zero-latency ACK) to decide the ack just received is for a READ_SRC and
   -- should be routed here. A WRITE ack (wb_ack_op(C_MEM_READ_SRC)='0')
   -- correctly produces neither this nor the DST valid below, and wb_data_i
   -- is simply ignored for it.
   tsb_src_in_valid <= wb_ack_op_valid and wb_ack_op(C_MEM_READ_SRC);

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
   tsb_dst_in_valid <= wb_ack_op_valid and wb_ack_op(C_MEM_READ_DST);

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

