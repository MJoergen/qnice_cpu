library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

-- This is a single-clock dual-port RAM, with one write port and one read port.
-- In case of Block RAMs an extra register is inserted, such that the memory is
-- read on the falling clock. This improves timing.
-- However, this trick does not work with distributed memory, but is not needed
-- either.

entity dp_ram is
   generic (
      G_RAM_STYLE : string := "block"; -- Select between "block" and "distributed".
      G_ADDR_SIZE : integer;
      G_DATA_SIZE : integer
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;
      -- Write interface
      wr_addr_i : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      wr_data_i : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      wr_en_i   : in  std_logic;
      -- Read interface
      rd_en_i   : in  std_logic;
      rd_addr_i : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      rd_data_o : out std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity dp_ram;

architecture synthesis of dp_ram is

   type mem_t is array (0 to 2**G_ADDR_SIZE-1) of std_logic_vector(G_DATA_SIZE-1 downto 0);

   signal dp_ram_r : mem_t := (others => (others => '0'));

   attribute ram_style : string;
   attribute ram_style of dp_ram_r : signal is G_RAM_STYLE;

   signal rd_data : std_logic_vector(G_DATA_SIZE-1 downto 0);

begin

   p_write : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wr_en_i = '1' then
            dp_ram_r(to_integer(wr_addr_i)) <= wr_data_i;
         end if;
      end if;
   end process p_write;


   gen_block_ram : if G_RAM_STYLE = "block" generate

      -- Block RAMs we read on the falling clock edge to improve timing.

      p_read_falling : process (clk_i)
      begin
         if falling_edge(clk_i) then
            if rd_en_i = '1' then
               rd_data <= dp_ram_r(to_integer(rd_addr_i));
            end if;
         end if;
      end process p_read_falling;

      p_read_rising : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if rd_en_i = '1' then
               rd_data_o <= rd_data;
            end if;
         end if;
      end process p_read_rising;

   else generate -- G_RAM_STYLE /= "block"

      -- Distributed RAM we read on the rising clock edge, again to improve timing.

      p_read : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if rd_en_i = '1' then
               rd_data_o <= dp_ram_r(to_integer(rd_addr_i));
            end if;
         end if;
      end process p_read;

   end generate gen_block_ram;

end architecture synthesis;

