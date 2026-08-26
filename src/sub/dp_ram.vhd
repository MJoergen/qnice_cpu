-- dp_ram - Single-clock dual-port RAM: port A reads, port B reads and writes.
--
-- FUNCTION
--   Two independently addressed ports sharing one clock and one memory array.
--   Writes take effect on the rising edge. Reads are registered with a 1-cycle
--   latency and gated by their read enable (*_rd_data_o holds its previous
--   value while *_rd_en_i = '0').
--
--   Two ports, each with ONE address. Port A reads. Port B reads and writes,
--   both at b_addr_i. Tie off whatever an instance does not need:
--
--     The register file reads on port A and writes on port B, leaving G_B_READ
--     false. Two independent addresses, which is what it needs.
--
--     The testbench memory model reads on both ports and writes on port B, so
--     it sets G_B_READ.
--
--   ONE ADDRESS PER PORT IS LOAD BEARING, and is why there is no separate
--   wr_addr_i. An FPGA RAM primitive has exactly two ports, each with one
--   address; a third independent address does not fit and the synthesiser
--   duplicates the array instead. Giving the write its own address port cost
--   8 RAMB36 rather than 4 on the 8Kx16 testbench memory, measured. Note this
--   bites even when a caller drives two of the addresses from the same net,
--   because "make utilization" synthesises with -flatten_hierarchy none and
--   this module is then elaborated in isolation, where they are simply two
--   different input ports.
--
--   THE TWO PORTS ARE NOT INTERCHANGEABLE. Port A is the timing-optimised
--   read: under G_RAM_STYLE = "block" it is staged through a falling-edge
--   register (see below), which is what puts the register file's read on the
--   right side of its critical path. Port B's read is a plain rising-edge read
--   sharing its process with the write. Behaviourally they are identical --
--   same latency, same read-first ordering, same read-enable gating.
--
-- WHY ONLY PORT B WRITES
--   A second write port cannot be had without either a "shared variable",
--   which VHDL-2008 forbids outside a protected type, or two writes in one
--   process, which Vivado refuses to infer a RAM from (Synth 8-4767). One
--   writer keeps the array an ordinary signal with a single driver. Nothing
--   here needs two: see doc/README.md and test/wb_dp_mem.vhd.
--
-- READ/WRITE ORDERING (read-first, on both read ports)
--   A simultaneous read and write to the SAME address returns the OLD contents
--   (the value prior to the concurrent write); the freshly written value is
--   observable on the following read. This holds identically for BOTH values of
--   G_RAM_STYLE - the block-mode falling-edge register only moves timing, it does
--   not change data or latency (rd_data_o[N+1] = rd_en[N] ? mem[N][rd_addr[N]] :
--   rd_data_o[N] in every case).
--
-- G_RAM_STYLE
--   "block"       - targets Block RAM. On port A an extra register (a_rd_data)
--                   captures the array read on the FALLING edge, then a_rd_data_o
--                   registers it on the rising edge. Splitting the array-read
--                   and output paths across half a cycle eases timing on
--                   wide/deep BRAMs. Requires a reasonably balanced clock duty
--                   cycle. Port B is a plain rising-edge read either way.
--   "distributed" - targets LUT/distributed RAM. A single rising-edge read
--                   register suffices; the falling-edge trick is neither possible
--                   nor necessary here.
--
-- RESET
--   None. Memory contents come from G_INIT_FILE (or zero) and are not reset by
--   rst_i. rst_i is unused and kept only for interface uniformity / the formal
--   testbench; remove it if your conventions disallow dangling ports.
--
-- GENERICS
--   G_INIT_FILE : text file of one binary word per line; "" leaves memory zero.
--   G_RAM_STYLE : "block" or "distributed" (validated below).
--   G_B_READ    : generate port B's read half. Leave false for a write-only
--                 port B; see the note at the read itself for why the caller's
--                 tie-off is not enough on its own.
--   G_ADDR_SIZE : address width; memory depth is 2**G_ADDR_SIZE words.
--   G_DATA_SIZE : data word width in bits.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;
   use std.textio.all;

entity dp_ram is
   generic (
      G_INIT_FILE : string  := "";
      G_RAM_STYLE : string  := "block"; -- "block" or "distributed"
      G_B_READ    : boolean := false;   -- enable port B's read half
      G_ADDR_SIZE : positive;
      G_DATA_SIZE : positive
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;                                   -- unused (see header)
      -- Port A: read only (registered, 1-cycle latency, gated by a_rd_en_i).
      -- Staged through a falling-edge register when G_RAM_STYLE = "block".
      a_addr_i    : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      a_rd_en_i   : in  std_logic;
      a_rd_data_o : out std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');
      -- Port B: read and write, both at b_addr_i. Same read latency and
      -- ordering as port A. The read half exists only when G_B_READ is set;
      -- b_rd_en_i and b_rd_data_o are then tied off and inert.
      b_addr_i    : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      b_rd_en_i   : in  std_logic;
      b_rd_data_o : out std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');
      b_wr_en_i   : in  std_logic;
      b_wr_data_i : in  std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity dp_ram;

architecture synthesis of dp_ram is

   type t_mem is array (0 to 2**G_ADDR_SIZE-1) of std_logic_vector(G_DATA_SIZE-1 downto 0);

   -- Initial memory contents, read from a text file of one binary word per line.
   -- A short file leaves the remaining words at zero.
   impure function init_from_file(file_name : string) return t_mem is
      file     init_file : text;
      variable init_line : line;
      variable mem       : t_mem := (others => (others => '0'));
   begin
      if file_name /= "" then
         file_open(init_file, file_name, read_mode);
         for i in t_mem'range loop
            readline(init_file, init_line);
            read(init_line, mem(i));
            if endfile(init_file) then
               return mem;
            end if;
         end loop;
      end if;
      return mem;
   end function init_from_file;

   -- The memory array. ram_style guides the synthesiser's implementation choice.
   signal dp_ram_r : t_mem := init_from_file(G_INIT_FILE);

   attribute ram_style : string;
   attribute ram_style of dp_ram_r : signal is G_RAM_STYLE;

   -- Block-mode only: falling-edge capture of port A's array read, staged before
   -- the rising-edge output register. Initialised for a defined power-up value
   -- (also keeps this state element well-behaved under formal k-induction).
   signal a_rd_data : std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');

begin

   -- Elaboration-time guard (ignored by synthesis). Also rejects empty/typo'd
   -- style strings before they silently fall through to the distributed branch.
   assert G_RAM_STYLE = "block" or G_RAM_STYLE = "distributed"
      report "G_RAM_STYLE must be either 'block' or 'distributed'. Incorrect value is " & G_RAM_STYLE
      severity failure;

   -- Port B: the write (sole driver of dp_ram_r) together with port B's read,
   -- at the shared address b_addr_i. They MUST stay in this one process, on
   -- this one edge and on this one address, or they stop sharing a physical RAM
   -- port and the array is duplicated -- see the header.
   --
   -- Read-first ordering falls out of signal semantics rather than statement
   -- order: the read's right-hand side is evaluated with the pre-edge contents
   -- of dp_ram_r, so a write in the same cycle is not visible to it.
   p_b : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- The G_B_READ term is what actually removes the read, and it has to
         -- be the generic rather than the caller's b_rd_en_i => '0': the
         -- per-module utilization pass synthesises with -flatten_hierarchy
         -- none, where a tie-off applied at the instantiation is not visible
         -- and the whole read port gets built anyway. That cost 40 LUTs of
         -- phantom LUTRAM in the register file's row of the table in
         -- doc/README.md. The shipping build flattens and prunes it either
         -- way, so this is about the measurement being honest, not the gates.
         if G_B_READ and b_rd_en_i = '1' then
            b_rd_data_o <= dp_ram_r(to_integer(b_addr_i));
         end if;

         if b_wr_en_i = '1' then
            dp_ram_r(to_integer(b_addr_i)) <= b_wr_data_i;
         end if;
      end if;
   end process p_b;


   gen_block_ram : if G_RAM_STYLE = "block" generate

      -- Falling-edge array read. Not gated by the read enable: the staging
      -- register reloads every cycle (a minor dynamic-power cost) so the output
      -- stage sees a settled value. Sees memory as of this cycle - i.e.
      -- excluding a write issued in the same cycle - which is what yields
      -- read-first ordering.
      --
      -- This trick of having a falling_edge register followed by a rising_edge
      -- register is purely an internal optimization to improve timing. To the
      -- user of this module, the timing semantics is just the ordinary
      -- one-cycle delay at rising clock edge.  The falling_edge register is
      -- absorbed into the Block RAM (as an address register). Without this
      -- falling_edge register, i.e. with *only* the rising_edge register, there
      -- would still be a approximately 2 ns Clock-to-Data delay, due to the
      -- Block RAM. With the falling_edge register first followed by the
      -- rising_edge register, the overall Clock-to-Data delay on the output is
      -- close to 0 ns. This allows a longer data-path on the read data.
      p_read_falling : process (clk_i)
      begin
         if falling_edge(clk_i) then
            a_rd_data <= dp_ram_r(to_integer(a_addr_i));
         end if;
      end process p_read_falling;

      -- Rising-edge output register, gated by a_rd_en_i (holds when '0').
      p_read_rising : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if a_rd_en_i = '1' then
               a_rd_data_o <= a_rd_data;
            end if;
         end if;
      end process p_read_rising;

   else generate -- G_RAM_STYLE = "distributed"

      -- Distributed RAM: a single rising-edge read register is enough; the
      -- falling-edge staging used for Block RAM is neither available nor needed.
      p_read : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if a_rd_en_i = '1' then
               a_rd_data_o <= dp_ram_r(to_integer(a_addr_i));
            end if;
         end if;
      end process p_read;

   end generate gen_block_ram;

end architecture synthesis;
