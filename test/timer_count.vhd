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
-- redone by MJoergen in 2021

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

entity timer_count is
   generic (
      G_CLK_FREQ   : natural                               -- system clock in Hertz
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- Registers
      csr_update_i : in  std_logic;
      csr_pre_i    : in  std_logic_vector(15 downto 0);
      csr_cnt_i    : in  std_logic_vector(15 downto 0);
      csr_int_i    : in  std_logic_vector(15 downto 0);

      -- Interrupt request
      int_n_o      : out std_logic                         -- left device's interrupt signal input
   );
end timer_count;

architecture synthesis of timer_count is

   -- Autodetect whether we're in simulation or in hardware.
   constant C_IS_SIM : boolean := false
-- pragma synthesis off
   or true
-- pragma synthesis on
;

   -- The Actual Counter
   signal counter_pre : std_logic_vector(15 downto 0);
   signal counter_cnt : std_logic_vector(15 downto 0);

   signal is_counting : std_logic;
   signal has_fired   : std_logic;

   -- Internal 100 kHz clock
   constant C_FREQ_INTERNAL       : natural := 100000;       -- internal clock speed
   constant C_FREQ_DIV_SYS_TARGET : natural := G_CLK_FREQ / C_FREQ_INTERNAL;
   signal   freq_div_cnt          : std_logic_vector(15 downto 0);

begin

   int_n_o <= not(has_fired and not rst_i);

   -- timer is only counting if PRE and CNT are nonzero
   is_counting <= '1' when csr_pre_i /= x"0000" and csr_cnt_i /= x"0000" else '0';

   -- nested counting loop: "count PRE times to CNT"
   p_count : process (clk_i)
   begin
      if rising_edge(clk_i) then

         -- new values for the PRE and CNT registers are on the data bus
         -- or timer has elapsed and fired: request the interrupt and reset the values
         if has_fired or csr_update_i then
            has_fired <= '0';
            counter_pre <= csr_pre_i;
            counter_cnt <= csr_cnt_i;
            freq_div_cnt <= to_stdlogicvector(C_FREQ_DIV_SYS_TARGET, 16);

         -- count, but only, if it has not yet fired and pause during interrupt/daisy handshakes
         elsif is_counting = '1' then

            -- create 100 kHz clock from system clock
            if freq_div_cnt = x"0000" or C_IS_SIM then
               freq_div_cnt <= to_stdlogicvector(C_FREQ_DIV_SYS_TARGET, 16);
               -- prescaler divides the 100 kHz clock by the value stored in the PRE register
               if counter_pre = x"0001" then
                  counter_pre <= csr_pre_i;
                  -- count until zero, then "has_fired" will be true
                  if counter_cnt = x"0000" then
                     has_fired <= '1';
                  else
                     counter_cnt <= counter_cnt - 1;
                  end if;
               else
                  counter_pre <= counter_pre - 1;
               end if;
            else
               freq_div_cnt <= freq_div_cnt - 1;
            end if;
         end if;

         if rst_i = '1' then
            has_fired    <= '0';
            counter_pre  <= (others => '0');
            counter_cnt  <= (others => '0');
            freq_div_cnt <= to_stdlogicvector(C_FREQ_DIV_SYS_TARGET, 16);
         end if;
      end if;
   end process p_count;

end architecture synthesis;

