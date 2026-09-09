-- A dual-port memory with two Wishbone Slave interfaces.
--
-- Port A is READ ONLY; port B reads and writes. That asymmetry comes from
-- src/sub/dp_ram.vhd, which cannot have two write ports and still be both
-- LRM-conformant VHDL-2008 and inferrable as a RAM by Vivado -- see its
-- header. It costs nothing: port A carries the instruction bus, which never
-- writes.
--
-- Each port models slave latency in the two independent ways a pipelined
-- Wishbone slave can be slow, and does so per port, because the instruction
-- and data buses meet different devices in a real system:
--
-- * G_x_STALL_DELAY delays ACCEPTANCE. After each accepted request the port
--   holds STALL for that many cycles, so the master cannot present the next
--   request. This is the shape of back-pressure test/eae.vhd produces.
--
-- * G_x_ACK_DELAY delays the RESPONSE. It is the total latency in cycles from
--   an accepted request to its ACK, so the minimum -- and the default -- is 1.
--   Requests stay pipelined: the master may issue as many as it is willing to
--   leave outstanding, and this is a fixed-latency shift register, so ACKs
--   necessarily come back in issue order.
--
-- The defaults (no stall, one-cycle ACK) are exactly the behaviour this model
-- had before the generics existed.
--
-- The two knobs are not interchangeable, and only the second one exercises the
-- masters' response bookkeeping. A stall is visible to the master before it
-- has committed to anything; a delayed ACK leaves requests in flight, which is
-- what FETCH's wb_stale counting and MEMORY's op-type FIFO exist to track. See
-- src/fetch/README.md and src/memory/README.md.
--
-- Both masters require ACKs in issue order, which a fixed latency per port
-- gives for free.
--
-- Both also forbid an ACK once CYC has been deasserted, because dropping CYC
-- cancels everything outstanding and a late ACK would pair stale data with the
-- address of a request from the new bus cycle. At G_x_ACK_DELAY = 1 that is
-- nearly impossible to get wrong. Above 1 it is not: the pipeline below holds
-- ACKs that are owed for several cycles, so it is cleared when CYC drops, the
-- same way rst_i clears it. Leaving that out corrupts instruction fetch, and
-- only for one specific reason -- FETCH tears the bus cycle down rather than
-- redirecting it when a request is stuck on STB against a stalling slave, a
-- path src/fetch/CLAUDE.md notes "cannot happen against the dual-port RAM here".
-- Setting G_A_STALL_DELAY is what makes it happen.

library ieee;
   use ieee.std_logic_1164.all;
   use std.textio.all;

entity wb_dp_mem is
   generic (
      G_INIT_FILE     : string  := "";
      G_RAM_STYLE     : string  := "block";
      G_ADDR_SIZE     : integer := 8;
      G_DATA_SIZE     : integer := 8;
      -- Cycles of STALL asserted after each accepted request. 0 = never stall.
      G_A_STALL_DELAY : natural := 0;
      G_B_STALL_DELAY : natural := 0;
      -- Total cycles from an accepted request to its ACK. 1 = no added delay,
      -- which is the shortest the underlying dp_ram can do and the shortest
      -- src/memory/memory.vhd permits.
      G_A_ACK_DELAY   : positive := 1;
      G_B_ACK_DELAY   : positive := 1
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      -- Port A: read only
      wb_a_cyc_i   : in  std_logic;
      wb_a_stall_o : out std_logic;
      wb_a_stb_i   : in  std_logic;
      wb_a_ack_o   : out std_logic;
      wb_a_addr_i  : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      wb_a_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0);
      -- Port B: read and write
      wb_b_cyc_i   : in  std_logic;
      wb_b_stall_o : out std_logic;
      wb_b_stb_i   : in  std_logic;
      wb_b_ack_o   : out std_logic;
      wb_b_we_i    : in  std_logic;
      wb_b_addr_i  : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      wb_b_data_i  : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      wb_b_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity wb_dp_mem;

architecture synthesis of wb_dp_mem is

   -- Read data has to be delayed alongside the ACK it accompanies. dp_ram
   -- presents a read on the cycle after its address and re-reads every cycle
   -- (both rd_en inputs are tied high), so with G_x_ACK_DELAY > 1 the array
   -- output has already moved on to whatever address was on the bus in the
   -- meantime by the time the ACK is due.

   type t_data_delay is array (natural range <>) of std_logic_vector(G_DATA_SIZE-1 downto 0);

   -- Port A
   signal a_addr      : std_logic_vector(G_ADDR_SIZE-1 downto 0);
   signal a_rd_data   : std_logic_vector(G_DATA_SIZE-1 downto 0);
   signal a_accept    : std_logic;
   signal a_ack_delay : std_logic_vector(1 to G_A_ACK_DELAY);
   signal a_stall_cnt : natural range 0 to G_A_STALL_DELAY;

   -- Port B
   signal b_addr      : std_logic_vector(G_ADDR_SIZE-1 downto 0);
   signal b_wr_en     : std_logic;
   signal b_wr_data   : std_logic_vector(G_DATA_SIZE-1 downto 0);
   signal b_rd_data   : std_logic_vector(G_DATA_SIZE-1 downto 0);
   signal b_accept    : std_logic;
   signal b_ack_delay : std_logic_vector(1 to G_B_ACK_DELAY);
   signal b_stall_cnt : natural range 0 to G_B_STALL_DELAY;

begin

   i_dp_ram : entity work.dp_ram
      generic map (
         G_INIT_FILE => G_INIT_FILE,
         G_RAM_STYLE => G_RAM_STYLE,
         G_B_READ    => true,
         G_ADDR_SIZE => G_ADDR_SIZE,
         G_DATA_SIZE => G_DATA_SIZE
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         -- Wishbone port A reads only; port B reads and writes, which is
         -- exactly the shape dp_ram offers. See the header.
         a_addr_i    => a_addr,
         a_rd_en_i   => '1',
         a_rd_data_o => a_rd_data,
         b_addr_i    => b_addr,
         b_rd_en_i   => '1',
         b_rd_data_o => b_rd_data,
         b_wr_en_i   => b_wr_en,
         b_wr_data_i => b_wr_data
      ); -- i_dp_ram


   ------------------------------------------------------------
   -- Port A: acceptance, stall and acknowledge
   ------------------------------------------------------------

   a_accept     <= wb_a_cyc_i and wb_a_stb_i and not wb_a_stall_o;
   wb_a_stall_o <= '1' when a_stall_cnt > 0 else
                   '0';
   wb_a_ack_o   <= a_ack_delay(G_A_ACK_DELAY);

   p_a_response : process (clk_i)
   begin
      if rising_edge(clk_i) then
         a_ack_delay(1) <= a_accept;

         for i in 2 to G_A_ACK_DELAY loop
            a_ack_delay(i) <= a_ack_delay(i - 1);
         end loop;

         if a_accept = '1' then
            a_stall_cnt <= G_A_STALL_DELAY;
         elsif a_stall_cnt > 0 then
            a_stall_cnt <= a_stall_cnt - 1;
         end if;

         -- Dropping CYC cancels every request still in flight, so the ACKs
         -- they are owed must not arrive after it. See the header.
         if wb_a_cyc_i = '0' or rst_i = '1' then
            a_ack_delay <= (others => '0');
         end if;

         if rst_i = '1' then
            a_stall_cnt <= 0;
         end if;
      end if;
   end process p_a_response;

   -- With the default one-cycle ACK the array output is already in step, so
   -- there is nothing to delay and the chain below costs nothing.

   gen_a_data : if G_A_ACK_DELAY = 1 generate
      wb_a_data_o <= a_rd_data;
   else generate
      signal a_data_delay : t_data_delay(1 to G_A_ACK_DELAY - 1);
   begin

      p_a_data : process (clk_i)
      begin
         if rising_edge(clk_i) then
            a_data_delay(1) <= a_rd_data;

            for i in 2 to G_A_ACK_DELAY - 1 loop
               a_data_delay(i) <= a_data_delay(i - 1);
            end loop;
         end if;
      end process p_a_data;

      wb_a_data_o <= a_data_delay(G_A_ACK_DELAY - 1);
   end generate gen_a_data;


   ------------------------------------------------------------
   -- Port B: acceptance, stall and acknowledge
   ------------------------------------------------------------

   b_accept     <= wb_b_cyc_i and wb_b_stb_i and not wb_b_stall_o;
   wb_b_stall_o <= '1' when b_stall_cnt > 0 else
                   '0';
   wb_b_ack_o   <= b_ack_delay(G_B_ACK_DELAY);

   p_b_response : process (clk_i)
   begin
      if rising_edge(clk_i) then
         b_ack_delay(1) <= b_accept;

         for i in 2 to G_B_ACK_DELAY loop
            b_ack_delay(i) <= b_ack_delay(i - 1);
         end loop;

         if b_accept = '1' then
            b_stall_cnt <= G_B_STALL_DELAY;
         elsif b_stall_cnt > 0 then
            b_stall_cnt <= b_stall_cnt - 1;
         end if;

         -- Dropping CYC cancels every request still in flight, so the ACKs
         -- they are owed must not arrive after it. See the header.
         if wb_b_cyc_i = '0' or rst_i = '1' then
            b_ack_delay <= (others => '0');
         end if;

         if rst_i = '1' then
            b_stall_cnt <= 0;
         end if;
      end if;
   end process p_b_response;

   gen_b_data : if G_B_ACK_DELAY = 1 generate
      wb_b_data_o <= b_rd_data;
   else generate
      signal b_data_delay : t_data_delay(1 to G_B_ACK_DELAY - 1);
   begin

      p_b_data : process (clk_i)
      begin
         if rising_edge(clk_i) then
            b_data_delay(1) <= b_rd_data;

            for i in 2 to G_B_ACK_DELAY - 1 loop
               b_data_delay(i) <= b_data_delay(i - 1);
            end loop;
         end if;
      end process p_b_data;

      wb_b_data_o <= b_data_delay(G_B_ACK_DELAY - 1);
   end generate gen_b_data;


   a_addr <= wb_a_addr_i;

   -- The write is gated by the stall for the same reason the ACK is: while
   -- the port is stalling, the master is still holding the request it has not
   -- yet had accepted, and writing it once per held cycle would apply it more
   -- than once.
   b_wr_en   <= wb_b_cyc_i and wb_b_stb_i and wb_b_we_i and not wb_b_stall_o;
   b_wr_data <= wb_b_data_i;
   b_addr    <= wb_b_addr_i;

end architecture synthesis;
