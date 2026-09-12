library ieee;
   use ieee.std_logic_1164.all;

-- This instantiates the QNICE CPU and a 8kW RAM. The RAM is pre-initialized
-- with a test program read from the file G_ROM, and is accessible via both the
-- Instruction Memory and Data Memory interfaces.
--
-- With G_SIMULATION, an EAE (Extended Arithmetic Element) and an Interrupt
-- Generator are additionally addressable in the upper half of the data address
-- space, 0x8000-0xFFFF, and a multiplexer splits the data bus between the two.
-- Neither is synthesised; the comment above that generate says why it matters
-- that they are not.

entity system is
   generic (
      G_REGISTER_BANK_WIDTH : integer;
      G_ROM                 : string;
      -- Simulation only: file to log every register and memory write to.
      -- An empty string (the default) disables the logging entirely.
      G_WRITES_FILE         : string := "";
      -- Simulation only: file to write the run statistics to (cycle count and
      -- memory request counts). An empty string disables them.
      G_STATS_FILE          : string := "";
      -- Wishbone slave latency injected by i_wb_dp_mem, per port. The defaults
      -- are the zero-latency behaviour; see that file's header for what the
      -- two kinds of delay do and why they are not interchangeable.
      G_A_STALL_DELAY       : natural  := 0;
      G_B_STALL_DELAY       : natural  := 0;
      G_A_ACK_DELAY         : positive := 1;
      G_B_ACK_DELAY         : positive := 1;
      -- Simulation only: disassemble each retiring instruction to the console.
      -- Passed straight through to WRITE, see src/cpu_main/write.vhd.
      G_DEBUG               : boolean  := false;
      -- True in the testbench, false in synthesis, and it is not merely a
      -- switch for simulation-only conveniences: see the generate below.
      G_SIMULATION          : boolean  := false
   );
   port (
      clk_i  : in  std_logic;
      rstn_i : in  std_logic;
      led_o  : out std_logic_vector(15 downto 0)
   );
end entity system;

architecture synthesis of system is

   -- Instruction Memory
   signal wbi_cyc     : std_logic;
   signal wbi_stb     : std_logic;
   signal wbi_stall   : std_logic;
   signal wbi_addr    : std_logic_vector(15 downto 0);
   signal wbi_ack     : std_logic;
   signal wbi_data_rd : std_logic_vector(15 downto 0);

   -- Data Memory
   signal wbd_cyc     : std_logic;
   signal wbd_stb     : std_logic;
   signal wbd_stall   : std_logic;
   signal wbd_addr    : std_logic_vector(15 downto 0);
   signal wbd_we      : std_logic;
   signal wbd_data_wr : std_logic_vector(15 downto 0);
   signal wbd_ack     : std_logic;
   signal wbd_data_rd : std_logic_vector(15 downto 0);

   signal halt : std_logic;

   -- Data bus as the RAM sees it. In simulation this is the lower half of the
   -- address space, downstream of i_wb_mux; in synthesis it is the whole bus.
   signal wbd_cyc_mem     : std_logic;
   signal wbd_stb_mem     : std_logic;
   signal wbd_stall_mem   : std_logic;
   signal wbd_we_mem      : std_logic;
   signal wbd_addr_mem    : std_logic_vector(15 downto 0);
   signal wbd_data_wr_mem : std_logic_vector(15 downto 0);
   signal wbd_ack_mem     : std_logic;
   signal wbd_data_rd_mem : std_logic_vector(15 downto 0);

   signal irq_valid : std_logic := '0';
   signal irq_ready : std_logic;
   signal irq_addr  : std_logic_vector(15 downto 0) := (others => '0');

begin

   -- Force driving output ports, to avoid Vivado Synthesis pruning to entire
   -- design.
   -- When the CPU is halted, it shows the last instruction fetched.
   led_o <= wbi_addr;


   -- Instantiate the QNICE CPU.
   i_cpu : entity work.cpu
      generic map (
         G_REGISTER_BANK_WIDTH => G_REGISTER_BANK_WIDTH,
         G_WRITES_FILE         => G_WRITES_FILE,
         G_DEBUG               => G_DEBUG
      )
      port map (
         clk_i       => clk_i,
         rst_i       => not rstn_i,
         wbi_cyc_o   => wbi_cyc,
         wbi_stb_o   => wbi_stb,
         wbi_stall_i => wbi_stall,
         wbi_addr_o  => wbi_addr,
         wbi_ack_i   => wbi_ack,
         wbi_data_i  => wbi_data_rd,
         wbd_cyc_o   => wbd_cyc,
         wbd_stb_o   => wbd_stb,
         wbd_stall_i => wbd_stall,
         wbd_addr_o  => wbd_addr,
         wbd_we_o    => wbd_we,
         wbd_dat_o   => wbd_data_wr,
         wbd_ack_i   => wbd_ack,
         wbd_data_i  => wbd_data_rd,
         irq_valid_i => irq_valid,
         irq_ready_o => irq_ready,
         irq_addr_i  => irq_addr,
         halt_o      => halt
      ); -- i_cpu


   -- Dual Port pre-initialized RAM.
   i_wb_dp_mem : entity work.wb_dp_mem
      generic map (
         G_INIT_FILE     => G_ROM,
         G_RAM_STYLE     => "block",
         G_ADDR_SIZE     => 13,
         G_DATA_SIZE     => 16,
         G_A_STALL_DELAY => G_A_STALL_DELAY,
         G_B_STALL_DELAY => G_B_STALL_DELAY,
         G_A_ACK_DELAY   => G_A_ACK_DELAY,
         G_B_ACK_DELAY   => G_B_ACK_DELAY
      )
      port map (
         clk_i        => clk_i,
         rst_i        => not rstn_i,
         wb_a_cyc_i   => wbi_cyc,
         wb_a_stb_i   => wbi_stb,
         wb_a_stall_o => wbi_stall,
         wb_a_addr_i  => wbi_addr(12 downto 0),
         wb_a_ack_o   => wbi_ack,
         wb_a_data_o  => wbi_data_rd,
         --
         wb_b_cyc_i   => wbd_cyc_mem,
         wb_b_stb_i   => wbd_stb_mem,
         wb_b_stall_o => wbd_stall_mem,
         wb_b_addr_i  => wbd_addr_mem(12 downto 0),
         wb_b_we_i    => wbd_we_mem,
         wb_b_data_i  => wbd_data_wr_mem,
         wb_b_ack_o   => wbd_ack_mem,
         wb_b_data_o  => wbd_data_rd_mem
      ); -- i_wb_dp_mem


   -- The upper half of the data address space, 0x8000-0xFFFF, holds the EAE and
   -- the Interrupt Generator, and they exist only in simulation -- they are
   -- there to give prog_mandel_perf.asm a multiplier, i.e. to make one test
   -- program's instruction mix realistic, and to test the hardware interrupt
   -- feature in prog_int_hw.asm. Nothing in a bitstream ever addresses this
   -- address space.
   --
   -- So the multiplexer in front of it is simulation-only too, and NOT because
   -- it is untidy to synthesise dead logic. It costs real timing margin, in two
   -- ways, both measured with Vivado 2022.2 at the 7.35 ns constraint:
   --
   --   * The module itself is 38 flip-flops and 80 LUTs, mostly the response
   --     buffer that restores order between two slaves of differing latency.
   --   * Worse, i_wb_dp_mem never stalls at the default latency generics, so
   --     with a direct connection wbd_stall is a synthesis CONSTANT '0' and the
   --     CPU's entire hold-a-stalled-request path folds away. wb_mux's own
   --     mux_stall term makes it live again, which puts back 32 flip-flops in
   --     MEMORY and 79 LUTs in CPU_MAIN -- the latter in exactly the stage the
   --     critical path runs through.
   --
   -- Together: 1076 LUTs / 673 registers and WNS -0.148 ns with three failing
   -- endpoints, against 939 / 603 and WNS +0.060 ns without. That is a failed
   -- build bought entirely with logic no bitstream can reach. Note the second
   -- effect would survive a leaner multiplexer: any slave that can stall costs
   -- it.

   gen_sim : if G_SIMULATION generate

      signal wbd_cyc_dev     : std_logic;
      signal wbd_stb_dev     : std_logic;
      signal wbd_stall_dev   : std_logic;
      signal wbd_we_dev      : std_logic;
      signal wbd_addr_dev    : std_logic_vector(15 downto 0);
      signal wbd_data_wr_dev : std_logic_vector(15 downto 0);
      signal wbd_ack_dev     : std_logic;
      signal wbd_data_rd_dev : std_logic_vector(15 downto 0);

      signal wbd_cyc_eae     : std_logic;
      signal wbd_stb_eae     : std_logic;
      signal wbd_stall_eae   : std_logic;
      signal wbd_we_eae      : std_logic;
      signal wbd_addr_eae    : std_logic_vector(15 downto 0);
      signal wbd_data_wr_eae : std_logic_vector(15 downto 0);
      signal wbd_ack_eae     : std_logic;
      signal wbd_data_rd_eae : std_logic_vector(15 downto 0);

      signal wbd_cyc_int     : std_logic;
      signal wbd_stb_int     : std_logic;
      signal wbd_stall_int   : std_logic;
      signal wbd_we_int      : std_logic;
      signal wbd_addr_int    : std_logic_vector(15 downto 0);
      signal wbd_data_wr_int : std_logic_vector(15 downto 0);
      signal wbd_ack_int     : std_logic;
      signal wbd_data_rd_int : std_logic_vector(15 downto 0);

   begin

      -- Split the address bus at 0x8000: RAM below, dev above. Note this is a real
      -- multiplexer and not just an address decode -- the two slaves have
      -- different, and configurable, latencies, and a pipelined WISHBONE master
      -- can only pair responses with requests by position. See wb_mux.vhd.
      i_wb_mux : entity work.wb_mux
         generic map (
            G_ADDR_SIZE       => 16,
            G_DATA_SIZE       => 16,
            G_MAX_OUTSTANDING => 2
         )
         port map (
            clk_i      => clk_i,
            rst_i      => not rstn_i,
            s_cyc_i    => wbd_cyc,
            s_stb_i    => wbd_stb,
            s_stall_o  => wbd_stall,
            s_we_i     => wbd_we,
            s_addr_i   => wbd_addr,
            s_data_i   => wbd_data_wr,
            s_ack_o    => wbd_ack,
            s_data_o   => wbd_data_rd,
            s_sel_i    => wbd_addr(15),
            --
            m0_cyc_o   => wbd_cyc_mem,
            m0_stb_o   => wbd_stb_mem,
            m0_stall_i => wbd_stall_mem,
            m0_we_o    => wbd_we_mem,
            m0_addr_o  => wbd_addr_mem,
            m0_data_o  => wbd_data_wr_mem,
            m0_ack_i   => wbd_ack_mem,
            m0_data_i  => wbd_data_rd_mem,
            --
            m1_cyc_o   => wbd_cyc_dev,
            m1_stb_o   => wbd_stb_dev,
            m1_stall_i => wbd_stall_dev,
            m1_we_o    => wbd_we_dev,
            m1_addr_o  => wbd_addr_dev,
            m1_data_o  => wbd_data_wr_dev,
            m1_ack_i   => wbd_ack_dev,
            m1_data_i  => wbd_data_rd_dev
         ); -- i_wb_mux

      -- Split the address bus at 0xC000: INT below, EAE above. Note this is a real
      -- multiplexer and not just an address decode -- the two slaves have
      -- different, and configurable, latencies, and a pipelined WISHBONE master
      -- can only pair responses with requests by position. See wb_mux.vhd.
      i_wb_mux_dev : entity work.wb_mux
         generic map (
            G_ADDR_SIZE       => 16,
            G_DATA_SIZE       => 16,
            G_MAX_OUTSTANDING => 2
         )
         port map (
            clk_i      => clk_i,
            rst_i      => not rstn_i,
            s_cyc_i    => wbd_cyc_dev,
            s_stb_i    => wbd_stb_dev,
            s_stall_o  => wbd_stall_dev,
            s_we_i     => wbd_we_dev,
            s_addr_i   => wbd_addr_dev,
            s_data_i   => wbd_data_wr_dev,
            s_ack_o    => wbd_ack_dev,
            s_data_o   => wbd_data_rd_dev,
            s_sel_i    => wbd_addr_dev(14),
            --
            m0_cyc_o   => wbd_cyc_int,
            m0_stb_o   => wbd_stb_int,
            m0_stall_i => wbd_stall_int,
            m0_we_o    => wbd_we_int,
            m0_addr_o  => wbd_addr_int,
            m0_data_o  => wbd_data_wr_int,
            m0_ack_i   => wbd_ack_int,
            m0_data_i  => wbd_data_rd_int,
            --
            m1_cyc_o   => wbd_cyc_eae,
            m1_stb_o   => wbd_stb_eae,
            m1_stall_i => wbd_stall_eae,
            m1_we_o    => wbd_we_eae,
            m1_addr_o  => wbd_addr_eae,
            m1_data_o  => wbd_data_wr_eae,
            m1_ack_i   => wbd_ack_eae,
            m1_data_i  => wbd_data_rd_eae
         ); -- i_wb_mux_dev


         -- EAE (Extended Arithmetic Element)
      i_eae : entity work.eae
         generic map (
            G_DELAY => 3
         )
         port map (
            clk_i     => clk_i,
            rst_i     => not rstn_i,
            cyc_i     => wbd_cyc_eae,
            stb_i     => wbd_stb_eae,
            stall_o   => wbd_stall_eae,
            addr_i    => wbd_addr_eae(2 downto 0),
            we_i      => wbd_we_eae,
            wr_data_i => wbd_data_wr_eae,
            ack_o     => wbd_ack_eae,
            rd_data_o => wbd_data_rd_eae
         ); -- i_eae

         -- INT (Interrupt Generator)
      i_interrupt : entity work.interrupt
         port map (
            clk_i        => clk_i,
            rst_i        => not rstn_i,
            wb_cyc_i     => wbd_cyc_int,
            wb_stb_i     => wbd_stb_int,
            wb_stall_o   => wbd_stall_int,
            wb_addr_i    => wbd_addr_int(2 downto 0),
            wb_we_i      => wbd_we_int,
            wb_wr_data_i => wbd_data_wr_int,
            wb_ack_o     => wbd_ack_int,
            wb_rd_data_o => wbd_data_rd_int,
            irq_valid_o  => irq_valid,
            irq_ready_i  => irq_ready,
            irq_addr_o   => irq_addr
         ); -- i_interrupt

   else generate

      -- One slave, so nothing can arrive out of order and there is nothing to
      -- multiplex: the RAM aliases across the whole 64 kW data address space.
      wbd_cyc_mem     <= wbd_cyc;
      wbd_stb_mem     <= wbd_stb;
      wbd_stall       <= wbd_stall_mem;
      wbd_we_mem      <= wbd_we;
      wbd_addr_mem    <= wbd_addr;
      wbd_data_wr_mem <= wbd_data_wr;
      wbd_ack         <= wbd_ack_mem;
      wbd_data_rd     <= wbd_data_rd_mem;

   end generate gen_sim;


-- pragma synthesis_off
   -- The two request terms are accepted beats in pipelined Wishbone: the slave
   -- takes the request in the cycle where cyc and stb are high and stall is
   -- low. Counting those rather than stb alone means a stalled request is
   -- counted once, not once per cycle it is held.
   i_test_monitor : entity work.test_monitor
      generic map (
         G_STATS_FILE => G_STATS_FILE
      )
      port map (
         clk_i      => clk_i,
         rst_i      => not rstn_i,
         halt_i     => halt,
         mem_we_i   => wbd_stb and wbd_we and not wbd_stall,
         mem_addr_i => wbd_addr,
         mem_data_i => wbd_data_wr,
         wbi_req_i  => wbi_cyc and wbi_stb and not wbi_stall,
         wbd_req_i  => wbd_cyc and wbd_stb and not wbd_stall
      ); -- i_test_monitor
-- pragma synthesis_on

end architecture synthesis;

