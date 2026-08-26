library ieee;
   use ieee.std_logic_1164.all;

entity system is
   generic (
      G_REGISTER_BANK_WIDTH : integer;
      G_ROM                 : string;
      -- Simulation only: file to log every register and memory write to.
      -- An empty string (the default) disables the logging entirely.
      G_WRITES_FILE         : string := "";
      -- Simulation only: file to write the run statistics to (cycle count and
      -- memory request counts). An empty string disables them.
      G_STATS_FILE          : string := ""
   );
   port (
      clk_i  : in  std_logic;
      rstn_i : in  std_logic;
      led_o  : out std_logic_vector(15 downto 0)
   );
end entity system;

architecture synthesis of system is

   signal wbi_cyc     : std_logic;
   signal wbi_stb     : std_logic;
   signal wbi_stall   : std_logic;
   signal wbi_addr    : std_logic_vector(15 downto 0);
   signal wbi_ack     : std_logic;
   signal wbi_data_rd : std_logic_vector(15 downto 0);
   signal wbd_cyc     : std_logic;
   signal wbd_stb     : std_logic;
   signal wbd_stall   : std_logic;
   signal wbd_addr    : std_logic_vector(15 downto 0);
   signal wbd_we      : std_logic;
   signal wbd_data_wr : std_logic_vector(15 downto 0);
   signal wbd_ack     : std_logic;
   signal wbd_data_rd : std_logic_vector(15 downto 0);

   signal halt        : std_logic;

begin

   led_o <= wbd_addr;

   i_cpu : entity work.cpu
      generic map (
         G_REGISTER_BANK_WIDTH => G_REGISTER_BANK_WIDTH,
         G_WRITES_FILE         => G_WRITES_FILE
      )
      port map (
         clk_i       => clk_i,
         rst_i       => not rstn_i,
         wbi_cyc_o   => wbi_cyc,
         wbi_stb_o   => wbi_stb,
         wbi_stall_i => wbi_stall,
         wbi_addr_o  => wbi_addr,
         wbi_ack_i   => wbi_ack,
         wbi_data_i  => wbi_data_rd,
         wbd_cyc_o   => wbd_cyc,
         wbd_stb_o   => wbd_stb,
         wbd_stall_i => wbd_stall,
         wbd_addr_o  => wbd_addr,
         wbd_we_o    => wbd_we,
         wbd_dat_o   => wbd_data_wr,
         wbd_ack_i   => wbd_ack,
         wbd_data_i  => wbd_data_rd,
         halt_o      => halt
      ); -- i_cpu

   i_wb_dp_mem : entity work.wb_dp_mem
      generic map (
         G_INIT_FILE => G_ROM,
         G_RAM_STYLE => "block",
         G_ADDR_SIZE => 13,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i        => clk_i,
         rst_i        => not rstn_i,
         wb_a_cyc_i   => wbi_cyc,
         wb_a_stb_i   => wbi_stb,
         wb_a_stall_o => wbi_stall,
         wb_a_addr_i  => wbi_addr(12 downto 0),
         wb_a_ack_o   => wbi_ack,
         wb_a_data_o  => wbi_data_rd,
         wb_b_cyc_i   => wbd_cyc,
         wb_b_stb_i   => wbd_stb,
         wb_b_stall_o => wbd_stall,
         wb_b_addr_i  => wbd_addr(12 downto 0),
         wb_b_we_i    => wbd_we,
         wb_b_data_i  => wbd_data_wr,
         wb_b_ack_o   => wbd_ack,
         wb_b_data_o  => wbd_data_rd
      ); -- i_wb_dp_mem


-- pragma synthesis_off
   -- The two request terms are accepted beats in pipelined Wishbone: the slave
   -- takes the request in the cycle where cyc and stb are high and stall is
   -- low. Counting those rather than stb alone means a stalled request is
   -- counted once, not once per cycle it is held.
   i_test_monitor : entity work.test_monitor
      generic map (
         G_STATS_FILE => G_STATS_FILE
      )
      port map (
         clk_i      => clk_i,
         rst_i      => not rstn_i,
         halt_i     => halt,
         mem_we_i   => wbd_stb and wbd_we and not wbd_stall,
         mem_addr_i => wbd_addr,
         mem_data_i => wbd_data_wr,
         wbi_req_i  => wbi_cyc and wbi_stb and not wbi_stall,
         wbd_req_i  => wbd_cyc and wbd_stb and not wbd_stall
      ); -- i_test_monitor
-- pragma synthesis_on

end architecture synthesis;

