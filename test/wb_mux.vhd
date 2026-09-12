-- A generic pipelined WISHBONE multiplexer: one master, two slaves, selected
-- by the extra signal s_sel_i. Slave 0 is served when s_sel_i is 0, slave 1
-- when it is 1.
--
-- The point of this module is that IT RESTORES RESPONSE ORDER. Pipelined
-- WISHBONE ACKs carry no identifying information -- a bare pulse -- so a master
-- with several requests in flight can only pair them with responses by
-- position, and therefore requires its slave to acknowledge in issue order.
-- Fanning that bus out to two slaves breaks the requirement the moment the two
-- have different latencies: issue to a slow slave and then to a fast one, and
-- the second response arrives first. src/memory/memory.vhd would then route
-- read data to the wrong operand, silently.
--
-- So this module makes the ordering guarantee structural instead of a property
-- of whichever slaves happen to be attached. It records which slave each
-- accepted request went to, in issue order, and releases responses strictly in
-- that order, buffering any response that arrives early. Both slaves may be
-- arbitrarily slow, in either of the two ways a pipelined WISHBONE slave can be
-- (delayed acceptance via STALL, delayed response via ACK), and may differ from
-- each other; none of that is visible to the master beyond the delay itself.
--
-- IT ADDS NO LATENCY OF ITS OWN. Requests are forwarded combinationally, and so
-- are responses: when the slave at the head of the order queue acknowledges on
-- a cycle where nothing is buffered ahead of it -- the common case, and the
-- only case when the two slaves have equal latency -- its ACK and data reach
-- the master in that same cycle. Buffering only engages when a response
-- actually arrives out of order.
--
-- Note the asymmetry that makes this work: a WISHBONE master cannot refuse an
-- ACK, so responses must always be accepted, whereas requests can be held off
-- with STALL. Hence the response buffers, and hence G_MAX_OUTSTANDING, which
-- bounds them: the module stalls a request that would exceed that many
-- requests in flight, so the buffers provably cannot overflow. Both masters in
-- this CPU cap themselves at two outstanding (C_MAX_PENDING in fetch.vhd, and
-- the two-deep FIFO in memory.vhd), so at the default the limit is never
-- reached and costs nothing.
--
-- Deliberately NOT on the request path: nothing here derives STB or STALL from
-- ACK. The stall the master sees is its slave's stall, plus a term off a
-- register, so the response path is never spliced onto the front of the request
-- path -- the same discipline memory.vhd's mreq_accept documents at length.
--
-- Requirements on the slaves: each must acknowledge its OWN requests in order
-- (this module reorders between slaves, not within one), and must not
-- acknowledge after CYC is deasserted, which cancels everything outstanding.

library ieee;
   use ieee.std_logic_1164.all;

entity wb_mux is
   generic (
      G_ADDR_SIZE       : positive := 16;
      G_DATA_SIZE       : positive := 16;
      -- Requests allowed in flight at once. The module stalls beyond this, so
      -- it also sizes the response buffers.
      G_MAX_OUTSTANDING : positive := 2
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      -- WISHBONE slave, facing the master
      s_cyc_i    : in  std_logic;
      s_stb_i    : in  std_logic;
      s_stall_o  : out std_logic;
      s_we_i     : in  std_logic;
      s_addr_i   : in  std_logic_vector(G_ADDR_SIZE - 1 downto 0);
      s_data_i   : in  std_logic_vector(G_DATA_SIZE - 1 downto 0);
      s_ack_o    : out std_logic;
      s_data_o   : out std_logic_vector(G_DATA_SIZE - 1 downto 0);
      s_sel_i    : in  std_logic;

      -- WISHBONE master 0: lower half of the address space
      m0_cyc_o   : out std_logic;
      m0_stb_o   : out std_logic;
      m0_stall_i : in  std_logic;
      m0_we_o    : out std_logic;
      m0_addr_o  : out std_logic_vector(G_ADDR_SIZE - 1 downto 0);
      m0_data_o  : out std_logic_vector(G_DATA_SIZE - 1 downto 0);
      m0_ack_i   : in  std_logic;
      m0_data_i  : in  std_logic_vector(G_DATA_SIZE - 1 downto 0);

      -- WISHBONE master 1: upper half of the address space
      m1_cyc_o   : out std_logic;
      m1_stb_o   : out std_logic;
      m1_stall_i : in  std_logic;
      m1_we_o    : out std_logic;
      m1_addr_o  : out std_logic_vector(G_ADDR_SIZE - 1 downto 0);
      m1_data_o  : out std_logic_vector(G_DATA_SIZE - 1 downto 0);
      m1_ack_i   : in  std_logic;
      m1_data_i  : in  std_logic_vector(G_DATA_SIZE - 1 downto 0)
   );
end entity wb_mux;

architecture synthesis of wb_mux is

   subtype R_FILL is natural range 0 to G_MAX_OUTSTANDING;

   type t_data_array is array (natural range <>) of std_logic_vector(G_DATA_SIZE - 1 downto 0);

   signal mux_stall  : std_logic;
   signal req_accept : std_logic;

   -- Which slave each accepted-but-unanswered request went to, oldest first.
   -- This is the whole ordering mechanism.
   signal order      : std_logic_vector(0 to G_MAX_OUTSTANDING - 1) := (others => '0');
   signal order_fill : R_FILL                                       := 0;

   -- Responses that arrived before their turn, per slave, oldest first.
   signal buf0      : t_data_array(0 to G_MAX_OUTSTANDING - 1);
   signal buf0_fill : R_FILL                                       := 0;
   signal buf1      : t_data_array(0 to G_MAX_OUTSTANDING - 1);
   signal buf1_fill : R_FILL                                       := 0;

   signal head       : std_logic;
   signal head_ack   : std_logic;
   signal head_fill  : R_FILL;
   signal head_ready : std_logic;
   signal resp_valid : std_logic;

begin

   ------------------------------------------------------------
   -- Request path: pure combinational fan-out
   ------------------------------------------------------------

   -- Off a register, never off an ACK. See the header.
   mux_stall <= '1' when order_fill = G_MAX_OUTSTANDING else
                 '0';

   s_stall_o <= (mux_stall or m1_stall_i) when s_sel_i = '1' else
                 (mux_stall or m0_stall_i);

   req_accept <= s_cyc_i and s_stb_i and not (mux_stall or m1_stall_i) when s_sel_i = '1' else
                 s_cyc_i and s_stb_i and not (mux_stall or m0_stall_i);

   m0_cyc_o  <= s_cyc_i;
   m0_stb_o  <= s_cyc_i and s_stb_i and not s_sel_i and not mux_stall;
   m0_we_o   <= s_we_i;
   m0_addr_o <= s_addr_i;
   m0_data_o <= s_data_i;

   m1_cyc_o  <= s_cyc_i;
   m1_stb_o  <= s_cyc_i and s_stb_i and s_sel_i and not mux_stall;
   m1_we_o   <= s_we_i;
   m1_addr_o <= s_addr_i;
   m1_data_o <= s_data_i;

   ------------------------------------------------------------
   -- Response path: oldest request first, zero latency when in order
   ------------------------------------------------------------

   head      <= order(0);
   head_ack  <= m1_ack_i when head = '1' else
                 m0_ack_i;
   head_fill <= buf1_fill when head = '1' else
                 buf0_fill;

   -- A response is due when the oldest outstanding request's slave has one to
   -- give: either buffered from an earlier cycle, or arriving right now.
   head_ready <= '1' when head_fill > 0 or head_ack = '1' else
                 '0';
   resp_valid <= s_cyc_i and head_ready when order_fill > 0 else
                 '0';

   s_ack_o <= resp_valid;

   -- Buffered data takes precedence over an ACK arriving this cycle, so that
   -- one slave's own responses stay in order. Otherwise the slave's data bus
   -- is passed straight through -- this is the zero-latency path.
   s_data_o <= buf1(0)   when head = '1' and buf1_fill > 0 else
                 m1_data_i when head = '1' else
                 buf0(0)   when buf0_fill > 0 else
                 m0_data_i;

   p_track : process (clk_i)
      variable order_v : std_logic_vector(0 to G_MAX_OUTSTANDING - 1);
      variable fill_v  : R_FILL;
      variable buf0_v  : t_data_array(0 to G_MAX_OUTSTANDING - 1);
      variable f0_v    : R_FILL;
      variable buf1_v  : t_data_array(0 to G_MAX_OUTSTANDING - 1);
      variable f1_v    : R_FILL;
   begin
      if rising_edge(clk_i) then
         order_v := order;
         fill_v  := order_fill;
         buf0_v  := buf0;
         f0_v    := buf0_fill;
         buf1_v  := buf1;
         f1_v    := buf1_fill;

         -- 1. Retire the response delivered combinationally above, popping the
         --    buffer entry too if that is where its data came from.
         if resp_valid = '1' then
            order_v(0 to G_MAX_OUTSTANDING - 2) := order_v(1 to G_MAX_OUTSTANDING - 1);
            fill_v                              := fill_v - 1;

            if head = '0' and f0_v > 0 then
               buf0_v(0 to G_MAX_OUTSTANDING - 2) := buf0_v(1 to G_MAX_OUTSTANDING - 1);
               f0_v                               := f0_v - 1;
            end if;

            if head = '1' and f1_v > 0 then
               buf1_v(0 to G_MAX_OUTSTANDING - 2) := buf1_v(1 to G_MAX_OUTSTANDING - 1);
               f1_v                               := f1_v - 1;
            end if;
         end if;

         -- 2. Buffer every ACK that step 1 did not just hand to the master. An
         --    ACK is consumed there only when its slave is at the head of the
         --    order queue AND nothing of its own was buffered ahead of it.
         if m0_ack_i = '1' and not (resp_valid = '1' and head = '0' and buf0_fill = 0) then
            assert f0_v < G_MAX_OUTSTANDING
               report "wb_mux: slave 0 response buffer overflow -- more responses than "
                      & "G_MAX_OUTSTANDING allows in flight, so a slave acknowledged a "
                      & "request that was never accepted"
               severity failure;
            buf0_v(f0_v) := m0_data_i;
            f0_v         := f0_v + 1;
         end if;

         if m1_ack_i = '1' and not (resp_valid = '1' and head = '1' and buf1_fill = 0) then
            assert f1_v < G_MAX_OUTSTANDING
               report "wb_mux: slave 1 response buffer overflow -- more responses than "
                      & "G_MAX_OUTSTANDING allows in flight, so a slave acknowledged a "
                      & "request that was never accepted"
               severity failure;
            buf1_v(f1_v) := m1_data_i;
            f1_v         := f1_v + 1;
         end if;

         -- 3. Record where a newly accepted request went. mux_stall guarantees
         --    there is room.
         if req_accept = '1' then
            order_v(fill_v) := s_sel_i;
            fill_v          := fill_v + 1;
         end if;

         order      <= order_v;
         order_fill <= fill_v;
         buf0       <= buf0_v;
         buf0_fill  <= f0_v;
         buf1       <= buf1_v;
         buf1_fill  <= f1_v;

         -- Deasserting CYC cancels every request in flight, so the bookkeeping
         -- for them goes too. Only the occupancy counts need clearing; the
         -- entries they index are then unreachable.
         if s_cyc_i = '0' or rst_i = '1' then
            order_fill <= 0;
            buf0_fill  <= 0;
            buf1_fill  <= 0;
         end if;
      end if;
   end process p_track;

end architecture synthesis;
