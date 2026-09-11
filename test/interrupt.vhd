-- This acts as a programmable interrupt generator.
-- This module is only meant to be used in simulation. It will
-- not be used during synthesis.
--
-- irq_addr_o is only valid when irq_valid_o is asserted. It is deliberately
-- scrambled when irq_valid_o is de-asserted.
--
-- Register Map:
-- 0xBF00 : Countdown number of clock cycles until interrupt is asserted. After count-down,
--          interrupt line remains asserted until accepted, and is then released. Counter
--          reads back as zero.
-- 0xBF01 : Address of interrupt service routine. Initialized to zero, which happens to be
--          the same as the CPU reset address.
-- 0xBF02 : Bit 0 indicates whether interrupt is currently asserted (can only ever read
--          non-zero when inside an ISR)
-- 0xBF03 : Number of accepted interrupt requests

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity interrupt is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- Wishbone Slave interface
      wb_cyc_i     : in  std_logic;
      wb_stb_i     : in  std_logic;
      wb_stall_o   : out std_logic;
      wb_addr_i    : in  std_logic_vector(2 downto 0);
      wb_we_i      : in  std_logic;
      wb_wr_data_i : in  std_logic_vector(15 downto 0);
      wb_ack_o     : out std_logic;
      wb_rd_data_o : out std_logic_vector(15 downto 0);

      -- Interrupt port on CPU
      irq_valid_o  : out std_logic;
      irq_ready_i  : in  std_logic;
      irq_addr_o   : out std_logic_vector(15 downto 0)
   );
end entity interrupt;

architecture simulation of interrupt is

   constant C_INT_COUNT  : std_logic_vector(2 downto 0) := "000";
   constant C_INT_ADDR   : std_logic_vector(2 downto 0) := "001";
   constant C_INT_STAT   : std_logic_vector(2 downto 0) := "010";
   constant C_INT_ACCEPT : std_logic_vector(2 downto 0) := "011";

   signal irq_timer  : std_logic_vector(15 downto 0) := (others => '0');
   signal irq_addr   : std_logic_vector(15 downto 0) := (others => '0');
   signal irq_accept : std_logic_vector(15 downto 0) := (others => '0');

   signal irq_ready_d : std_logic := '0';

begin

   p_checks : process (clk_i)
   begin
      if rising_edge(clk_i) then
         irq_ready_d <= irq_ready_i;

         if irq_ready_d = '1' then
            assert irq_ready_i = '0'
               report "ERROR: Duplicate irq_ready_i"
               severity failure;
         end if;
      end if;
   end process p_checks;

   wb_stall_o <= '0';

   p_irq : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if irq_ready_i = '1' then
            assert irq_valid_o = '1'
               report "ERROR: Stray irq_ready_i"
               severity failure;

            irq_accept  <= irq_accept + 1;
            irq_valid_o <= '0';
            irq_addr_o  <= (others => '1'); -- Deliberately scramble address after accept
         end if;

         -- Count-down interrupt timer.
         -- CPU writes are further down in this process, and therefore
         -- overrule anything here.
         -- NOTE: To avoid race conditions, the counter only decrements while
         -- irq_valid_o is 0.
         if irq_timer > 0 and irq_valid_o = '0' then
            irq_timer <= irq_timer - 1;
            if irq_timer = 1 then
               -- Counter transitioning from 1 to 0 asserts the interrupt line.
               irq_valid_o <= '1';
               irq_addr_o  <= irq_addr;
            end if;
         end if;

         wb_ack_o     <= '0';
         wb_rd_data_o <= (others => '0');

         if wb_cyc_i = '1' and wb_stb_i = '1' then
            wb_ack_o <= '1';
            if wb_we_i = '1' then
               case wb_addr_i is

                  when C_INT_COUNT =>
                     irq_timer <= wb_wr_data_i;

                  when C_INT_ADDR =>
                     irq_addr <= wb_wr_data_i;

                  when others =>
                     null;
               end case;
            else
               case wb_addr_i is

                  when C_INT_COUNT =>
                     wb_rd_data_o <= irq_timer;

                  when C_INT_ADDR =>
                     wb_rd_data_o <= irq_addr;

                  when C_INT_STAT =>
                     wb_rd_data_o(0) <= irq_valid_o;

                  when C_INT_ACCEPT =>
                     wb_rd_data_o <= irq_accept;

                  when others =>
                     null;
               end case;
            end if;
         end if;

         if rst_i = '1' then
            wb_ack_o    <= '0';
            irq_valid_o <= '0';
            irq_addr_o  <= (others => '0');
            irq_timer   <= (others => '0');
            irq_addr    <= (others => '0');
            irq_accept  <= (others => '0');
         end if;
      end if;
   end process p_irq;

end architecture simulation;

