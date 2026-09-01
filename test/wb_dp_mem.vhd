-- A dual-port memory with two Wishbone Slave interfaces.
--
-- Port A is READ ONLY; port B reads and writes. That asymmetry comes from
-- src/sub/dp_ram.vhd, which cannot have two write ports and still be both
-- LRM-conformant VHDL-2008 and inferrable as a RAM by Vivado -- see its
-- header. It costs nothing: port A carries the instruction bus, which never
-- writes.
--
-- G_READ_REG selects between the two slave behaviours, and defaults to the
-- registered one that every committed golden file was produced with.
--
--   true  - ACKs are registered, so a request accepted in one cycle is
--           answered in the next. The ordinary pipelined-Wishbone slave.
--
--   false - a full ZERO-LATENCY slave: the ACK is combinational, asserted in
--           the same cycle the request is accepted, with the read data valid
--           alongside it. Both halves have to move together -- the generic is
--           passed to dp_ram (removing the read output registers) AND drops
--           p_ack -- because a combinational ACK over a registered read would
--           announce data that is not there yet.
--
-- The point of the false setting is to exercise the zero-latency paths in the
-- two bus masters against something that really behaves that way; see
-- src/memory/README.md#Zero-latency-ACKs and
-- src/fetch/README.md#Zero-latency-ACKs. Run the whole simulation in that mode
-- with "make test READ_REG=false".
--
-- It is a SIMULATION configuration, not a synthesis one. dp_ram's port B read
-- becomes asynchronous, and an asynchronous read cannot come out of a Block
-- RAM, so with G_RAM_STYLE = "block" the array stops mapping to BRAM -- see
-- the comment at gen_b_reg in src/sub/dp_ram.vhd.
--
-- Measured, Vivado 2022.2, synthesis only, -flatten_hierarchy none, this 8Kx16
-- instance (the i_wb_dp_mem row of "make utilization"'s per-module table):
--
--   G_READ_REG        true      false
--   RAMB36               4          0
--   LUTRAMs              0      4,096
--   Logic LUTs           3        615
--
-- The whole array moves out of 4 Block RAMs and into 4,096 LUTRAMs, taking the
-- device total from 936 to 5,643 LUTs. That is the cost of the mode, and the
-- reason it is opt-in and defaulted off rather than simply always on.

library ieee;
   use ieee.std_logic_1164.all;
   use std.textio.all;

entity wb_dp_mem is
   generic (
      G_INIT_FILE : string  := "";
      G_RAM_STYLE : string  := "block";
      G_READ_REG  : boolean := true;    -- keep port A's output register
      G_ADDR_SIZE : integer := 8;
      G_DATA_SIZE : integer := 8
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      -- Port A: read only
      wb_a_cyc_i   : in  std_logic;
      wb_a_stall_o : out std_logic;
      wb_a_stb_i   : in  std_logic;
      wb_a_ack_o   : out std_logic;
      wb_a_addr_i  : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      wb_a_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0);
      -- Port B: read and write
      wb_b_cyc_i   : in  std_logic;
      wb_b_stall_o : out std_logic;
      wb_b_stb_i   : in  std_logic;
      wb_b_ack_o   : out std_logic;
      wb_b_we_i    : in  std_logic;
      wb_b_addr_i  : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      wb_b_data_i  : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      wb_b_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity wb_dp_mem;

architecture synthesis of wb_dp_mem is

   -- Port A
   signal a_addr    : std_logic_vector(G_ADDR_SIZE-1 downto 0);
   signal a_rd_data : std_logic_vector(G_DATA_SIZE-1 downto 0);
   signal wb_a_ack  : std_logic;

   -- Port B
   signal b_addr    : std_logic_vector(G_ADDR_SIZE-1 downto 0);
   signal b_wr_en   : std_logic;
   signal b_wr_data : std_logic_vector(G_DATA_SIZE-1 downto 0);
   signal b_rd_data : std_logic_vector(G_DATA_SIZE-1 downto 0);
   signal wb_b_ack  : std_logic;

begin

   i_dp_ram : entity work.dp_ram
      generic map (
         G_INIT_FILE => G_INIT_FILE,
         G_RAM_STYLE => G_RAM_STYLE,
         G_B_READ    => true,
         G_READ_REG  => G_READ_REG,
         G_ADDR_SIZE => G_ADDR_SIZE,
         G_DATA_SIZE => G_DATA_SIZE
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         -- Wishbone port A reads only; port B reads and writes, which is
         -- exactly the shape dp_ram offers. See the header.
         a_addr_i    => a_addr,
         a_rd_en_i   => '1',
         a_rd_data_o => a_rd_data,
         b_addr_i    => b_addr,
         b_rd_en_i   => '1',
         b_rd_data_o => b_rd_data,
         b_wr_en_i   => b_wr_en,
         b_wr_data_i => b_wr_data
      ); -- i_dp_ram


   gen_ack : if G_READ_REG generate

      -- Acknowledge.
      --
      -- Note both branches derive the ACK from cyc/stb/stall only, never from
      -- anything coming back out of a master. That is the slave half of the
      -- no-combinational-loop contract the masters document: with a
      -- combinational ACK, a slave that also fed a master's own outputs back
      -- into its ACK would close a loop through it. See the header of
      -- src/memory/memory.vhd.
      p_ack : process (clk_i)
      begin
         if rising_edge(clk_i) then
            wb_a_ack <= wb_a_cyc_i and wb_a_stb_i and not wb_a_stall_o;
            wb_b_ack <= wb_b_cyc_i and wb_b_stb_i and not wb_b_stall_o;

            if rst_i = '1' then
               wb_a_ack <= '0';
               wb_b_ack <= '0';
            end if;
         end if;
      end process p_ack;

   else generate

      -- Zero latency: acknowledge in the very cycle the request is accepted.
      -- Gated by rst_i to match the registered branch, which cannot ACK during
      -- reset either.
      wb_a_ack <= wb_a_cyc_i and wb_a_stb_i and not wb_a_stall_o and not rst_i;
      wb_b_ack <= wb_b_cyc_i and wb_b_stb_i and not wb_b_stall_o and not rst_i;

   end generate gen_ack;


   a_addr       <= wb_a_addr_i;
   wb_a_data_o  <= a_rd_data;
   wb_a_stall_o <= '0';
   wb_a_ack_o   <= wb_a_ack;


   b_wr_en      <= wb_b_cyc_i and wb_b_stb_i and wb_b_we_i and not wb_b_stall_o;
   b_wr_data    <= wb_b_data_i;
   b_addr       <= wb_b_addr_i;
   wb_b_data_o  <= b_rd_data;
   wb_b_stall_o <= '0';
   wb_b_ack_o   <= wb_b_ack;

end architecture synthesis;

