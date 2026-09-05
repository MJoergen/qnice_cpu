-- This module accepts a list of microcode instructions (in
-- s_stage_i.microcodes) and sequences them into fixed-width chunks
-- (in m_stage_o.microcodes), emitting one chunk per PREPARE beat.
--
-- It sits on the DECODE-to-PREPARE link, instantiated by cpu_main.vhd alongside
-- the two stages it joins rather than inside either of them: it is an elastic
-- one-to-many adapter, and has no part in either decoding an instruction or
-- preparing its operands.
--
-- One DECODE beat (s_valid_i) is expanded into N PREPARE beats
-- (m_valid_o), where N is the number of chunks up to and including the
-- chunk whose C_LAST bit is set. A new DECODE beat is not accepted until
-- the chunk marked 'last' has been accepted downstream.
--
-- It also joins the register file's two read ports (and the Status Register)
-- into the stage record on their way past. DECODE issues the read -- it owns
-- the register numbers -- but the values come back a cycle later, by which time
-- the instruction is already in DECODE's output register and on its way through
-- here, so the values are wired straight from REGISTERS to this module rather
-- than through DECODE. They are deliberately NOT registered anywhere: a value
-- must stay live while the sequence is being issued, because the older
-- instruction still in WRITE (or the previous micro-op of this very one, as in
-- "ADD @R0++, @R0++") can write the register in the meantime, and the register
-- file's write-before-read bypass then puts the new value on the read port.
-- See "Waveforms" in README.md.
--
-- CONTRACT: The C_LAST bit MUST be set in the top chunk of the list, i.e. no
-- later than chunk index C_NUM_CHUNKS-1 (= 2 for the current 36-bit
-- 'microcodes' field, which holds three 12-bit chunks). One chunk beyond that
-- would push 'index' past its subtype range and slice 'microcodes' out of
-- bounds. This contract is enforced formally in sequencer.psl (see the
-- "index = C_NUM_CHUNKS-1 |-> last" assume).

library ieee;
   use ieee.std_logic_1164.all;

   use work.cpu_constants.t_dec2seq;
   use work.cpu_constants.t_seq2prep;
   use work.cpu_constants.C_LAST;
   use work.cpu_constants.C_UCODE_BITS;

entity sequencer is
   port (
      clk_i         : in  std_logic;
      rst_i         : in  std_logic;
      -- Connect to DECODE
      s_valid_i     : in  std_logic;
      s_ready_o     : out std_logic;
      s_stage_i     : in  t_dec2seq;
      -- Connect to REGISTERS. Values only; DECODE drives the read ports.
      reg_src_val_i : in  std_logic_vector(15 downto 0);
      reg_dst_val_i : in  std_logic_vector(15 downto 0);
      reg_r14_i     : in  std_logic_vector(15 downto 0);
      -- Connect to PREPARE
      m_valid_o     : out std_logic;
      m_ready_i     : in  std_logic;
      m_stage_o     : out t_seq2prep
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
   s_ready_o <= '0' when m_valid_o = '1' and m_stage_o.microcode(C_LAST) = '0' else
                m_ready_i;

   -- Advance the chunk index on every accepted PREPARE beat, wrapping back
   -- to 0 once the 'last' chunk has been accepted.
   p_index : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if m_valid_o = '1' and m_ready_i = '1' then
            if m_stage_o.microcode(C_LAST) = '1' then
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
   -- 'microcode' is the one chunk this beat carries, sliced out of the list on
   -- the input; the input and output records are different types precisely so
   -- that the unselected chunks cannot leave this module. They used to: the
   -- output was a copy of the input with the low C_UCODE_BITS overwritten, and
   -- the upper bits still held the raw list, with a comment obliging every
   -- reader downstream to slice before use.
   --
   -- The twelve elements after it are DECODE's, forwarded unchanged. They are
   -- copied one by one rather than by a whole-record assignment, which the two
   -- types no longer allow -- the price of the split.
   --
   -- The last three are filled in from the register file here, one clock cycle
   -- after DECODE presented reg_src_addr_o/reg_dst_addr_o; they do not exist on
   -- the DECODE link at all.
   p_output : process (all)
   begin
      m_valid_o <= s_valid_i;

      m_stage_o.microcode <=
         s_stage_i.microcodes((index + 1) * C_UCODE_BITS - 1 downto index * C_UCODE_BITS);

      m_stage_o.addr      <= s_stage_i.addr;
      m_stage_o.inst      <= s_stage_i.inst;
      m_stage_o.immediate <= s_stage_i.immediate;
      m_stage_o.src_addr  <= s_stage_i.src_addr;
      m_stage_o.src_mode  <= s_stage_i.src_mode;
      m_stage_o.src_imm   <= s_stage_i.src_imm;
      m_stage_o.dst_addr  <= s_stage_i.dst_addr;
      m_stage_o.dst_mode  <= s_stage_i.dst_mode;
      m_stage_o.dst_imm   <= s_stage_i.dst_imm;
      m_stage_o.res_reg   <= s_stage_i.res_reg;
      m_stage_o.is_crb    <= s_stage_i.is_crb;
      m_stage_o.early_jmp <= s_stage_i.early_jmp;

      m_stage_o.src_reg_val <= reg_src_val_i;
      m_stage_o.dst_reg_val <= reg_dst_val_i;
      m_stage_o.r14         <= reg_r14_i;
   end process p_output;

end architecture synthesis;

