library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

-- -----------------------------------------------------------------------------
-- dp_ram - Single-clock simple dual-port RAM (1 write port, 1 read port)
-- -----------------------------------------------------------------------------
--
-- FUNCTION
--   Independent write and read ports sharing one clock. Writes are synchronous
--   to the rising edge. Reads are registered with a 1-cycle latency and gated by
--   rd_en_i (rd_data_o holds its previous value while rd_en_i = '0').
--
-- READ/WRITE ORDERING (read-first)
--   A simultaneous read and write to the SAME address returns the OLD contents
--   (the value prior to the concurrent write); the freshly written value is
--   observable on the following read. This holds identically for BOTH values of
--   G_RAM_STYLE - the block-mode falling-edge register only moves timing, it does
--   not change data or latency (rd_data_o[N+1] = rd_en[N] ? mem[N][rd_addr[N]] :
--   rd_data_o[N] in both cases).
--
-- G_RAM_STYLE
--   "block"       - targets Block RAM. An extra register (rd_data) captures the
--                   array read on the FALLING edge, then rd_data_o registers it
--                   on the rising edge. Splitting the array-read and output paths
--                   across half a cycle eases timing on wide/deep BRAMs. Requires
--                   a reasonably balanced clock duty cycle.
--   "distributed" - targets LUT/distributed RAM. A single rising-edge read
--                   register suffices; the falling-edge trick is neither possible
--                   nor necessary here.
--
-- RESET
--   None. Memory contents power up to 0 (array initializer) and are not reset by
--   rst_i. rst_i is unused and kept only for interface uniformity / the formal
--   testbench; remove it if your conventions disallow dangling ports.
--
-- GENERICS
--   G_RAM_STYLE : "block" or "distributed" (validated below).
--   G_ADDR_SIZE : address width; memory depth is 2**G_ADDR_SIZE words.
--   G_DATA_SIZE : data word width in bits.
-- -----------------------------------------------------------------------------

entity dp_ram is
   generic (
      G_RAM_STYLE : string := "block"; -- "block" or "distributed"
      G_ADDR_SIZE : positive;
      G_DATA_SIZE : positive
   );
   port (
      clk_i     : in    std_logic;
      rst_i     : in    std_logic;                                   -- unused (see header)
      -- Write interface (synchronous, rising edge)
      wr_addr_i : in    std_logic_vector(G_ADDR_SIZE-1 downto 0);
      wr_data_i : in    std_logic_vector(G_DATA_SIZE-1 downto 0);
      wr_en_i   : in    std_logic;
      -- Read interface (registered, 1-cycle latency, gated by rd_en_i)
      rd_en_i   : in    std_logic;
      rd_addr_i : in    std_logic_vector(G_ADDR_SIZE-1 downto 0);
      rd_data_o : out   std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity dp_ram;

architecture synthesis of dp_ram is

   type mem_t is array (0 to 2**G_ADDR_SIZE-1) of std_logic_vector(G_DATA_SIZE-1 downto 0);

   -- The memory array. ram_style guides the synthesiser's implementation choice.
   signal dp_ram_r : mem_t := (others => (others => '0'));

   attribute ram_style : string;
   attribute ram_style of dp_ram_r : signal is G_RAM_STYLE;

   -- Block-mode only: falling-edge capture of the array read, staged before the
   -- rising-edge output register. Initialised for a defined power-up value (also
   -- keeps this second state element well-behaved under formal k-induction).
   signal rd_data : std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');

begin

   -- Elaboration-time guard (ignored by synthesis). Also rejects empty/typo'd
   -- style strings before they silently fall through to the distributed branch.
   assert G_RAM_STYLE = "block" or G_RAM_STYLE = "distributed"
      report "G_RAM_STYLE must be either 'block' or 'distributed'. Incorrect value is " & G_RAM_STYLE
      severity failure;

   -- Synchronous write port.
   p_write : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wr_en_i = '1' then
            dp_ram_r(to_integer(wr_addr_i)) <= wr_data_i;
         end if;
      end if;
   end process p_write;


   gen_block_ram : if G_RAM_STYLE = "block" generate

      -- Falling-edge array read. Not gated by rd_en_i: rd_data reloads every
      -- cycle (a minor dynamic-power cost) so the output stage sees a settled
      -- value. Sees memory as of this cycle - i.e. excluding a write issued in
      -- the same cycle - which is what yields read-first ordering.
      p_read_falling : process (clk_i)
      begin
         if falling_edge(clk_i) then
            rd_data <= dp_ram_r(to_integer(rd_addr_i));
         end if;
      end process p_read_falling;

      -- Rising-edge output register, gated by rd_en_i (holds when '0').
      p_read_rising : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if rd_en_i = '1' then
               rd_data_o <= rd_data;
            end if;
         end if;
      end process p_read_rising;

   else generate -- G_RAM_STYLE = "distributed"

      -- Distributed RAM: a single rising-edge read register is enough; the
      -- falling-edge staging used for Block RAM is neither available nor needed.
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

