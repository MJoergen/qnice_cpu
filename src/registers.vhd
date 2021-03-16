library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity registers is
   port (
      clk_i         : in  std_logic;
      rst_i         : in  std_logic;
      -- Read interface
      src_reg_i     : in  std_logic_vector(3 downto 0);
      src_val_o     : out std_logic_vector(15 downto 0);
      dst_reg_i     : in  std_logic_vector(3 downto 0);
      dst_val_o     : out std_logic_vector(15 downto 0);
      r14_o         : out std_logic_vector(15 downto 0);
      -- Write interface
      wr_r14_en_i   : in  std_logic;
      wr_r14_i      : in  std_logic_vector(15 downto 0);
      wr_en_i       : in  std_logic;
      wr_addr_i     : in  std_logic_vector(3 downto 0);
      wr_val_i      : in  std_logic_vector(15 downto 0)
   );
end entity registers;

architecture synthesis of registers is

   type upper_mem_t is array (8 to 15) of std_logic_vector(15 downto 0);

   signal upper_regs : upper_mem_t := (others => (others => '0'));

   signal r14 : std_logic_vector(15 downto 0) := (others => '0');

   signal src_val_upper : std_logic_vector(15 downto 0);
   signal dst_val_upper : std_logic_vector(15 downto 0);

   signal src_val_lower : std_logic_vector(15 downto 0);
   signal dst_val_lower : std_logic_vector(15 downto 0);

   signal src_reg_d : std_logic_vector(3 downto 0);
   signal dst_reg_d : std_logic_vector(3 downto 0);

   signal src_rd_addr : std_logic_vector(10 downto 0);
   signal dst_rd_addr : std_logic_vector(10 downto 0);
   signal wr_addr     : std_logic_vector(10 downto 0);

   signal wr_r14_en_d : std_logic;
   signal wr_r14_d    : std_logic_vector(15 downto 0);
   signal wr_en_d     : std_logic;
   signal wr_addr_d   : std_logic_vector(3 downto 0);
   signal wr_val_d    : std_logic_vector(15 downto 0);

begin

   src_rd_addr <= r14(15 downto 8) & src_reg_i(2 downto 0);
   dst_rd_addr <= r14(15 downto 8) & dst_reg_i(2 downto 0);
   wr_addr     <= r14(15 downto 8) & wr_addr_i(2 downto 0);


   i_ram_lower_src : entity work.dp_ram
      generic map (
         G_ADDR_SIZE => 11,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         rd_addr_i => src_rd_addr,
         rd_data_o => src_val_lower,
         wr_addr_i => wr_addr,
         wr_data_i => wr_val_i,
         wr_en_i   => wr_en_i and not wr_addr_i(3)
      ); -- i_ram_lower_src


   i_ram_lower_dst : entity work.dp_ram
      generic map (
         G_ADDR_SIZE => 11,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         rd_addr_i => dst_rd_addr,
         rd_data_o => dst_val_lower,
         wr_addr_i => wr_addr,
         wr_data_i => wr_val_i,
         wr_en_i   => wr_en_i and not wr_addr_i(3)
      ); -- i_ram_lower_dst


   p_write : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wr_en_i = '1' then
            if to_integer(wr_addr_i) >= 8 then
               upper_regs(to_integer(wr_addr_i)) <= wr_val_i;
            end if;
         end if;

-- pragma synthesis_off
         if rst_i = '1' then
            for i in 8 to 15 loop
               upper_regs(i) <= X"111" * to_std_logic_vector(i, 4);
            end loop;
         end if;
-- pragma synthesis_on
      end if;
   end process p_write;


   p_delay : process (clk_i)
   begin
      if rising_edge(clk_i) then
         src_reg_d <= src_reg_i;
         dst_reg_d <= dst_reg_i;
      end if;
   end process p_delay;

   p_read : process (clk_i)
   begin
      if rising_edge(clk_i) then
         src_val_upper <= upper_regs(8+to_integer(src_reg_i(2 downto 0)));
         dst_val_upper <= upper_regs(8+to_integer(dst_reg_i(2 downto 0)));
      end if;
   end process p_read;


   p_r14 : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wr_r14_en_i = '1' then
            r14 <= wr_r14_i or X"0001";
         end if;

         if wr_en_i = '1' and wr_addr_i = C_REG_SR then
            r14 <= wr_val_i or X"0001";
         end if;

         if rst_i = '1' then
            r14 <= X"0001";
         end if;
      end if;
   end process p_r14;


   ------------------------------------------------------------
   -- Write before read
   ------------------------------------------------------------

   p_wbr : process (clk_i)
   begin
      if rising_edge(clk_i) then
         wr_r14_en_d <= wr_r14_en_i;
         wr_r14_d    <= wr_r14_i;
         wr_val_d    <= wr_val_i;
         wr_en_d     <= wr_en_i;
         wr_addr_d   <= wr_addr_i;
      end if;
   end process p_wbr;


   r14_o <= r14;

   src_val_o <= wr_val_d      when wr_en_d = '1' and wr_addr_d = src_reg_d else
                r14           when src_reg_d = C_REG_SR else
                src_val_upper when src_reg_d >= 8 else
                src_val_lower;
   dst_val_o <= wr_val_d      when wr_en_d = '1' and wr_addr_d = dst_reg_d else
                r14           when dst_reg_d = C_REG_SR else
                dst_val_upper when dst_reg_d >= 8 else
                dst_val_lower;

end architecture synthesis;

