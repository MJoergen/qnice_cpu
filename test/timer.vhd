library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

entity timer is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- Wishbone memory interface
      cyc_i       : in  std_logic;
      stb_i       : in  std_logic;
      stall_o     : out std_logic;
      addr_i      : in  std_logic_vector(15 downto 0);
      we_i        : in  std_logic;
      dat_i       : in  std_logic_vector(15 downto 0);
      ack_o       : out std_logic;
      data_o      : out std_logic_vector(15 downto 0);
      -- Interrupt interface
      int_req_o   : out std_logic;
      int_grant_i : in  std_logic
   );
end entity timer;

architecture synthesis of timer is

   signal timer   : std_logic_vector(15 downto 0);
   signal addr    : std_logic_vector(15 downto 0);
   signal int_req : std_logic;

begin

   stall_o <= '0';
   ack_o   <= '0';

   p : process (clk_i)
   begin
      if rising_edge(clk_i) then

         data_o <= (others => '0');

         if timer /= 0 then
            timer <= timer - 1;

            if timer = 1 then
               int_req <= '1';
            end if;
         end if;

         if int_grant_i = '1' then
            data_o  <= addr;
            int_req <= '0';
         end if;

         if cyc_i = '1' and stb_i = '1' and we_i = '1' and addr_i = X"8000" then
            addr <= dat_i;
         end if;
         if cyc_i = '1' and stb_i = '1' and we_i = '1' and addr_i = X"8001" then
            timer <= dat_i;
         end if;

         if rst_i = '1' then
            timer <= (others => '0');
            addr  <= (others => '0');
            int_req   <= '0';
         end if;
      end if;
   end process p;

   int_req_o <= int_req;

end architecture synthesis;

