library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- This is a simple buffer that is transparent (combinatorial) when the
-- receiver is ready, but registers the incoming value if not. Unlike
-- one_stage_fifo, data presented on s_data_i can reach m_data_o (and be
-- consumed) on the very same clock cycle -- there is zero cut-through
-- latency when the buffer is empty and the downstream is ready.
--
-- Ports:
-- * s_afull_o : combinatorial indicator that the single storage element is
--   currently occupied (m_valid_r = '1'). This is an "occupied" flag, NOT
--   the same thing as "not ready" -- s_ready_o can still be '1' in the same
--   cycle s_afull_o is '1', if the downstream is draining the buffer this
--   cycle (m_ready_i = '1'). Use s_ready_o, not s_afull_o, to gate whether
--   it is legal to present new data.
--
-- Preconditions / interface contract:
-- * clk_i / rst_i, and all s_*/m_* signals are assumed synchronous to clk_i.
--   No clock-domain-crossing handling is performed by this module.
-- * rst_i is a SYNCHRONOUS reset: it is only sampled on the rising edge of
--   clk_i. If an asynchronous reset source is used upstream, it must
--   already be synchronized/double-flopped before reaching this port.
-- * Upstream must hold s_valid_i='1' and keep s_data_i stable until
--   s_ready_o='1' is observed on a clock edge. This module does not detect
--   or flag violations of that contract in synthesis (see the
--   simulation-only check below).
-- * Downstream must not interpret m_data_o as meaningful while
--   m_valid_o='0'. m_data_r is intentionally NOT cleared by rst_i (only
--   m_valid_r is) -- so m_data_o may hold stale/undefined content
--   immediately after reset until the first valid write occurs.
-- * m_valid_r/m_data_r carry synthesis initial values ('0' / all-zero).
--   This assumes a target where power-up/GSR initial values are honored
--   (typical for FPGA flows). On targets where they are not (e.g. many ASIC
--   flows), correctness depends entirely on rst_i being asserted at least
--   once before first use -- do not rely on the initializers alone.
--
-- Timing note on chaining (important -- read before instantiating a chain):
-- This module differs from one_stage_fifo in that BOTH directions are
-- combinatorial when the buffer is empty:
-- * s_ready_o is combinatorial in m_ready_i (ready propagates backward).
-- * m_valid_o/m_data_o are combinatorial in s_valid_i/s_data_i (valid and
--   data propagate forward).
-- Chaining N instances back-to-back therefore creates, in the all-empty
-- case, an unbroken combinational path of length O(N) in BOTH directions
-- within a single clock cycle (valid+data rippling forward from source to
-- sink, ready rippling backward from sink to source). This is a materially
-- larger timing-closure risk than one_stage_fifo, where only the ready path
-- was combinatorial. Budget chain length against Fmax accordingly, and
-- consider breaking long chains periodically with a fully-registered stage.
-- Note this module does NOT itself violate the usual valid/ready
-- convention (m_valid_o does not depend on m_ready_i, and s_ready_o does
-- not depend on s_valid_i) -- but external logic that makes m_ready_i
-- depend combinatorially on this module's m_valid_o (or the symmetric case
-- upstream) would create a genuine combinational loop.

entity one_stage_buffer is
   generic (
      G_DATA_SIZE : integer := 8
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;  -- synchronous reset, active high
      s_valid_i : in  std_logic;
      s_ready_o : out std_logic;
      s_data_i  : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      s_afull_o : out std_logic;
      m_valid_o : out std_logic;
      m_ready_i : in  std_logic;
      m_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity one_stage_buffer;

architecture synthesis of one_stage_buffer is

   signal s_ready_s : std_logic;
   signal m_valid_r : std_logic := '0';
   signal m_data_r  : std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');

begin

   -- We accept data from upstream in two situations:
   -- * When the FIFO is empty.
   -- * When downstream is ready.
   -- The latter allows simultaneous read and write, even when full.
   --
   -- Gated with "and not rst_i": without this, once rst_i clears m_valid_r
   -- to '0' this expression would evaluate to '1' unconditionally for the
   -- whole reset period, telling upstream "accepted" while the reset
   -- process (below) simultaneously forces the transfer to be discarded --
   -- a silent data-loss path. Gating here ensures upstream is correctly
   -- told "not ready" for as long as rst_i is asserted.
   s_ready_s <= (m_ready_i or not m_valid_r) and not rst_i;

   p_buffer : process (clk_i)
   begin
      if rising_edge(clk_i) then

         -- Downstream has consumed the output, and no new data is
         -- replacing it this cycle: buffer goes empty.
         if m_ready_i = '1' and s_valid_i = '0' then
            m_valid_r <= '0';
         end if;

         -- Valid data on the input was accepted (s_ready_s='1'): capture
         -- it into the register. This covers both the "store because
         -- downstream isn't ready" case and the "full + simultaneous
         -- read/write" case, where the register must hold the new value
         -- for the following cycle even though m_valid_r itself doesn't
         -- change this cycle.
         if s_ready_s = '1' and s_valid_i = '1' then
            m_data_r  <= s_data_i;
         end if;

         -- Downstream wasn't ready this cycle, but data was accepted:
         -- buffer becomes (or remains) occupied.
         if m_ready_i = '0' and s_valid_i = '1' then
            m_valid_r <= '1';
         end if;

         -- Synchronous reset: empties the buffer by clearing the valid
         -- bit. Deliberately does NOT clear m_data_r (don't-care state
         -- per the valid/ready contract above). This assignment is
         -- evaluated last, so reset always wins even in a cycle where one
         -- of the blocks above would otherwise set m_valid_r.
         if rst_i = '1' then
            m_valid_r <= '0';
         end if;

      end if;
   end process p_buffer;

   -- pragma translate_off
   -- Simulation-only check: upstream must hold s_valid_i asserted and keep
   -- s_data_i stable until it is actually accepted (s_ready_s='1'). Has no
   -- effect on synthesis; exists purely to catch upstream protocol
   -- violations early, since a violation would otherwise silently corrupt
   -- data with no other indication.
   p_check_upstream_stability : process (clk_i)
   begin
      if rising_edge(clk_i) and rst_i = '0' then
         if s_valid_i = '1' and s_ready_s = '0' then
            assert (s_valid_i'stable(0 ns))
               report "one_stage_buffer: s_valid_i deasserted while stalled (s_ready_o was '0')"
               severity error;
         end if;
      end if;
   end process p_check_upstream_stability;
   -- pragma translate_on

   -- Connect output signals.
   -- m_valid_o combines the registered "buffer occupied" state with a
   -- combinatorial cut-through of s_valid_i, masked during reset -- this
   -- is what gives zero-latency passthrough when the buffer is empty.
   s_afull_o <= m_valid_r;
   s_ready_o <= s_ready_s;
   m_data_o  <= m_data_r when m_valid_r = '1' else s_data_i;
   m_valid_o <= (m_valid_r or s_valid_i) and not rst_i;

end architecture synthesis;

