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

   signal addr : std_logic_vector(2*G_ADDR_SIZE-1 downto 0) := (others => '0');
   signal data : std_logic_vector(2*G_DATA_SIZE-1 downto 0) := (others => '0');

   type STATE_t is (ZERO_ST, ONE_ST, TWO_ST);
   signal state : STATE_t := ZERO_ST;

begin

   m_valid_o  <= not rst_i when state = ONE_ST or state = TWO_ST else '0';
   m_double_o <= '1' when state = TWO_ST else '0';
   m_addr_o   <= addr(G_ADDR_SIZE-1 downto 0);
   m_data_o   <= data;

   s_ready_o <= '1' when state = ZERO_ST or state = ONE_ST or (state = TWO_ST and m_ready_i = '1')
                    else '0';

   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case state is
            when ZERO_ST =>
               if s_valid_i and s_ready_o then
                  addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                  data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                  state <= ONE_ST;
               end if;

            when ONE_ST =>
               if m_ready_i then
                  state <= ZERO_ST;
               end if;

               if s_valid_i and s_ready_o then
                  if m_ready_i then
                     addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                     data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                     state <= ONE_ST;
                  else
                     addr(2*G_ADDR_SIZE-1 downto G_ADDR_SIZE) <= s_addr_i;
                     data(2*G_DATA_SIZE-1 downto G_DATA_SIZE) <= s_data_i;
                     state <= TWO_ST;
                  end if;
               end if;

            when TWO_ST =>
               if m_ready_i then
                  if m_double_i then
                     state <= ZERO_ST;
                  else
                     addr(G_ADDR_SIZE-1 downto 0) <= addr(2*G_ADDR_SIZE-1 downto G_ADDR_SIZE);
                     data(G_DATA_SIZE-1 downto 0) <= data(2*G_DATA_SIZE-1 downto G_DATA_SIZE);
                     state <= ONE_ST;
                  end if;
               end if;

               if s_valid_i and s_ready_o then
                  if m_double_i then
                     addr(G_ADDR_SIZE-1 downto 0) <= s_addr_i;
                     data(G_DATA_SIZE-1 downto 0) <= s_data_i;
                     state <= ONE_ST;
                  else
                     addr(2*G_ADDR_SIZE-1 downto G_ADDR_SIZE) <= s_addr_i;
                     data(2*G_DATA_SIZE-1 downto G_DATA_SIZE) <= s_data_i;
                     state <= TWO_ST;
                  end if;
               end if;

            when others => null;
         end case;

         if rst_i then
            state <= ZERO_ST;
         end if;
      end if;
   end process p_fsm;

end architecture synthesis;

