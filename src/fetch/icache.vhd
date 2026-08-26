-- A small instruction buffer sitting between the instruction FETCH stage and
-- the DECODE stage.
--
-- THEORY OF OPERATION
-- The module buffers up to two consecutive instruction words. The DECODE
-- stage needs to see two words at once, because an instruction may be followed
-- by an immediate operand occupying the following word. DECODE cannot know
-- whether the second word is an operand until it has decoded the first, so it
-- reports back - combinatorially, in the same cycle as the handshake - how
-- many words it actually consumed:
--
--    m_double_i = '0' : one word consumed  (no immediate operand)
--    m_double_i = '1' : two words consumed (instruction plus operand)
--
-- m_double_o indicates how many words are currently OFFERED. DECODE may only
-- assert m_double_i when two words are offered; consuming two words when only
-- one is available is a protocol violation.
--
-- Buffer occupancy is fully determined by the output handshake signals, which
-- is why the internal signal "count" is derived combinatorially from
-- m_valid_o/m_double_o rather than being a separate register.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
--
-- a) rst_i IS ALSO THE PIPELINE FLUSH. It must be driven by the logical OR of
--    the global reset and the FETCH stage's redirect signal (fetch.dc_valid_i),
--    exactly as the DECODE stage's reset is. This is not a convenience: when
--    FETCH is redirected to a new PC it discards its own buffers, so any words
--    still held here belong to the abandoned instruction stream and MUST be
--    discarded in the SAME clock cycle. Failing to do so delivers one or two
--    stale instructions to DECODE after every taken branch.
--
--    Consequently rst_i pulses during normal operation, not merely at startup.
--    All logic below is written with that in mind:
--      - m_valid_o is gated combinatorially by rst_i, so the flush takes
--        effect in the same cycle and DECODE never observes a stale word.
--      - s_ready_o is likewise gated, so no input handshake completes during a
--        flush cycle. Without this the module would signal acceptance of a
--        word it is about to discard. This is safe with respect to FETCH,
--        which is discarding that word too.
--      - m_double is cleared on reset alongside m_valid, so m_double_o can
--        never be left asserted while m_valid_o is low.
--
-- b) The words arriving on the input port must be CONSECUTIVE in address. The
--    "second word is the immediate operand" interpretation is only meaningful
--    for a gapless, increasing address stream. FETCH guarantees this between
--    redirects.
--
-- c) m_double_i must only be asserted when m_valid_o = '1' and m_double_o = '1'.
--
-- RESET
-- All state is synchronously reset by rst_i, with the combinational gating of
-- m_valid_o and s_ready_o noted above. No clock domain crossing is present;
-- all ports are synchronous to clk_i.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity icache is
   generic (
      G_ADDR_SIZE : integer;
      G_DATA_SIZE : integer
   );
   port (
      clk_i      : in  std_logic;

      -- Synchronous reset AND pipeline flush; see interface contract (a).
      rst_i      : in  std_logic;

      -- From Instruction fetch
      s_valid_i  : in  std_logic;
      s_ready_o  : out std_logic;
      s_addr_i   : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      s_data_i   : in  std_logic_vector(G_DATA_SIZE-1 downto 0);

      -- To Decode
      -- m_valid_o and m_ready_i are the usual handshaking signals, m_addr_o is
      -- the address of the current instruction, and m_data_o contains one or
      -- two words of data, as indicated by m_double_o. In either case
      -- data(G_DATA_SIZE-1 downto 0) is the instruction, and
      -- data(2*G_DATA_SIZE-1 downto G_DATA_SIZE) is the immediate operand if
      -- present (i.e. the word following the instruction). In conjunction
      -- with m_ready_i, the signal m_double_i indicates whether one or two
      -- words are consumed in this clock cycle. Therefore m_double_i must
      -- depend combinatorially on the output signals.
      m_valid_o  : out std_logic;
      m_ready_i  : in  std_logic;
      m_double_o : out std_logic;
      m_addr_o   : out std_logic_vector(G_ADDR_SIZE-1 downto 0);
      m_data_o   : out std_logic_vector(2 * G_DATA_SIZE-1 downto 0);
      m_double_i : in  std_logic
   );
end entity icache;

architecture synthesis of icache is

   -- Number of words currently buffered. Derived combinatorially from the
   -- output handshake signals rather than held in a register, so it cannot
   -- disagree with what is being offered to DECODE. Note that m_valid_o is
   -- already gated by rst_i, hence count is 0 throughout a flush cycle.
   signal count : integer range 0 to 2;

   -- Slot 0 occupies the low half of each vector and holds the older word;
   -- slot 1 occupies the high half and holds the newer word. The upper half
   -- of m_addr is never driven off-chip -- it is retained because it makes the
   -- slot-1-to-slot-0 shift below a uniform vector operation, and because it
   -- lets the formal properties check that the two buffered addresses really
   -- are consecutive.
   signal m_addr   : std_logic_vector(2 * G_ADDR_SIZE-1 downto 0) := (others => '0');
   signal m_data   : std_logic_vector(2 * G_DATA_SIZE-1 downto 0) := (others => '0');
   signal m_valid  : std_logic                                      := '0';
   signal m_double : std_logic                                      := '0';

begin

   count <= 0 when m_valid_o = '0' else
            1 when m_valid_o = '1' and m_double_o = '0' else
            2;

   -- Accept a new word whenever a slot is free, or whenever the buffer is full
   -- but at least one word is leaving this cycle. Gated by rst_i so that no
   -- handshake completes during a flush; see interface contract (a).
   --
   -- Note that this creates a combinational path from m_ready_i to s_ready_o,
   -- i.e. a ready-to-ready path across the stage, while contract (c) creates a
   -- combinational path from m_valid_o/m_double_o back to m_double_i. Neither
   -- forms a loop in the intended system, because FETCH's output valid does
   -- not depend on its input ready, but both are worth keeping in mind for
   -- timing closure.
   s_ready_o <= '0' when rst_i = '1' else
                '1' when count = 0 or count = 1 or (count = 2 and m_ready_i = '1') else
                '0';

   -- The flush must be visible to DECODE in the same cycle it is applied,
   -- hence the combinational gating here rather than relying on the register.
   m_valid_o  <= m_valid and not rst_i;
   m_double_o <= m_double and not rst_i;
   m_addr_o   <= m_addr(G_ADDR_SIZE-1 downto 0);
   m_data_o   <= m_data;


   -- NOTE ON ASSIGNMENT ORDERING
   -- In the count=1 and count=2 branches below, the output-side block and the
   -- input-side block may both assign m_valid/m_double/m_addr/m_data in the
   -- same cycle. This is deliberate: the input-side block is written second
   -- so that last-assignment-wins gives it priority, which is what makes the
   -- simultaneous-in-and-out cases correct. Do not reorder these blocks.
   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then

         case count is

            when 0 =>
               -- Buffer empty: a new word fills slot 0.
               if s_valid_i = '1' and s_ready_o = '1' then
                  m_addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                  m_data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                  m_valid                          <= '1';
                  m_double                         <= '0';
               end if;

            when 1 =>
               -- One word buffered. Only a single word is offered, so
               -- m_double_i is irrelevant here and is deliberately ignored:
               -- a handshake always consumes exactly the one word in slot 0.
               if m_ready_i = '1' then
                  m_valid  <= '0';
                  m_double <= '0';
               end if;

               if s_valid_i = '1' and s_ready_o = '1' then
                  if m_ready_i = '1' then
                     -- The buffered word leaves as the new one arrives, so the
                     -- new word takes its place in slot 0.
                     m_addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                     m_data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                     m_valid                          <= '1';
                     m_double                         <= '0';
                  else
                     -- Nothing leaves; the new word fills slot 1 and both
                     -- words are then offered together.
                     m_addr(2 * G_ADDR_SIZE-1 downto G_ADDR_SIZE) <= s_addr_i;
                     m_data(2 * G_DATA_SIZE-1 downto G_DATA_SIZE) <= s_data_i;
                     m_valid                                        <= '1';
                     m_double                                       <= '1';
                  end if;
               end if;

            when 2 =>
               -- Two words buffered and both offered. m_double_i now selects
               -- whether DECODE consumes one word or both.
               if m_ready_i = '1' then
                  if m_double_i = '1' then
                     -- Both words consumed; buffer drains completely. Clearing
                     -- m_double here is essential, not cosmetic: without it the
                     -- flag survives the drain and m_double_o is left asserted
                     -- while m_valid_o is low, which DECODE is entitled to
                     -- sample combinatorially.
                     m_valid  <= '0';
                     m_double <= '0';
                  else
                     -- Only the instruction consumed; the operand candidate in
                     -- slot 1 shifts down and becomes the next instruction.
                     m_addr(G_ADDR_SIZE-1 downto 0) <= m_addr(2 * G_ADDR_SIZE-1 downto G_ADDR_SIZE);
                     m_data(G_DATA_SIZE-1 downto 0) <= m_data(2 * G_DATA_SIZE-1 downto G_DATA_SIZE);
                     m_valid                          <= '1';
                     m_double                         <= '0';
                  end if;
               end if;

               -- s_ready_o is only high in this state when m_ready_i is high,
               -- so reaching this block implies a word is leaving as well.
               if s_valid_i = '1' and s_ready_o = '1' then
                  if m_double_i = '1' then
                     -- Two out, one in: the arriving word lands in slot 0.
                     m_addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                     m_data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                     m_valid                          <= '1';
                     m_double                         <= '0';
                  else
                     -- One out, one in: slot 1 shifted down above, and the
                     -- arriving word refills slot 1.
                     m_addr(2 * G_ADDR_SIZE-1 downto G_ADDR_SIZE) <= s_addr_i;
                     m_data(2 * G_DATA_SIZE-1 downto G_DATA_SIZE) <= s_data_i;
                     m_valid                                        <= '1';
                     m_double                                       <= '1';
                  end if;
               end if;

            when others =>
               null;

         end case;

         -- Reset and flush. Applied last so that it overrides every branch
         -- above. Clearing m_double as well as m_valid guarantees that
         -- m_double_o is never left asserted while m_valid_o is low. The
         -- address and data registers are deliberately not cleared: they are
         -- meaningless while m_valid is low, and clearing them would cost
         -- flops for no benefit.
         if rst_i = '1' then
            m_valid  <= '0';
            m_double <= '0';
         end if;

      end if;
   end process p_fsm;

end architecture synthesis;

