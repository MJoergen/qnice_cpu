-- A simple instruction fetch unit.
--
-- This unit has four interfaces:
-- 1. Sending read requests to WISHBONE (with possible backpressure)
-- 2. Receiving read responses from WISHBONE
-- 3. Sending instructions to DECODE stage (with possible backpressure)
-- 4. Receiving a new PC from the WRITE stage
--
-- THEORY OF OPERATION
-- The unit speculatively fetches a linear sequence of instructions starting at
-- the address most recently supplied by the WRITE stage.  Each WISHBONE read
-- request reserves one "slot".  A slot is allocated when the request is issued
-- (STB asserted) and released when the corresponding instruction word is
-- handed over to the DECODE stage.  At most C_MAX_PENDING slots may be in use
-- at any time, which bounds the occupancy of both internal FIFOs and therefore
-- guarantees that neither of them can ever overflow.
--
-- The WISHBONE interface runs in pipelined mode: STB is asserted for one clock
-- cycle per request (held until STALL is deasserted), whereas CYC is held high
-- until every accepted request has been acknowledged.  Up to two outstanding
-- WISHBONE requests are used.
--
-- REDIRECT
-- A redirect (dc_valid_i) does NOT normally terminate the bus cycle.  CYC
-- stays asserted and the first request of the new instruction stream goes out
-- on the very next clock cycle, which takes one cycle off the branch penalty.
-- The price is that requests the slave has already accepted still owe an
-- acknowledgement, and those acknowledgements must not be paired with an
-- address from the new stream.  wb_stale counts them and wb_rsp_accept is
-- gated so that they are discarded on arrival; this relies on contract (d).
--
-- The bus cycle is torn down instead -- CYC deasserted for at least one cycle,
-- cancelling everything, at the cost of the cycle just saved -- in the one
-- case where it cannot be redirected: a request already asserted on STB that
-- the slave has not yet accepted.  WISHBONE B4 lets the master neither
-- withdraw STB nor alter the request while STALL is asserted.  A slave that
-- never stalls, which is what this CPU is built around, never reaches that
-- path.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) dc_valid_i is an unconditional, single-cycle flush.  It has no
--    backpressure and takes effect immediately: everything already fetched is
--    abandoned, both internal FIFOs are cleared, and fetching restarts at
--    dc_addr_i.
-- b) The WRITE stage MUST supply a new PC (dc_valid_i) before any fetched
--    instruction is meaningful.  wb_addr_o is reset to zero, so without a new
--    PC the unit will start fetching from address 0.
-- c) The attached WISHBONE slave MUST NOT assert ACK after CYC has been
--    deasserted (WISHBONE B4, pipelined mode).  Deasserting CYC terminates the
--    bus cycle and cancels all outstanding requests.  A slave that acknowledges
--    a cancelled request would cause silent instruction corruption, because
--    the stale response would be paired with the address of a new request.
-- d) The attached WISHBONE slave MUST acknowledge requests IN ORDER.  Nothing
--    on the bus identifies which request an ACK belongs to, so discarding the
--    acknowledgements owed to an abandoned request means discarding the next
--    wb_stale of them.  Against a slave that completed requests out of order
--    this would drop the wrong responses.  The Memory module makes the same
--    assumption for the same reason; see src/memory/README.md.
--
-- RESET
-- All state is synchronously reset by rst_i.  No clock domain crossing is
-- present; all ports are synchronous to clk_i.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity fetch is
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      -- Send read request to WISHBONE
      wb_cyc_o   : out std_logic := '0';
      wb_stb_o   : out std_logic := '0';
      wb_stall_i : in  std_logic;
      wb_addr_o  : out std_logic_vector(15 downto 0) := (others => '0');

      -- Receive read response from WISHBONE
      wb_ack_i   : in  std_logic;
      wb_data_i  : in  std_logic_vector(15 downto 0);

      -- Send instruction to DECODE (i.e. to the Icache)
      dc_valid_o : out std_logic := '0';
      dc_ready_i : in  std_logic;
      dc_addr_o  : out std_logic_vector(15 downto 0);
      dc_data_o  : out std_logic_vector(15 downto 0);

      -- Receive a new PC from WRITE.  Every write to R15 is a branch, and
      -- WRITE forwards it here; the dc_ prefix on these two ports is historical
      -- and does NOT mean they come from DECODE.
      dc_valid_i : in  std_logic;
      dc_addr_i  : in  std_logic_vector(15 downto 0)
   );
end entity fetch;

architecture synthesis of fetch is

   -- Maximum number of instruction slots in flight.  This must not exceed the
   -- depth of either internal FIFO (both are two entries deep).
   constant C_MAX_PENDING : natural := 2;

   -- Handshake shorthands.  These are used both by the control logic and by
   -- the formal properties in fetch.psl.
   signal wb_req_accept : std_logic;   -- Request accepted by the slave
   signal wb_ack_any    : std_logic;   -- Any acknowledgement from the slave
   signal wb_rsp_accept : std_logic;   -- Response for a request still wanted
   signal dc_accept     : std_logic;   -- Instruction accepted by DECODE

   -- Requests accepted by the slave but not yet acknowledged.  This counts
   -- both live requests and the stale ones left behind by a redirect; the
   -- redirect below refuses the fast path when that would push the total past
   -- C_MAX_PENDING, so the bound is the same as it has always been.
   signal wb_outstanding : natural range 0 to C_MAX_PENDING := 0;

   -- Acknowledgements still owed for requests that a redirect abandoned.  The
   -- slave acknowledges in order, so these are the NEXT wb_stale acks to
   -- arrive, and each must be discarded rather than paired with an address
   -- from the new instruction stream.
   signal wb_stale : natural range 0 to C_MAX_PENDING := 0;

   -- Slots allocated: requests issued but whose instruction word has not yet
   -- been delivered to the DECODE stage.  Invariant:
   --    wb_pending = <STB waiting> + <address FIFO occupancy>
   --    <address FIFO occupancy> = <data buffer occupancy> + wb_outstanding
   signal wb_pending : natural range 0 to 3 := 0;

   signal tsf_in_addr_ready  : std_logic;
   signal tsf_in_addr_fill   : natural range 0 to 2;
   signal tsf_out_addr_valid : std_logic;
   signal tsf_out_addr_ready : std_logic;
   signal tsf_out_addr_data  : std_logic_vector(15 downto 0);

   signal tsb_in_data_ready  : std_logic;
   signal tsb_in_data_fill   : natural range 0 to 2;
   signal tsb_out_data_valid : std_logic;
   signal tsb_out_data_ready : std_logic;
   signal tsb_out_data_data  : std_logic_vector(15 downto 0);

begin

   -- A request is accepted when STB is high and the slave is not stalling.
   -- STB is only ever asserted together with CYC, so the CYC term is
   -- redundant, but it is kept for readability and protocol clarity.
   wb_req_accept <= wb_cyc_o and wb_stb_o and not wb_stall_i;
   wb_ack_any    <= wb_cyc_o and wb_ack_i;
   dc_accept     <= dc_valid_o and dc_ready_i;

   -- Only an acknowledgement that is not owed to an abandoned request carries
   -- an instruction word.  Everything downstream of this -- the data buffer,
   -- and therefore the address/data pairing -- sees the gated version.
   wb_rsp_accept <= wb_ack_any when wb_stale = 0 else '0';


   -- Control the wishbone request interface.
   --
   -- The process is written as an explicit transition function using
   -- variables, so that the ordering of the individual effects (accept,
   -- acknowledge, deliver, redirect, issue, terminate, reset) is unambiguous
   -- and each effect is applied to the already-updated state.
   --
   -- NOTE THE ORDER OF STEPS 4 AND 5.  The redirect runs BEFORE the issue, so
   -- that the issue picks up the new address; that ordering is what saves the
   -- cycle.  It used to be the other way round, with the redirect explicitly
   -- overriding the issue.
   p_wishbone : process (clk_i)
      variable cyc_v         : std_logic;
      variable stb_v         : std_logic;
      variable addr_v        : std_logic_vector(15 downto 0);
      variable outstanding_v : natural range 0 to C_MAX_PENDING;
      variable stale_v       : natural range 0 to C_MAX_PENDING;
      variable pending_v     : natural range 0 to 3;
      -- Set when the bus cycle has to be torn down rather than redirected,
      -- which suppresses the request that would otherwise be issued below.
      variable cancel_v      : boolean;
   begin
      if rising_edge(clk_i) then
         cyc_v         := wb_cyc_o;
         stb_v         := wb_stb_o;
         addr_v        := wb_addr_o;
         outstanding_v := wb_outstanding;
         stale_v       := wb_stale;
         pending_v     := wb_pending;
         cancel_v      := false;

         -- 1. The slave accepted the pending request.  Retire STB, advance the
         --    speculative address, and record the request as outstanding.
         if wb_req_accept = '1' then
            stb_v         := '0';
            addr_v        := addr_v + 1;
            outstanding_v := outstanding_v + 1;
         end if;

         -- 2. The slave returned a response, completing one outstanding
         --    request.  If that request was abandoned by an earlier redirect
         --    the response is dropped here and never reaches the data buffer;
         --    wb_rsp_accept is gated for exactly that reason.
         if wb_ack_any = '1' then
            outstanding_v := outstanding_v - 1;
            if stale_v > 0 then
               stale_v := stale_v - 1;
            end if;
         end if;

         -- 3. The DECODE stage accepted an instruction, releasing its slot.
         if dc_accept = '1' then
            pending_v := pending_v - 1;
         end if;

         -- 4. Redirect: a new PC from WRITE abandons everything in flight.
         --    This runs BEFORE the issue step below, so that the first request
         --    of the new instruction stream goes out on the very next cycle
         --    rather than the one after it -- one clock cycle off every branch.
         if dc_valid_i = '1' then
            addr_v    := dc_addr_i;
            pending_v := 0;

            if stb_v = '1' then
               -- A request is still waiting for the slave to accept it, i.e.
               -- the slave is stalling.  WISHBONE B4 lets the master neither
               -- withdraw STB nor alter the request while STALL is asserted,
               -- so the only way out is to tear the bus cycle down: drop CYC
               -- for at least one cycle, which cancels everything outstanding
               -- (interface contract (c)).  This costs the extra cycle that
               -- the fast path avoids, and cannot arise with a slave that
               -- never stalls -- the dual-port RAM this CPU is built around.
               cancel_v      := true;
               cyc_v         := '0';
               stb_v         := '0';
               outstanding_v := 0;
               stale_v       := 0;
            else
               -- Nothing is waiting for acceptance, so the bus cycle can be
               -- redirected instead of torn down.  Every request the slave has
               -- already taken still owes an acknowledgement; those are
               -- counted here and discarded as they arrive.  Note that
               -- outstanding_v already includes any stale acks left over from
               -- an earlier redirect, so assigning rather than adding is
               -- correct: everything outstanding is now stale.
               stale_v := outstanding_v;
            end if;
         end if;

         -- 5. Issue a new request whenever a slot is free and no request is
         --    already waiting to be accepted.  Because a slot is held from
         --    issue until delivery, pending_v bounds the occupancy of both
         --    internal FIFOs, so tsf_in_addr_ready and tsb_in_data_ready are
         --    guaranteed high whenever a push occurs.  They therefore do not
         --    need to be part of this condition.
         --    The budget counts stale acknowledgements as well as allocated
         --    slots.  A stale request occupies a slot on the BUS even though
         --    it no longer occupies one here, so without the stale_v term a
         --    redirect could push the number of unacknowledged requests past
         --    C_MAX_PENDING -- which is both an assertion in fetch.psl
         --    (f_wb_master_req_count_max) and a constraint on how much any
         --    slave has to be able to queue.  It costs nothing in practice:
         --    the stale count is back to zero within a cycle or two.
         if pending_v + stale_v < C_MAX_PENDING and stb_v = '0' and not cancel_v then
            cyc_v     := '1';
            stb_v     := '1';
            pending_v := pending_v + 1;
         end if;

         -- 6. Terminate the bus cycle once nothing is in flight.  CYC must be
         --    held for as long as a request is waiting to be accepted or an
         --    acknowledgement is still owed -- including one owed to a request
         --    that has been abandoned, since dropping CYC is what would cancel
         --    it and the whole point of step 4 is not to.
         if stb_v = '0' and outstanding_v = 0 then
            cyc_v := '0';
         end if;

         if rst_i = '1' then
            cyc_v         := '0';
            stb_v         := '0';
            addr_v        := (others => '0');
            outstanding_v := 0;
            stale_v       := 0;
            pending_v     := 0;
         end if;

         wb_cyc_o       <= cyc_v;
         wb_stb_o       <= stb_v;
         wb_addr_o      <= addr_v;
         wb_outstanding <= outstanding_v;
         wb_stale       <= stale_v;
         wb_pending     <= pending_v;
      end if;
   end process p_wishbone;


   -- FIFO to store the WISHBONE address
   i_two_stage_fifo_addr : entity work.two_stage_fifo
      generic map (
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i or dc_valid_i,
         s_valid_i => wb_req_accept,
         s_ready_o => tsf_in_addr_ready,
         s_data_i  => wb_addr_o,
         s_fill_o  => tsf_in_addr_fill,
         m_valid_o => tsf_out_addr_valid,
         m_ready_i => tsf_out_addr_ready,
         m_data_o  => tsf_out_addr_data
      ); -- i_two_stage_fifo_addr


   -- FIFO to store the WISHBONE data
   i_two_stage_buffer_data : entity work.two_stage_buffer
      generic map (
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i or dc_valid_i,
         s_valid_i => wb_rsp_accept,
         s_ready_o => tsb_in_data_ready,
         s_data_i  => wb_data_i,
         s_fill_o  => tsb_in_data_fill,
         m_valid_o => tsb_out_data_valid,
         m_ready_i => tsb_out_data_ready,
         m_data_o  => tsb_out_data_data
      ); -- i_two_stage_buffer_data


   -- Concatenate WISHBONE address and data
   i_pipe_concat : entity work.pipe_concat
      generic map (
         G_DATA0_SIZE => 16,
         G_DATA1_SIZE => 16
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i or dc_valid_i,
         s1_valid_i => tsf_out_addr_valid,
         s1_ready_o => tsf_out_addr_ready,
         s1_data_i  => tsf_out_addr_data,
         s0_valid_i => tsb_out_data_valid,
         s0_ready_o => tsb_out_data_ready,
         s0_data_i  => tsb_out_data_data,
         m_valid_o  => dc_valid_o,
         m_ready_i  => dc_ready_i,
         m_data_o(31 downto 16) => dc_addr_o,
         m_data_o(15 downto 0)  => dc_data_o
      ); -- i_pipe_concat

end architecture synthesis;

