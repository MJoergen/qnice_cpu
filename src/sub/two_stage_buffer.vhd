-- An elastic pipeline with two stages, with zero latency.
-- It can accept two writes before blocking, i.e. a FIFO of depth two.
--
-- This is built by chaining two one_stage_buffer instances: the first
-- ("i_one_stage_buffer_first") interfaces to the external upstream (s_valid_i/s_ready_o/
-- s_data_i), and the second ("i_one_stage_buffer_second") interfaces to the external
-- downstream (m_valid_o/m_ready_i/m_data_o). Data may cut through both
-- stages combinatorially in the same cycle when both are empty and the
-- downstream is ready -- see one_stage_buffer's header for the timing
-- implications of that (both directions become combinatorial when empty).
--
-- s_fill_o reports the number of items currently stored (0, 1, or 2).
-- Its priority-mux
-- implementation relies on an invariant that is NOT locally visible in this
-- file: the pipeline always fills "from the back", i.e. the first stage
-- (s_afull) can only be occupied while the second stage (int_afull) is
-- also occupied. The seemingly-missing combination (s_afull='1',
-- int_afull='0') is therefore unreachable, not overlooked -- s_fill_o's
-- 0 branch only checks int_afull for exactly this reason. This
-- invariant, along with the rest of this module's handshake behavior, is
-- formally proven (BMC + induction) in the accompanying two_stage_buffer.psl
-- (see f_internal in particular). Any RTL change here should be re-checked
-- against that file, not just re-simulated.

library ieee;
   use ieee.std_logic_1164.all;

entity two_stage_buffer is
   generic (
      G_DATA_SIZE : integer := 8
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;
      s_valid_i : in  std_logic;
      s_ready_o : out std_logic;
      s_data_i  : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      s_fill_o  : out natural range 0 to 2;
      m_valid_o : out std_logic;
      m_ready_i : in  std_logic;
      m_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity two_stage_buffer;

architecture synthesis of two_stage_buffer is

   -- int_* signals connect the first stage's output to the second stage's
   -- input (i.e. the internal, not externally visible, handshake).
   signal int_valid : std_logic;
   signal int_ready : std_logic;
   signal int_data  : std_logic_vector(G_DATA_SIZE-1 downto 0);

   -- int_afull : occupancy of the SECOND (downstream-facing) stage.
   -- s_afull   : occupancy of the FIRST (upstream-facing) stage.
   -- See the header comment above: int_afull='0' implies s_afull='0'
   -- (proven in two_stage_buffer.psl / f_internal), which is what makes
   -- the s_fill_o encoding below well-defined.
   signal int_afull : std_logic;
   signal s_afull   : std_logic;

begin

   s_fill_o <= 0 when int_afull = '0' else
               1 when s_afull = '0' else
               2;

   -- First stage: accepts data from the external upstream interface.
   i_one_stage_buffer_first : entity work.one_stage_buffer
      generic map (
         G_DATA_SIZE => G_DATA_SIZE
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         s_valid_i => s_valid_i,
         s_ready_o => s_ready_o,
         s_data_i  => s_data_i,
         s_afull_o => s_afull,
         m_valid_o => int_valid,
         m_ready_i => int_ready,
         m_data_o  => int_data
      ); -- i_one_stage_buffer_first

   -- Second stage: drives the external downstream interface. May accept
   -- and immediately forward (cut through) data from the first stage
   -- combinatorially within the same cycle when it is itself empty.
   i_one_stage_buffer_second : entity work.one_stage_buffer
      generic map (
         G_DATA_SIZE => G_DATA_SIZE
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         s_valid_i => int_valid,
         s_ready_o => int_ready,
         s_data_i  => int_data,
         s_afull_o => int_afull,
         m_valid_o => m_valid_o,
         m_ready_i => m_ready_i,
         m_data_o  => m_data_o
      ); -- i_one_stage_buffer_second

end architecture synthesis;

