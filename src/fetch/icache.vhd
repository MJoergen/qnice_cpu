library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

entity icache is
   generic (
      G_ADDR_SIZE : integer;
      G_DATA_SIZE : integer
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      -- From Instruction fetch
      s_valid_i  : in  std_logic;
      s_ready_o  : out std_logic;
      s_addr_i   : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      s_data_i   : in  std_logic_vector(G_DATA_SIZE-1 downto 0);

      -- To Decode
      m_valid_o  : out std_logic;
      m_ready_i  : in  std_logic;
      m_double_o : out std_logic;
      m_addr_o   : out std_logic_vector(G_ADDR_SIZE-1 downto 0);
      m_data_o   : out std_logic_vector(2*G_DATA_SIZE-1 downto 0);
      m_double_i : in  std_logic
   );
end entity icache;

architecture synthesis of icache is

   signal count : integer range 0 to 2;

   signal m_addr   : std_logic_vector(2*G_ADDR_SIZE-1 downto 0) := (others => '0');
   signal m_data   : std_logic_vector(2*G_DATA_SIZE-1 downto 0) := (others => '0');
   signal m_valid  : std_logic := '0';
   signal m_double : std_logic := '0';

begin

   count <= 0 when m_valid_o = '0' else
            1 when m_valid_o = '1' and m_double_o = '0' else
            2;

   s_ready_o <= '1' when count = 0 or count = 1 or (count = 2 and m_ready_i = '1')
                    else '0';

   m_valid_o  <= m_valid and not rst_i;
   m_double_o <= m_double;
   m_addr_o   <= m_addr(G_ADDR_SIZE-1 downto 0);
   m_data_o   <= m_data;

   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case count is
            when 0 =>
               if s_valid_i and s_ready_o then
                  m_addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                  m_data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                  m_valid  <= '1';
                  m_double <= '0';
               end if;

            when 1 =>
               if m_ready_i then
                  m_valid <= '0';
               end if;

               if s_valid_i and s_ready_o then
                  if m_ready_i then
                     m_addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                     m_data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                     m_valid  <= '1';
                     m_double <= '0';
                  else
                     m_addr(2*G_ADDR_SIZE-1 downto G_ADDR_SIZE) <= s_addr_i;
                     m_data(2*G_DATA_SIZE-1 downto G_DATA_SIZE) <= s_data_i;
                     m_valid  <= '1';
                     m_double <= '1';
                  end if;
               end if;

            when 2 =>
               if m_ready_i then
                  if m_double_i then
                     m_valid <= '0';
                  else
                     m_addr(G_ADDR_SIZE-1 downto 0) <= m_addr(2*G_ADDR_SIZE-1 downto G_ADDR_SIZE);
                     m_data(G_DATA_SIZE-1 downto 0) <= m_data(2*G_DATA_SIZE-1 downto G_DATA_SIZE);
                     m_valid  <= '1';
                     m_double <= '0';
                  end if;
               end if;

               if s_valid_i and s_ready_o then
                  if m_double_i then
                     m_addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                     m_data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                     m_valid  <= '1';
                     m_double <= '0';
                  else
                     m_addr(2*G_ADDR_SIZE-1 downto G_ADDR_SIZE) <= s_addr_i;
                     m_data(2*G_DATA_SIZE-1 downto G_DATA_SIZE) <= s_data_i;
                     m_valid  <= '1';
                     m_double <= '1';
                  end if;
               end if;

            when others => null;
         end case;

         if rst_i then
            m_valid <= '0';
         end if;
      end if;
   end process p_fsm;

end architecture synthesis;

