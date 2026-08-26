library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

-- A dual-port memory with two Wishbone Slave interfaces.
--
-- Port A is READ ONLY; port B reads and writes. That asymmetry comes from
-- dp_mem, which cannot have two write ports and still be both LRM-conformant
-- VHDL-2008 and inferrable as a RAM by Vivado -- see the header of
-- test/dp_mem.vhd. It costs nothing: port A carries the instruction bus,
-- which never writes.

entity wb_dp_mem is
   generic (
      G_INIT_FILE : string := "";
      G_RAM_STYLE : string := "block";
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

   i_dp_mem : entity work.dp_mem
      generic map (
         G_INIT_FILE => G_INIT_FILE,
         G_RAM_STYLE => G_RAM_STYLE,
         G_ADDR_SIZE => G_ADDR_SIZE,
         G_DATA_SIZE => G_DATA_SIZE
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         a_addr_i    => a_addr,
         a_rd_data_o => a_rd_data,
         b_addr_i    => b_addr,
         b_wr_en_i   => b_wr_en,
         b_wr_data_i => b_wr_data,
         b_rd_data_o => b_rd_data
      ); -- i_dp_mem


   -- Acknowledge
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

