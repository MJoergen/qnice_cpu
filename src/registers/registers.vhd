library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.C_REG_SR;

-- This is the register file of the QNICE CPU
-- Lower registers (R0-R7) are banked (indexed by SR register (aka R14)  bits 15-8).
-- Upper registers (R8-R15) are not banked.
--
-- There is a one-clock-cycle delay when reading.
--
-- It supports Write-Before-Read, which means that if one reads from and writes
-- to the same register in a given clock cycle, then the next clock cycle gives
-- the NEW value, i.e. the one just written.

entity registers is
   generic (
      G_REGISTER_BANK_WIDTH : integer
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- Read interface (with two simultaneous read ports), connected to DECODE stage
      rd_en_i     : in  std_logic;
      src_reg_i   : in  std_logic_vector(3 downto 0); -- Only valid when rd_en_i = '1'
      src_val_o   : out std_logic_vector(15 downto 0);
      dst_reg_i   : in  std_logic_vector(3 downto 0); -- Only valid when rd_en_i = '1'
      dst_val_o   : out std_logic_vector(15 downto 0);
      wr_en_i     : in  std_logic;
      wr_reg_i    : in  std_logic_vector(3 downto 0);
      wr_val_i    : in  std_logic_vector(15 downto 0);
      -- Separate dedicated interface for the SR register (aka R14)
      sr_val_o    : out std_logic_vector(15 downto 0);
      wr_sr_en_i  : in  std_logic;
      wr_sr_val_i : in  std_logic_vector(15 downto 0)
   );
end entity registers;

architecture synthesis of registers is

   signal lower_rd_en       : std_logic;
   signal lower_rd_addr_src : std_logic_vector(G_REGISTER_BANK_WIDTH+2 downto 0);
   signal lower_rd_data_src : std_logic_vector(15 downto 0);
   signal lower_rd_addr_dst : std_logic_vector(G_REGISTER_BANK_WIDTH+2 downto 0);
   signal lower_rd_data_dst : std_logic_vector(15 downto 0);
   signal lower_wr_en       : std_logic;
   signal lower_wr_addr     : std_logic_vector(G_REGISTER_BANK_WIDTH+2 downto 0);
   signal lower_wr_data     : std_logic_vector(15 downto 0);

   signal upper_rd_en       : std_logic;
   signal upper_rd_addr_src : std_logic_vector(2 downto 0);
   signal upper_rd_addr_dst : std_logic_vector(2 downto 0);
   signal upper_rd_data_src : std_logic_vector(15 downto 0);
   signal upper_rd_data_dst : std_logic_vector(15 downto 0);
   signal upper_wr_en       : std_logic;
   signal upper_wr_addr     : std_logic_vector(2 downto 0);
   signal upper_wr_data     : std_logic_vector(15 downto 0);

   signal reg_sr : std_logic_vector(15 downto 0) := (others => '0');

   signal src_reg_d   : std_logic_vector(3 downto 0);
   signal dst_reg_d   : std_logic_vector(3 downto 0);
   signal wr_sr_en_d  : std_logic;
   signal wr_sr_val_d : std_logic_vector(15 downto 0);
   signal wr_en_d     : std_logic;
   signal wr_addr_d   : std_logic_vector(3 downto 0);
   signal wr_val_d    : std_logic_vector(15 downto 0);

   signal rd_en_d     : std_logic;
   signal src_val_d   : std_logic_vector(15 downto 0);
   signal dst_val_d   : std_logic_vector(15 downto 0);

begin

   ------------------------------------------------------------
   -- Lower register bank: R0 - R7
   ------------------------------------------------------------

   lower_rd_en       <= rd_en_i;
   lower_rd_addr_src <= reg_sr(G_REGISTER_BANK_WIDTH+7 downto 8) & src_reg_i(2 downto 0);
   lower_rd_addr_dst <= reg_sr(G_REGISTER_BANK_WIDTH+7 downto 8) & dst_reg_i(2 downto 0);
   lower_wr_addr     <= reg_sr(G_REGISTER_BANK_WIDTH+7 downto 8) & wr_reg_i(2 downto 0);
   lower_wr_data     <= wr_val_i;
   lower_wr_en       <= wr_en_i and not wr_reg_i(3);

   i_ram_lower_src : entity work.dp_ram
      generic map (
         G_ADDR_SIZE => G_REGISTER_BANK_WIDTH+3,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         rd_en_i   => lower_rd_en,
         rd_addr_i => lower_rd_addr_src,
         rd_data_o => lower_rd_data_src,
         wr_en_i   => lower_wr_en,
         wr_addr_i => lower_wr_addr,
         wr_data_i => lower_wr_data
      ); -- i_ram_lower_src


   i_ram_lower_dst : entity work.dp_ram
      generic map (
         G_ADDR_SIZE => G_REGISTER_BANK_WIDTH+3,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         rd_en_i   => lower_rd_en,
         rd_addr_i => lower_rd_addr_dst,
         rd_data_o => lower_rd_data_dst,
         wr_en_i   => lower_wr_en,
         wr_addr_i => lower_wr_addr,
         wr_data_i => lower_wr_data
      ); -- i_ram_lower_dst


   ------------------------------------------------------------
   -- Upper register bank: R8 - R15
   ------------------------------------------------------------

   upper_rd_en       <= rd_en_i;
   upper_rd_addr_src <= src_reg_i(2 downto 0);
   upper_rd_addr_dst <= dst_reg_i(2 downto 0);
   upper_wr_en       <= wr_en_i and wr_reg_i(3);
   upper_wr_addr     <= wr_reg_i(2 downto 0);
   upper_wr_data     <= wr_val_i;

   i_ram_upper_src : entity work.dp_ram
      generic map (
         G_RAM_STYLE => "distributed",
         G_ADDR_SIZE => 3,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         rd_en_i   => upper_rd_en,
         rd_addr_i => upper_rd_addr_src,
         rd_data_o => upper_rd_data_src,
         wr_en_i   => upper_wr_en,
         wr_addr_i => upper_wr_addr,
         wr_data_i => upper_wr_data
      ); -- i_ram_upper_src


   i_ram_upper_dst : entity work.dp_ram
      generic map (
         G_RAM_STYLE => "distributed",
         G_ADDR_SIZE => 3,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         rd_en_i   => upper_rd_en,
         rd_addr_i => upper_rd_addr_dst,
         rd_data_o => upper_rd_data_dst,
         wr_en_i   => upper_wr_en,
         wr_addr_i => upper_wr_addr,
         wr_data_i => upper_wr_data
      ); -- i_ram_upper_dst


   ------------------------------------------------------------
   -- Special handling of reg_sr
   ------------------------------------------------------------

   p_sr : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wr_sr_en_i = '1' then
            reg_sr <= wr_sr_val_i or X"0001";
         end if;

         if wr_en_i = '1' and wr_reg_i = C_REG_SR then
            reg_sr <= wr_val_i or X"0001";
         end if;

         if rst_i = '1' then
            reg_sr <= X"0001";
         end if;
      end if;
   end process p_sr;


   ------------------------------------------------------------
   -- Write before read
   ------------------------------------------------------------

   p_wbr : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rd_en_i = '1' then
            src_reg_d <= src_reg_i;
            dst_reg_d <= dst_reg_i;
         end if;
         wr_sr_en_d  <= wr_sr_en_i;
         wr_sr_val_d <= wr_sr_val_i;
         wr_val_d    <= wr_val_i;
         wr_en_d     <= wr_en_i;
         wr_addr_d   <= wr_reg_i;
         rd_en_d     <= rd_en_i;
      end if;
   end process p_wbr;

   p_rden_keep : process (clk_i)
   begin
      if rising_edge(clk_i) then
         src_val_d <= src_val_o;
         dst_val_d <= dst_val_o;
      end if;
   end process p_rden_keep;


   sr_val_o <= X"0001"                when rst_i = '1' else
               wr_val_i or X"0001"    when wr_en_i = '1' and wr_reg_i = C_REG_SR else
               wr_sr_val_i or X"0001" when wr_sr_en_i = '1' else
               reg_sr;

   -- TBD: Possible timing optimization: Make "wr_en_d = '1' and wr_addr_d =
   -- src_reg_d" a single register.
   -- Potential improvement: Small

   src_val_o <= wr_val_i          when wr_en_i = '1' and wr_reg_i = src_reg_d else
                wr_val_d          when wr_en_d = '1' and wr_addr_d = src_reg_d else
                src_val_d         when rd_en_d = '0' else
                reg_sr            when src_reg_d = C_REG_SR else
                upper_rd_data_src when src_reg_d >= 8 else
                lower_rd_data_src;
   dst_val_o <= wr_val_i          when wr_en_i = '1' and wr_reg_i = dst_reg_d else
                wr_val_d          when wr_en_d = '1' and wr_addr_d = dst_reg_d else
                dst_val_d         when rd_en_d = '0' else
                reg_sr            when dst_reg_d = C_REG_SR else
                upper_rd_data_dst when dst_reg_d >= 8 else
                lower_rd_data_dst;

end architecture synthesis;

