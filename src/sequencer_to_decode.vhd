library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

entity sequencer_to_decode is
   port (
      clk_i            : in  std_logic;
      rst_i            : in  std_logic;

      -- From Instruction fetch
      fetch_valid_i    : in  std_logic;
      fetch_ready_o    : out std_logic;
      fetch_addr_i     : in  std_logic_vector(15 downto 0);
      fetch_data_i     : in  std_logic_vector(15 downto 0);

      -- To Decode
      decode_valid_o   : out std_logic;
      decode_ready_i   : in  std_logic;
      decode_double_o  : out std_logic;
      decode_addr_o    : out std_logic_vector(15 downto 0);
      decode_data_o    : out std_logic_vector(31 downto 0);
      decode_double_i  : in  std_logic
   );
end entity sequencer_to_decode;

architecture synthesis of sequencer_to_decode is

   signal addr   : std_logic_vector(31 downto 0);
   signal data   : std_logic_vector(31 downto 0);
   signal valid  : std_logic;
   signal double : std_logic;

   type STATE_t is (ZERO_ST, ONE_ST, TWO_ST);
   signal state : STATE_t := ZERO_ST;

begin

   decode_valid_o  <= '1' when state = ONE_ST or state = TWO_ST else '0';
   decode_double_o <= '1' when state = TWO_ST else '0';
   decode_addr_o   <= addr(15 downto 0);
   decode_data_o   <= data;

   fetch_ready_o <= '1' when state = ZERO_ST or state = ONE_ST or (state = TWO_ST and decode_ready_i = '1')
                    else '0';

   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case state is
            when ZERO_ST =>
               if fetch_valid_i and fetch_ready_o then
                  addr(15 downto 0) <= fetch_addr_i;
                  data(15 downto 0) <= fetch_data_i;
                  state <= ONE_ST;
               end if;

            when ONE_ST =>
               if decode_ready_i then
                  state <= ZERO_ST;
               end if;

               if fetch_valid_i and fetch_ready_o then
                  if decode_ready_i then
                     addr(15 downto 0) <= fetch_addr_i;
                     data(15 downto 0) <= fetch_data_i;
                     state <= ONE_ST;
                  else
                     addr(31 downto 16) <= fetch_addr_i;
                     data(31 downto 16) <= fetch_data_i;
                     state <= TWO_ST;
                  end if;
               end if;

            when TWO_ST =>
               if decode_ready_i then
                  if decode_double_i then
                     state <= ZERO_ST;
                  else
                     addr(15 downto 0) <= addr(31 downto 16);
                     data(15 downto 0) <= data(31 downto 16);
                     state <= ONE_ST;
                  end if;
               end if;

               if fetch_valid_i and fetch_ready_o then
                  if decode_double_i then
                     addr(15 downto 0) <= fetch_addr_i;
                     data(15 downto 0) <= fetch_data_i;
                     state <= ONE_ST;
                  else
                     addr(31 downto 16) <= fetch_addr_i;
                     data(31 downto 16) <= fetch_data_i;
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

