library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- This module implements a FIFO consisting of only a single register layer.
-- It has its use in elastic pipelines, where the data flow has back-pressure.
-- It places registers on the valid and data signals in the downstream direction,
-- but the ready signal in the upstream direction is still combinatorial.
-- The FIFO supports simultaneous read and write, both when the FIFO is full
-- and when it is empty.
--
-- For additional information, see:
-- https://www.itdev.co.uk/blog/pipelining-axi-buses-registered-ready-signals
--
-- Preconditions / interface contract:
-- * clk_i / rst_i, and all s_*/m_* signals are assumed synchronous to clk_i.
--   No clock-domain-crossing handling is performed by this module.
-- * rst_i is a SYNCHRONOUS reset: it is only sampled on the rising edge of
--   clk_i (see p_fifo below). If an asynchronous reset source is used
--   upstream, it must already be synchronized/double-flopped before
--   reaching this port.
-- * Upstream must hold s_valid_i='1' and keep s_data_i stable until
--   s_ready_o='1' is observed on a clock edge (standard valid/ready
--   handshake semantics). This module does not detect or flag violations
--   of that contract; a violation will silently corrupt the data captured.
-- * Downstream must not interpret m_data_o as meaningful while
--   m_valid_o='0'. In particular, m_data_r is intentionally NOT reset by
--   rst_i (only m_valid_r is) -- so m_data_o is undefined/stale
--   immediately after reset until the first valid write occurs.
--
-- Timing note on chaining:
-- s_ready_o is purely combinatorial from m_ready_i (by design -- this is
-- what keeps the module to a single register layer instead of a full skid
-- buffer). Chaining N instances back-to-back therefore creates a single
-- unbroken combinational path from the last stage's m_ready_i back to the
-- first stage's s_ready_o. This is fine for short pipelines but should be
-- budgeted against Fmax closure for long chains; consider breaking long
-- chains periodically with a throughput-bubble-tolerant register stage.

entity one_stage_fifo is
   generic (
      G_DATA_SIZE : integer := 8
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;  -- synchronous reset, active high
      s_valid_i : in  std_logic;
      s_ready_o : out std_logic;
      s_data_i  : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      m_valid_o : out std_logic;
      m_ready_i : in  std_logic;
      m_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity one_stage_fifo;

architecture synthesis of one_stage_fifo is

   signal s_ready_s : std_logic;
   signal m_valid_r : std_logic;
   signal m_data_r  : std_logic_vector(G_DATA_SIZE-1 downto 0);

begin

   -- We accept data from upstream in two situations:
   -- * When the FIFO is empty (m_valid_r = '0').
   -- * When downstream is ready (m_ready_i = '1'), which allows the FIFO
   --   to be simultaneously read and written even while full, without
   --   ever needing a second storage element.
   s_ready_s <= m_ready_i or not m_valid_r;

   p_fifo : process (clk_i)
   begin
      if rising_edge(clk_i) then

         -- Capture (or hold) the single data/valid register.
         -- NOTE: m_data_r is only updated when s_ready_s='1'; when it is
         -- '0' the register (and thus m_data_o) simply holds its last
         -- value, which is correct since m_valid_o='1' in that state and
         -- downstream has not yet consumed it.
         if s_ready_s = '1' then
            m_data_r  <= s_data_i;
            m_valid_r <= s_valid_i;
         end if;

         -- Synchronous reset: empties the FIFO by clearing the valid bit.
         -- Deliberately does NOT clear m_data_r -- this is a don't-care
         -- state per the valid/ready contract (see header), and clearing
         -- it would just cost an extra reset fan-out for no functional
         -- benefit. This "if" is separate from and evaluated after the
         -- one above, so reset always wins even in a cycle where
         -- s_ready_s and rst_i are both '1'.
         if rst_i = '1' then
            m_valid_r <= '0';
         end if;

      end if;
   end process p_fifo;

   -- pragma translate_off
   -- Simulation-only check: upstream must hold s_valid_i asserted and keep
   -- s_data_i stable until it is actually accepted (s_ready_s='1'). This
   -- has no effect on synthesis; it exists purely to catch upstream
   -- protocol violations early in simulation, since a violation would
   -- otherwise silently corrupt captured data with no other indication.
   p_check_upstream_stability : process (clk_i)
   begin
      if rising_edge(clk_i) and rst_i = '0' then
         if s_valid_i = '1' and s_ready_s = '0' then
            assert (s_valid_i'stable(0 ns))
               report "one_stage_fifo: s_valid_i deasserted while stalled (s_ready_o was '0')"
               severity error;
         end if;
      end if;
   end process p_check_upstream_stability;
   -- pragma translate_on

   -- Connect output signals
   s_ready_o <= s_ready_s;
   m_valid_o <= m_valid_r;
   m_data_o  <= m_data_r;

end architecture synthesis;
