-- This module accepts a list of microcode instructions (in
-- s_stage_i.microcodes) and sequences them into fixed-width chunks
-- (in m_stage_o.microcodes), emitting one chunk per PREPARE beat.
--
-- One DECODE beat (s_valid_i) is expanded into N PREPARE beats
-- (m_valid_o), where N is the number of chunks up to and including the
-- chunk whose C_LAST bit is set. A new DECODE beat is not accepted until
-- the chunk marked 'last' has been accepted downstream.
--
-- CONTRACT: The C_LAST bit MUST be set in the top chunk of the list, i.e. no
-- later than chunk index C_NUM_CHUNKS-1 (= 2 for the current 36-bit
-- 'microcodes' field, which holds three 12-bit chunks). One chunk beyond that
-- would push 'index' past its subtype range and slice 'microcodes' out of
-- bounds. This contract is enforced formally in sequencer.psl (see the
-- "index = C_NUM_CHUNKS-1 |-> last" assume).

library ieee;
   use ieee.std_logic_1164.all;

   use work.cpu_constants.t_stage;
   use work.cpu_constants.C_LAST;
   use work.cpu_constants.C_UCODE_BITS;

entity sequencer is
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;
      -- Connect to DECODE
      s_valid_i : in  std_logic;
      s_ready_o : out std_logic;
      s_stage_i : in  t_stage;
      -- Connect to PREPARE
      m_valid_o : out std_logic;
      m_ready_i : in  std_logic;
      m_stage_o : out t_stage
   );
end entity sequencer;

architecture synthesis of sequencer is

   -- Number of microcode chunks carried by one DECODE beat, derived from the
   -- width of the 'microcodes' field (36 bits / 12 bits per chunk = 3).
   constant C_NUM_CHUNKS : positive := s_stage_i.microcodes'length / C_UCODE_BITS;

   -- Index of the chunk currently being presented on m_stage_o (see CONTRACT).
   signal index : natural range 0 to C_NUM_CHUNKS - 1 := 0;

begin

   -- Elaboration-time sanity check: the C_LAST flag must live inside the
   -- low chunk slice that p_output overwrites; otherwise 'last' would be
   -- read from a stale upper bit of the raw, unselected microcode list.
   assert C_LAST < C_UCODE_BITS
      report "C_LAST must be inside the chunk slice (C_LAST < C_UCODE_BITS)"
      severity failure;

   -- Elaboration-time sanity check: the list must divide evenly into chunks,
   -- otherwise the top chunk would slice past the end of 'microcodes'.
   assert s_stage_i.microcodes'length = C_NUM_CHUNKS * C_UCODE_BITS
      report "'microcodes' width must be a whole multiple of C_UCODE_BITS"
      severity failure;

   -- Accept a new sequence only when the microcode chunk marked 'last' is
   -- being accepted. While a non-last chunk is presented, hold s_ready_o
   -- low so DECODE keeps the same list stable across the whole sequence.
   s_ready_o <= '0' when m_valid_o = '1' and m_stage_o.microcodes(C_LAST) = '0' else
                m_ready_i;

   -- Advance the chunk index on every accepted PREPARE beat, wrapping back
   -- to 0 once the 'last' chunk has been accepted.
   p_index : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if m_valid_o = '1' and m_ready_i = '1' then
            if m_stage_o.microcodes(C_LAST) = '1' then
               index <= 0;
            else
               index <= index + 1;
            end if;
         end if;

         if rst_i = '1' then
            index <= 0;
         end if;
      end if;
   end process p_index;


   -- Combinatorial output, to avoid inserting latency into the pipeline.
   --
   -- The full input stage is forwarded first (this also carries any fields
   -- other than 'microcodes'), then the low C_UCODE_BITS slice of
   -- 'microcodes' is overwritten with the selected chunk. NOTE: the upper
   -- bits of m_stage_o.microcodes still hold the raw, unselected list;
   -- downstream logic MUST consume only bits (C_UCODE_BITS-1 downto 0).
   p_output : process (all)
   begin
      m_valid_o <= s_valid_i;
      m_stage_o <= s_stage_i;
      m_stage_o.microcodes(C_UCODE_BITS - 1 downto 0) <=
         s_stage_i.microcodes((index + 1) * C_UCODE_BITS - 1 downto index * C_UCODE_BITS);
   end process p_output;

end architecture synthesis;

