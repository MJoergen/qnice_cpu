-- pipe_concat - Concatenate (join) two elastic pipelines into one
--
-- THEORY OF OPERATION
--   This is a purely combinational "join" primitive: it merges two independent
--   elastic (valid/ready handshaked) input streams s0 and s1 into a single
--   output stream m whose payload is the concatenation of the two inputs.
--
--   A single output beat is offered only when BOTH inputs present a beat
--   simultaneously, and both inputs are consumed on exactly the same cycle the
--   output beat is accepted. Hence no data is buffered, dropped, duplicated, or
--   reordered - the module is a zero-latency, zero-storage combinational join.
--
-- HANDSHAKE ALGEBRA
--   m_valid_o  = s0_valid_i and s1_valid_i   -- offer output only when both ready
--   s0_ready_o = m_ready_i  and s1_valid_i   -- consume s0 only when beat transfers
--   s1_ready_o = m_ready_i  and s0_valid_i   -- consume s1 only when beat transfers
--
--   From these it follows that an input transfer occurs iff the output transfers:
--     (s0_valid and s0_ready) = (s1_valid and s1_ready) = (m_valid and m_ready)
--   which is the defining invariant of a lossless, in-order join.
--
--   Note: by this definition s0_ready_o may assert while s0_valid_i is low (and
--   likewise for s1). This is legal AXI-Stream style behaviour (ready may lead
--   valid); the beat is only actually consumed when the local valid is also high.
--
-- PAYLOAD LAYOUT (bit ordering)
--   m_data_o = s1_data_i & s0_data_i
--     - s0_data_i occupies the LSBs: bits [G_DATA0_SIZE-1 downto 0]
--     - s1_data_i occupies the MSBs: bits [G_DATA0_SIZE+G_DATA1_SIZE-1 downto
--                                          G_DATA0_SIZE]
--
-- TIMING / INTEGRATION NOTE
--   Because s0_ready_o/s1_ready_o depend combinationally on the peer valid and on
--   m_ready_i, this block forwards ready and the peer valid straight through with
--   no register stage. Chaining many such combinational stages lengthens the
--   ready path; insert a pipeline/skid buffer if backpressure timing closes hard.
--
-- RESET / CLOCK
--   The datapath is purely combinational and stateless: neither clk_i nor rst_i
--   affects the outputs. Both ports exist solely to satisfy the formal
--   verification environment (see pipe_concat.psl) and downstream conventions.
--
-- GENERICS
--   G_DATA0_SIZE : width in bits of input stream 0 (placed in the LSBs of m_data)
--   G_DATA1_SIZE : width in bits of input stream 1 (placed in the MSBs of m_data)

library ieee;
   use ieee.std_logic_1164.all;

entity pipe_concat is
   generic (
      G_DATA0_SIZE : positive := 8;                     -- s0 payload width (LSBs)
      G_DATA1_SIZE : positive := 8                      -- s1 payload width (MSBs)
   );
   port (
      clk_i      : in  std_logic;                       -- unused: formal env only
      rst_i      : in  std_logic;                       -- unused: formal env only
      -- Input stream 0 (occupies output LSBs)
      s0_valid_i : in  std_logic;
      s0_ready_o : out std_logic;
      s0_data_i  : in  std_logic_vector(G_DATA0_SIZE-1 downto 0);
      s1_valid_i : in  std_logic;
      s1_ready_o : out std_logic;
      s1_data_i  : in  std_logic_vector(G_DATA1_SIZE-1 downto 0);
      -- Output stream (concatenated payload, s1 in MSBs, s0 in LSBs)
      m_valid_o  : out std_logic;
      m_ready_i  : in  std_logic;
      m_data_o   : out std_logic_vector(G_DATA0_SIZE + G_DATA1_SIZE-1 downto 0)
   );
end entity pipe_concat;

architecture synthesis of pipe_concat is

begin

   -- Concatenate payloads: s1 in the MSBs, s0 in the LSBs.
   m_data_o <= s1_data_i & s0_data_i;

   -- Join handshake: offer an output beat only when both inputs are valid, and
   -- consume each input only on the cycle the output beat is accepted.
   m_valid_o  <=               s0_valid_i and s1_valid_i;  -- both inputs present
   s0_ready_o <= m_ready_i                and s1_valid_i;  -- s0 taken iff beat xfers
   s1_ready_o <= m_ready_i and s0_valid_i;                 -- s1 taken iff beat xfers

end architecture synthesis;
