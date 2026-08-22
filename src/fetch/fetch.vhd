library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

-- A simple instruction fetch unit.
--
-- This unit has four interfaces:
-- 1. Sending read requests to WISHBONE (with possible backpressure)
-- 2. Receiving read responses from WISHBONE
-- 3. Sending instructions to DECODE stage (with possible backpressure)
-- 4. Receiving a new PC from DECODE
--
-- THEORY OF OPERATION
-- The unit speculatively fetches a linear sequence of instructions starting at
-- the address most recently supplied by the DECODE stage.  Each WISHBONE read
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
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) dc_valid_i is an unconditional, single-cycle flush.  It has no
--    backpressure and takes effect immediately: the current WISHBONE
--    transaction is aborted, both internal FIFOs are cleared, and fetching
--    restarts at dc_addr_i.
-- b) The DECODE stage MUST supply a new PC (dc_valid_i) before any fetched
--    instruction is meaningful.  wb_addr_o is reset to zero, so without a new
--    PC the unit will start fetching from address 0.
-- c) The attached WISHBONE slave MUST NOT assert ACK after CYC has been
--    deasserted (WISHBONE B4, pipelined mode).  Deasserting CYC terminates the
--    bus cycle and cancels all outstanding requests.  A slave that acknowledges
--    a cancelled request would cause silent instruction corruption, because
--    the stale response would be paired with the address of a new request.
--
-- RESET
-- All state is synchronously reset by rst_i.  No clock domain crossing is
-- present; all ports are synchronous to clk_i.

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

      -- Send instruction to DECODE
      dc_valid_o : out std_logic := '0';
      dc_ready_i : in  std_logic;
      dc_addr_o  : out std_logic_vector(15 downto 0);
      dc_data_o  : out std_logic_vector(15 downto 0);

      -- Receive a new PC from DECODE
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
   signal wb_rsp_accept : std_logic;   -- Response delivered by the slave
   signal dc_accept     : std_logic;   -- Instruction accepted by DECODE

   -- Requests accepted by the slave but not yet acknowledged.
   signal wb_outstanding : natural range 0 to 3 := 0;

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
   wb_rsp_accept <= wb_cyc_o and wb_ack_i;
   dc_accept     <= dc_valid_o and dc_ready_i;


   -- Control the wishbone request interface.
   --
   -- The process is written as an explicit transition function using
   -- variables, so that the ordering of the individual effects (accept,
   -- acknowledge, deliver, issue, terminate, abort, reset) is unambiguous and
   -- each effect is applied to the already-updated state.
   p_wishbone : process (clk_i)
      variable cyc_v         : std_logic;
      variable stb_v         : std_logic;
      variable addr_v        : std_logic_vector(15 downto 0);
      variable outstanding_v : natural range 0 to 3;
      variable pending_v     : natural range 0 to 3;
   begin
      if rising_edge(clk_i) then
         cyc_v         := wb_cyc_o;
         stb_v         := wb_stb_o;
         addr_v        := wb_addr_o;
         outstanding_v := wb_outstanding;
         pending_v     := wb_pending;

         -- 1. The slave accepted the pending request.  Retire STB, advance the
         --    speculative address, and record the request as outstanding.
         if wb_req_accept = '1' then
            stb_v         := '0';
            addr_v        := addr_v + 1;
            outstanding_v := outstanding_v + 1;
         end if;

         -- 2. The slave returned a response, completing one outstanding
         --    request.  The response data is captured by the data buffer.
         if wb_rsp_accept = '1' then
            outstanding_v := outstanding_v - 1;
         end if;

         -- 3. The DECODE stage accepted an instruction, releasing its slot.
         if dc_accept = '1' then
            pending_v := pending_v - 1;
         end if;

         -- 4. Issue a new request whenever a slot is free and no request is
         --    already waiting to be accepted.  Because a slot is held from
         --    issue until delivery, pending_v bounds the occupancy of both
         --    internal FIFOs, so tsf_in_addr_ready and tsb_in_data_ready are
         --    guaranteed high whenever a push occurs.  They therefore do not
         --    need to be part of this condition.
         if pending_v < C_MAX_PENDING and stb_v = '0' then
            cyc_v     := '1';
            stb_v     := '1';
            pending_v := pending_v + 1;
         end if;

         -- 5. Terminate the bus cycle once nothing is in flight.  CYC must be
         --    held for as long as a request is waiting to be accepted or an
         --    acknowledgement is still owed.
         if stb_v = '0' and outstanding_v = 0 then
            cyc_v := '0';
         end if;

         -- 6. Abort: a new PC from DECODE cancels everything in flight.
         --    Deasserting CYC for at least one cycle terminates the current
         --    WISHBONE cycle; see interface contract (c) above.  This is
         --    applied last so that it overrides any request issued in step 4.
         if dc_valid_i = '1' then
            cyc_v         := '0';
            stb_v         := '0';
            addr_v        := dc_addr_i;
            outstanding_v := 0;
            pending_v     := 0;
         end if;

         if rst_i = '1' then
            cyc_v         := '0';
            stb_v         := '0';
            addr_v        := (others => '0');
            outstanding_v := 0;
            pending_v     := 0;
         end if;

         wb_cyc_o       <= cyc_v;
         wb_stb_o       <= stb_v;
         wb_addr_o      <= addr_v;
         wb_outstanding <= outstanding_v;
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

