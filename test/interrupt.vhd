-- This acks as a programmable interrupt generator.
-- Only relevant in simulation.
--
-- Register Map
-- 0xFF00 : Countdown number of clock cycles until interrupt is asserted
-- 0xFF01 : Address of interrupt service routine
-- 0xFF02 : Bit 0 indicates whether interrupt is currently asserted (useful for
--          reading while inside an ISR).
-- Writing a zero to 0xFF00 deliberately clears irq_valid_o.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity interrupt is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;

      -- Wishbone Slave interface
      cyc_i       : in  std_logic;
      stb_i       : in  std_logic;
      stall_o     : out std_logic;
      addr_i      : in  std_logic_vector(2 downto 0);
      we_i        : in  std_logic;
      wr_data_i   : in  std_logic_vector(15 downto 0);
      ack_o       : out std_logic;
      rd_data_o   : out std_logic_vector(15 downto 0);

      -- Interrupt port on CPU
      irq_valid_o : out std_logic;
      irq_ready_i : in  std_logic;
      irq_addr_o  : out std_logic_vector(15 downto 0)
   );
end entity interrupt;

architecture rtl of interrupt is

   constant C_INT_COUNT : std_logic_vector(2 downto 0) := "000";
   constant C_INT_ADDR  : std_logic_vector(2 downto 0) := "001";
   constant C_INT_STAT  : std_logic_vector(2 downto 0) := "010";

   signal irq_timer : std_logic_vector(15 downto 0) := (others => '0');
   signal irq_addr  : std_logic_vector(15 downto 0) := (others => '0');

begin

   stall_o <= '0';
   p_irq : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if irq_ready_i = '1' then
            irq_valid_o <= '0';
         end if;

         ack_o     <= '0';
         rd_data_o <= (others => '0');
         if cyc_i = '1' and stb_i = '1' then
            ack_o <= '1';
            if we_i = '1' then
               case addr_i is

                  when C_INT_COUNT =>
                     irq_timer <= wr_data_i;
                     if wr_data_i = 0 then
                        irq_valid_o <= '0';
                     end if;

                  when C_INT_ADDR =>
                     irq_addr <= wr_data_i;

                  when others =>
                     null;
               end case;
            else
               case addr_i is

                  when C_INT_COUNT =>
                     rd_data_o <= irq_timer;

                  when C_INT_ADDR =>
                     rd_data_o <= irq_addr;

                  when C_INT_STAT =>
                     rd_data_o(0) <= irq_valid_o;

                  when others =>
                     null;
               end case;
            end if;
         end if;

         if irq_timer > 0 then
            irq_timer <= irq_timer - 1;
            if irq_timer = 1 then
               irq_valid_o <= '1';
               irq_addr_o  <= irq_addr;
            end if;
         end if;

         if rst_i = '1' then
            irq_valid_o <= '0';
            irq_timer   <= (others => '0');
         end if;
      end if;
   end process p_irq;

end architecture rtl;

