-- dp_ram - Single-clock dual-port RAM: port A reads, port B reads and writes.
--
-- FUNCTION
--   Two independently addressed ports sharing one clock and one memory array.
--   Writes take effect on the rising edge. Reads are registered with a 1-cycle
--   latency and gated by their read enable (*_rd_data_o holds its previous
--   value while *_rd_en_i = '0'). Port A's output register can be removed with
--   G_READ_REG => false, which turns that port into a same-cycle read; see
--   G_READ_REG below.
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
--   sharing its process with the write. With G_READ_REG = true they are
--   behaviourally identical -- same latency, same read-first ordering, same
--   read-enable gating.
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
-- G_READ_REG (both read ports)
--   true  - the default and the configuration everything in this repo uses.
--           Both ports read with the 1-cycle latency described above.
--
--   false - the rising-edge output register is removed from BOTH read ports,
--           so the data for the address presented in a cycle is available at
--           the END of that SAME cycle. Both ports keep a clocked array
--           access, so this stays synthesisable to Block RAM -- see
--           gen_b_block below for what that costs on port B. This is what a zero-latency Wishbone slave needs: an
--           ACK returned in the cycle the request is accepted (see
--           src/memory/README.md and src/fetch/README.md). It costs a
--           combinational path from a_addr_i to a_rd_data_o, so it is opt-in.
--
--           Port B follows its style: an asynchronous read under
--           "distributed", and under "block" the same falling-edge staging
--           port A uses -- together with a falling-edge WRITE, which is what
--           keeps it on one clock and therefore mappable to a Block RAM. See
--           gen_b_block below; moving the write is invisible at cycle
--           granularity but halves the write setup budget.
--
--           Port A keeps whatever staging its style gives it, so BOTH styles
--           lose exactly one cycle of latency there, but they present the data
--           at different points WITHIN the cycle:
--             "block"       - the falling-edge register stays, so the array
--                             read still happens on the falling edge and only
--                             the wire from it is combinational. The data
--                             appears MID-CYCLE and is stable from there to
--                             the closing edge -- about half a cycle of setup
--                             for the consumer, and a correspondingly relaxed
--                             path. Requires a reasonably balanced duty cycle,
--                             as the registered block configuration already
--                             does.
--             "distributed" - a genuine asynchronous LUTRAM read: address to
--                             data is combinational for the WHOLE cycle. More
--                             setup for the consumer, but the entire array
--                             access is now on the critical path.
--
--           The block variant is easy to mis-predict, so it is worth being
--           explicit: it does NOT keep the 1-cycle latency merely because a
--           register remains in the path. That register captures the CURRENT
--           cycle's address halfway through the cycle, so the value is out
--           before the edge that ENDS that cycle. formal/dp_ram.psl states the
--           two styles with different properties for exactly this reason --
--           f_read_back_async (same cycle) for distributed, and
--           f_read_back_async_block (low phase only) for block, because for
--           block neither plain rising-edge form is true: |=> is too late and
--           |-> is too early.
--
--           The read enables keep a meaning rather than being ignored: with no
--           register there is nothing to hold, so instead of holding its
--           previous value *_rd_data_o reads all-zeros while *_rd_en_i = '0'.
--           Deliberate, not incidental. A silently-inert port is the trap
--           G_B_READ already documents below; a caller that drives a_rd_en_i
--           low deserves a defined output rather than the array contents at
--           whatever a_addr_i happens to be. The mask costs one AND per bit --
--           if it ever lands on a critical path, dropping it (output follows
--           the address unconditionally) is a one-line change, but then say so
--           here and fix f_read_zero_when_disabled in formal/dp_ram.psl.
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
--   G_READ_REG  : keep both read ports' output registers (default). False
--                 makes them same-cycle reads; see G_READ_REG above.
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
      G_READ_REG  : boolean := true;    -- keep the read output registers
      G_ADDR_SIZE : positive;
      G_DATA_SIZE : positive
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;                                   -- unused (see header)
      -- Port A: read only, gated by a_rd_en_i. Registered with 1-cycle
      -- latency by default; same-cycle and zero when disabled if G_READ_REG is
      -- false. Staged through a falling-edge register when
      -- G_RAM_STYLE = "block".
      a_addr_i    : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      a_rd_en_i   : in  std_logic;
      a_rd_data_o : out std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');
      -- Port B: read and write, both at b_addr_i. Same read latency and
      -- ordering as port A, and G_READ_REG applies here too. The read half
      -- exists only when G_B_READ is set; b_rd_en_i and b_rd_data_o are then
      -- tied off and inert.
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

   -- The same, for port B, used only when G_READ_REG is false: with the output
   -- register gone, this is what keeps port B's array read on a clock edge
   -- instead of turning it into an asynchronous read a Block RAM cannot serve.
   signal b_rd_data : std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');

begin

   -- Elaboration-time guard (ignored by synthesis). Also rejects empty/typo'd
   -- style strings before they silently fall through to the distributed branch.
   assert G_RAM_STYLE = "block" or G_RAM_STYLE = "distributed"
      report "G_RAM_STYLE must be either 'block' or 'distributed'. Incorrect value is " & G_RAM_STYLE
      severity failure;

   gen_b_reg : if G_READ_REG generate

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

   else generate

      gen_b_block : if G_RAM_STYLE = "block" generate

         -- G_READ_REG = false, block style. Port A's falling-edge trick,
         -- applied to port B -- and it has to be applied to the WRITE as well,
         -- which is the part that is easy to miss.
         --
         -- Staging only the read is not enough: port B would then want a
         -- falling-edge read and a rising-edge write, and a Block RAM port has
         -- ONE clock. Vivado says so directly -- "[Synth 8-6849] Infeasible
         -- attribute ram_style = block ... trying to implement using LUTRAM" --
         -- and drops the whole 8Kx16 array into 4096 LUTRAMs. Putting both on
         -- the falling edge gives port B a single clock again and the array
         -- maps to 4 RAMB36, exactly as in the registered configuration.
         -- Measured numbers are in test/wb_dp_mem.vhd's header.
         --
         -- Moving the write is invisible from outside at cycle granularity.
         -- The write lands mid-cycle N rather than at the edge that ends it,
         -- but both read ports also sample on that same falling edge and take
         -- the pre-edge contents, so a read requested in cycle N still returns
         -- the old value (read-first, unchanged) and one requested in cycle N+1
         -- still returns the new one. What it does cost is write setup: the
         -- address and data now have to be stable by mid-cycle rather than by
         -- the end of it. Fine here -- they come from CPU registers and are
         -- stable all cycle -- but it is a real constraint on any other caller.
         p_b_write : process (clk_i)
         begin
            if falling_edge(clk_i) then
               if b_wr_en_i = '1' then
                  dp_ram_r(to_integer(b_addr_i)) <= b_wr_data_i;
               end if;
            end if;
         end process p_b_write;

         gen_b_read : if G_B_READ generate

            p_b_read_falling : process (clk_i)
            begin
               if falling_edge(clk_i) then
                  b_rd_data <= dp_ram_r(to_integer(b_addr_i));
               end if;
            end process p_b_read_falling;

            b_rd_data_o <= b_rd_data when b_rd_en_i = '1' else
                           (others => '0');

         end generate gen_b_read;

      else generate

         -- G_READ_REG = false, distributed style. A LUTRAM read is
         -- asynchronous by nature, so there is nothing to stage and no reason
         -- to move the write off the rising edge.
         p_b_write : process (clk_i)
         begin
            if rising_edge(clk_i) then
               if b_wr_en_i = '1' then
                  dp_ram_r(to_integer(b_addr_i)) <= b_wr_data_i;
               end if;
            end if;
         end process p_b_write;

         gen_b_read : if G_B_READ generate

            -- Read-first ordering survives: the write above lands on the NEXT
            -- rising edge, so a read in the same cycle still sees the old
            -- contents.
            b_rd_data_o <= dp_ram_r(to_integer(b_addr_i)) when b_rd_en_i = '1' else
                           (others => '0');

         end generate gen_b_read;

      end generate gen_b_block;

   end generate gen_b_reg;


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

      gen_a_reg_block : if G_READ_REG generate

         -- Rising-edge output register, gated by a_rd_en_i (holds when '0').
         p_read_rising : process (clk_i)
         begin
            if rising_edge(clk_i) then
               if a_rd_en_i = '1' then
                  a_rd_data_o <= a_rd_data;
               end if;
            end if;
         end process p_read_rising;

      else generate

         -- Same-cycle read: the falling-edge stage above already holds this
         -- cycle's array read by mid-cycle, so the output is just a wire from
         -- it and settles half a cycle before the consumer samples. Masked to
         -- zero rather than held when disabled -- there is no register left to
         -- hold anything, and inferring a latch here would be a bug, not a
         -- feature. See G_READ_REG in the header.
         a_rd_data_o <= a_rd_data when a_rd_en_i = '1' else
                        (others => '0');

      end generate gen_a_reg_block;

   else generate -- G_RAM_STYLE = "distributed"

      gen_a_reg_dist : if G_READ_REG generate

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

      else generate

         -- Asynchronous LUTRAM read: address to data is combinational for the
         -- whole cycle, which is a materially longer path than the block-style
         -- branch above gives -- see G_READ_REG in the header before choosing
         -- this combination.
         a_rd_data_o <= dp_ram_r(to_integer(a_addr_i)) when a_rd_en_i = '1' else
                        (others => '0');

      end generate gen_a_reg_dist;

   end generate gen_block_ram;

end architecture synthesis;
