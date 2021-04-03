library ieee;
use ieee.std_logic_1164.all;

entity system is
   generic (
      G_REGISTER_BANK_WIDTH : integer;
      G_ROM : string
   );
   port (
      clk_i  : in  std_logic;
      rstn_i : in  std_logic;
      led_o  : out std_logic_vector(15 downto 0)
   );
end entity system;

architecture synthesis of system is

   signal wbi_cyc       : std_logic;
   signal wbi_stb       : std_logic;
   signal wbi_stall     : std_logic;
   signal wbi_addr      : std_logic_vector(15 downto 0);
   signal wbi_ack       : std_logic;
   signal wbi_data_rd   : std_logic_vector(15 downto 0);
   signal wbd_cyc       : std_logic;
   signal wbd_stb       : std_logic;
   signal wbd_addr      : std_logic_vector(15 downto 0);
   signal wbd_we        : std_logic;
   signal wbd_data_cpu  : std_logic_vector(15 downto 0);
   signal wbd_stall     : std_logic;
   signal wbd_ack       : std_logic;
   signal wbd_data      : std_logic_vector(15 downto 0);
   signal int_cpu_n     : std_logic;
   signal grant_cpu_n   : std_logic;
   signal int_timer_n   : std_logic;
   signal grant_timer_n : std_logic;

   signal wbd_stb_mem     : std_logic;
   signal wbd_stall_mem   : std_logic;
   signal wbd_ack_mem     : std_logic;
   signal wbd_data_mem    : std_logic_vector(15 downto 0);
   signal wbd_stb_timer   : std_logic;
   signal wbd_stall_timer : std_logic;
   signal wbd_ack_timer   : std_logic;
   signal wbd_data_timer  : std_logic_vector(15 downto 0);

begin

   led_o <= wbd_addr;

   i_cpu : entity work.cpu
      generic map (
         G_REGISTER_BANK_WIDTH => G_REGISTER_BANK_WIDTH
      )
      port map (
         clk_i       => clk_i,
         rst_i       => not rstn_i,
         int_n_i     => int_cpu_n,
         grant_n_o   => grant_cpu_n,
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
         wbd_dat_o   => wbd_data_cpu,
         wbd_ack_i   => wbd_ack,
         wbd_data_i  => wbd_data
      ); -- i_cpu

   wbd_stb_mem   <= wbd_stb when (wbd_addr and X"E000") = X"0000" else '0';
   wbd_stb_timer <= wbd_stb when (wbd_addr and X"FFFC") = X"FF28" else '0';

   i_tdp_mem : entity work.wb_tdp_mem
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
         wb_a_we_i    => '0',
         wb_a_data_i  => X"0000",
         wb_a_ack_o   => wbi_ack,
         wb_a_data_o  => wbi_data_rd,
         wb_b_cyc_i   => wbd_cyc,
         wb_b_stb_i   => wbd_stb_mem,
         wb_b_stall_o => wbd_stall_mem,
         wb_b_addr_i  => wbd_addr(12 downto 0),
         wb_b_we_i    => wbd_we,
         wb_b_data_i  => wbd_data_cpu,
         wb_b_ack_o   => wbd_ack_mem,
         wb_b_data_o  => wbd_data_mem
      ); -- i_tdp_mem

   i_daisy_chain : entity work.daisy_chain
      port map (
         clk_i           => clk_i,
         rst_i           => not rstn_i,
         this_int_n_i    => int_timer_n,
         this_grant_n_o  => grant_timer_n,
         left_int_n_o    => int_cpu_n,
         left_grant_n_i  => grant_cpu_n,
         right_int_n_i   => '1',
         right_grant_n_o => open
      ); -- i_daisy_chain

   i_timer : entity work.timer
      generic map (
         G_CLK_FREQ => 80000000   -- 80 MHz
      )
      port map (
         clk_i       => clk_i,
         rst_i       => not rstn_i,
         int_n_o     => int_timer_n,
         grant_n_i   => grant_timer_n,
         wb_cyc_i    => wbd_cyc,
         wb_stb_i    => wbd_stb_timer,
         wb_stall_o  => wbd_stall_timer,
         wb_addr_i   => wbd_addr(1 downto 0),
         wb_we_i     => wbd_we,
         wb_data_i   => wbd_data_cpu,
         wb_ack_o    => wbd_ack_timer,
         wb_data_o   => wbd_data_timer
      ); -- i_timer

   wbd_stall <= wbd_stall_mem or wbd_stall_timer;
   wbd_ack   <= wbd_ack_mem   or wbd_ack_timer;
   wbd_data  <= wbd_data_mem  or wbd_data_timer;

end architecture synthesis;

