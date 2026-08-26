-- An elastic pipeline with two stages. I.e. can accept two writes before blocking.
-- In other words, a FIFO of depth two.
--
-- THEORY OF OPERATION
-- The FIFO has exactly two storage slots, ordered from input to output:
--
--    s_data_r : input slot,  occupied iff s_ready_r = '0' (i.e. FIFO is full)
--    m_data_r : output slot, occupied iff m_valid_r = '1'
--
-- Note that s_data_r is written on EVERY cycle where s_ready_r = '1',
-- irrespective of s_valid_i, so it routinely holds data that was never
-- accepted. Its contents are meaningful only while the FIFO is full.
--
-- The occupancy is fully determined by the two control registers, which is why
-- s_fill_o is derived combinationally from them rather than from a separate
-- counter. The encoding is:
--
--    0 : empty
--    1 : one word held, room for one more
--    2 : full
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
--
-- a) rst_i MAY ALSO BE USED AS A PIPELINE FLUSH. Several users of this module
--    (e.g. the instruction fetch unit) drive rst_i with the OR of the global
--    reset and a redirect signal, so rst_i can pulse during normal operation.
--    To make that safe, s_ready_o is gated combinationally by rst_i: no input
--    handshake can complete during a flush cycle. Without the gate the FIFO
--    would signal acceptance of a word that is discarded at the very next
--    clock edge, and the upstream -- believing the word was taken -- would
--    never present it again. That is silent data loss.
--
-- b) m_valid_o is deliberately NOT gated by rst_i. A flush cycle may
--    therefore still complete an OUTPUT handshake, handing one word downstream
--    that the flush is about to discard. This is not data loss -- the word
--    genuinely existed -- but it does mean the downstream stage must be reset
--    by the same signal, so that it discards the word too. In other words,
--    rst_i must be common to this module and its consumer. Gating m_valid_o
--    as well would remove that requirement, at the cost of dropping m_valid_o
--    mid-transfer, which breaks the output stability guarantee for any
--    consumer that is NOT reset simultaneously. The shared-reset convention
--    is the intended one.
--
-- c) An offered input word must be held stable until accepted: while
--    s_valid_i = '1' and s_ready_o = '0', neither s_valid_i nor s_data_i may
--    change.
--
-- RESET
-- All state is synchronously reset by rst_i, with the combinational gating of
-- s_ready_o noted above. No clock domain crossing is present; all ports are
-- synchronous to clk_i.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity two_stage_fifo is
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
end entity two_stage_fifo;

architecture synthesis of two_stage_fifo is

   -- Input registers
   signal s_data_r : std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');

   -- Output registers
   signal m_data_r : std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');

   -- Control signals
   signal s_ready_r : std_logic := '1';
   signal m_valid_r : std_logic := '0';

begin

   -- Occupancy is reported from the REGISTERS, not from the gated s_ready_o
   -- output. Deriving it from s_ready_o would make a flush cycle report the
   -- FIFO as full, since the gate forces s_ready_o low; the stored occupancy
   -- has not actually changed at that point.
   s_fill_o <= 0 when m_valid_r = '0' else
               1 when m_valid_r = '1' and s_ready_r = '1' else
               2; --  when m_valid_r = '1' and s_ready_r = '0'


   p_s_data : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if s_ready_r = '1' then
            s_data_r  <= s_data_i;
         end if;
      end if;
   end process p_s_data;


   -- Note that this process only updates s_ready_r while m_valid_r is high.
   -- That is sound because of the invariant "an empty FIFO is always ready"
   -- (m_valid_r = '0' implies s_ready_r = '1'); the state
   -- (m_valid_r = '0', s_ready_r = '0') would be a permanent deadlock, as the
   -- only process able to raise s_ready_r is gated off in it. That state is
   -- unreachable from reset -- see f_inv_empty_ready in two_stage_fifo.psl,
   -- which asserts it explicitly so that k-induction cannot assume it.
   p_s_ready : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if m_valid_r = '1' then
            s_ready_r <= m_ready_i or (s_ready_r and not s_valid_i);
         end if;

         if rst_i = '1' then
            s_ready_r <= '1';
         end if;
      end if;
   end process p_s_ready;


   p_m : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if s_ready_r = '1' then
            if m_valid_r = '0' or m_ready_i = '1' then
               m_valid_r <= s_valid_i;
               m_data_r  <= s_data_i;
            end if;
         else
            if m_ready_i = '1' then
               m_data_r  <= s_data_r;
            end if;
         end if;

         if rst_i = '1' then
            m_valid_r <= '0';
         end if;
      end if;
   end process p_m;


   ------------------------------------------------------------
   -- Connect output signals
   ------------------------------------------------------------

   -- Gated by rst_i so that no input handshake completes during a reset or
   -- flush cycle; see interface contract (a). Note that rst_i is synchronous,
   -- so without this gate s_ready_o would still show the pre-reset value
   -- throughout the reset cycle and could accept a word that the reset then
   -- discards at the clock edge.
   s_ready_o <= s_ready_r and not rst_i;


   m_valid_o <= m_valid_r;
   m_data_o  <= m_data_r;

end architecture synthesis;

