-- Timer Interrupt Generator (100 kHz internal base clock)
--
-- can be Daisy Chained
-- meant to be connected with the QNICE CPU as data I/O controled through MMIO
-- and meant to be connected with other interrupt capable devices via a Daisy Chain
--
--  output goes zero when not enabled
--
-- Registers:
--
--  0 = PRE: The 100 kHz timer clock is divided by the value stored in
--           this device register. 100 (which corresponds to 0x0064 in
--           the prescaler register) yields a 1 millisecond pulse which
--           in turn is fed to the actual counter. When 0, the timer
--           is disabled.
--  1 = CNT: When the number of output pulses from the prescaler circuit
--           equals the number stored in this register, an interrupt will
--           be generated (if the interrupt address is 0x0000, the
--           interrupt will be suppressed). When 0, the timer is disabled.
--  2 = INT: This register contains the address of the desired interrupt
--           service routine. This should always point to a valid ISR,
--           possibly just an RTI.
--
-- done by sy2002 in August & September 2020

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity timer is
   generic (
      G_CLK_FREQ  : natural                               -- system clock in Hertz
   );
   port (
      clk_i       : in  std_logic;                        -- system clock
      rst_i       : in  std_logic;                        -- sync reset

      int_n_o     : out std_logic;                        -- left device's interrupt signal input
      grant_n_i   : in  std_logic;                        -- left device's grant signal output

      -- Wishbone slave interface
      wb_cyc_i    : in  std_logic;
      wb_stall_o  : out std_logic;
      wb_stb_i    : in  std_logic;
      wb_ack_o    : out std_logic;
      wb_we_i     : in  std_logic;
      wb_addr_i   : in  std_logic_vector(1 downto 0);
      wb_data_i   : in  std_logic_vector(15 downto 0);
      wb_data_o   : out std_logic_vector(15 downto 0)
   );
end timer;

architecture synthesis of timer is

   -- Registers
   signal csr_update : std_logic;
   signal csr_pre    : std_logic_vector(15 downto 0);
   signal csr_cnt    : std_logic_vector(15 downto 0);
   signal csr_int    : std_logic_vector(15 downto 0);

begin

   i_timer_csr : entity work.timer_csr
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         csr_update_o => csr_update,
         csr_pre_o    => csr_pre,
         csr_cnt_o    => csr_cnt,
         csr_int_o    => csr_int,
         grant_n_i    => grant_n_i,
         wb_cyc_i     => wb_cyc_i,
         wb_stall_o   => wb_stall_o,
         wb_stb_i     => wb_stb_i,
         wb_ack_o     => wb_ack_o,
         wb_we_i      => wb_we_i,
         wb_addr_i    => wb_addr_i,
         wb_data_i    => wb_data_i,
         wb_data_o    => wb_data_o
      ); -- i_timer_csr

   i_timer_count : entity work.timer_count
      generic map (
         G_CLK_FREQ => G_CLK_FREQ
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         csr_update_i => csr_update,
         csr_pre_i    => csr_pre,
         csr_cnt_i    => csr_cnt,
         csr_int_i    => csr_int,
         int_n_o      => int_n_o
      ); -- i_timer_count

end architecture synthesis;

