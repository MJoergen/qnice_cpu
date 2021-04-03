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

entity timer_csr is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      csr_update_o : out std_logic;
      csr_pre_o    : out std_logic_vector(15 downto 0);
      csr_cnt_o    : out std_logic_vector(15 downto 0);
      csr_int_o    : out std_logic_vector(15 downto 0);

      grant_n_i    : in  std_logic;

      -- Wishbone slave interface
      wb_cyc_i     : in  std_logic;
      wb_stall_o   : out std_logic;
      wb_stb_i     : in  std_logic;
      wb_ack_o     : out std_logic;
      wb_we_i      : in  std_logic;
      wb_addr_i    : in  std_logic_vector(1 downto 0);
      wb_data_i    : in  std_logic_vector(15 downto 0);
      wb_data_o    : out std_logic_vector(15 downto 0)
   );
end timer_csr;

architecture synthesis of timer_csr is

   constant C_REGNO_PRE : std_logic_vector(1 downto 0) := "00";
   constant C_REGNO_CNT : std_logic_vector(1 downto 0) := "01";
   constant C_REGNO_INT : std_logic_vector(1 downto 0) := "10";

   -- Registers
   signal   csr_update  : std_logic;
   signal   csr_pre     : std_logic_vector(15 downto 0);
   signal   csr_cnt     : std_logic_vector(15 downto 0);
   signal   csr_int     : std_logic_vector(15 downto 0);

begin

   p_read : process (clk_i)
   begin
      if rising_edge(clk_i) then
         wb_data_o <= (others => '0');
         wb_ack_o  <= '0';

         if grant_n_i = '0' then
            wb_data_o <= csr_int;
         end if;

         -- read registers
         if wb_cyc_i = '1' and wb_stb_i = '1' and wb_we_i = '0' then
            case wb_addr_i is
               when C_REGNO_PRE => wb_data_o <= csr_pre;
               when C_REGNO_CNT => wb_data_o <= csr_cnt;
               when C_REGNO_INT => wb_data_o <= csr_int;
               when others => null;
            end case;
            wb_ack_o <= '1';
         end if;
      end if;
   end process p_read;

   p_write : process(clk_i)
   begin
      if rising_edge(clk_i) then
         csr_update <= '0';

         -- write registers
         if wb_cyc_i = '1' and wb_stb_i = '1' and wb_we_i = '1' then
            case wb_addr_i is
               when C_REGNO_PRE => csr_pre <= wb_data_i;
               when C_REGNO_CNT => csr_cnt <= wb_data_i;
               when C_REGNO_INT => csr_int <= wb_data_i;
               when others => null;
            end case;
            csr_update <= '1';
         end if;

         if rst_i = '1' then
            csr_pre <= (others => '0');
            csr_cnt <= (others => '0');
            csr_int <= (others => '0');
         end if;
      end if;
   end process p_write;

   -- Connect output signals
   wb_stall_o <= '0';
   csr_update_o <= csr_update;
   csr_pre_o    <= csr_pre;
   csr_cnt_o    <= csr_cnt;
   csr_int_o    <= csr_int;

end architecture synthesis;

