library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

entity serializer is
   generic (
      G_DATA_SIZE : integer;
      G_USER_SIZE : integer
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;

      s_valid_i : in  std_logic;
      s_ready_o : out std_logic;
      s_data_i  : in  std_logic_vector(3*G_DATA_SIZE-1 downto 0);
      s_user_i  : in  std_logic_vector(G_USER_SIZE-1 downto 0);

      m_valid_o : out std_logic;
      m_ready_i : in  std_logic;
      m_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0);
      m_user_o  : out std_logic_vector(G_USER_SIZE-1 downto 0)
   );
end entity serializer;

architecture synthesis of serializer is

   signal index : integer range 0 to 3 := 0;

begin

   s_ready_o <= '0' when s_valid_i = '1' and m_data_o(G_DATA_SIZE-1) = '0' else '1';

   p_index : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if m_valid_o and m_ready_i then
            if s_ready_o then
               index <= 0;
            else
               index <= index + 1;
            end if;
         end if;

         if rst_i then
            index <= 0;
         end if;
      end if;
   end process p_index;

   m_valid_o <= s_valid_i;
   m_data_o  <= s_data_i((index+1)*G_DATA_SIZE-1 downto index*G_DATA_SIZE);
   m_user_o  <= s_user_i;

end architecture synthesis;

