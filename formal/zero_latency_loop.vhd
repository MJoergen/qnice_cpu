-- Combinational-loop harness for the zero-latency-slave configuration.
--
-- WHAT THIS IS FOR
-- The CPU supports a Wishbone slave that acknowledges in the same cycle it
-- accepts a request (see src/memory/README.md#Zero-latency-ACKs and
-- src/fetch/README.md#Zero-latency-ACKs). Such a slave makes wb_ack_i a
-- combinational function of wb_stb_o, which turns any path from wb_ack_i back
-- to wb_stb_o into a real combinational cycle. There is no PSL property to
-- write here: the question is whether the elaborated netlist contains a cycle
-- at all, and yosys "check -assert" answers exactly that.
--
-- WHY IT HAS TO BE THE WHOLE CPU
-- Checking the modules in isolation is NOT enough, and believing otherwise is
-- how this was missed the first time. Standalone, memory.vhd is loop-free for
-- any behaviour of msrc_ready_i / mdst_ready_i, because those are free inputs.
-- In the assembled CPU they come from PREPARE, whose wait_for_mem_dst makes
-- SRC-ready depend on DST-valid -- so a mreq_accept that reads them closes:
--
--    wbd_ack -> memory.wb_ack_zero_lat -> wb_ack_op(DST)
--            -> i_two_stage_buffer_dst -> mdst_valid_o
--            -> prepare.wait_for_mem_dst -> msrc_ready_i
--            -> memory.mreq_accept -> i_one_stage_buffer_wb -> wbd_stb
--            -> wbd_ack
--
-- Six such loops existed until mreq_accept was made to depend on registered
-- occupancy alone. Note "prep -flatten" is required: without it "check" cannot
-- see a cycle that crosses module boundaries, and reports nothing.
--
-- THE FAILURE IS SILENT WITHOUT THIS
-- A reintroduced loop breaks no test and no formal property. GHDL settles the
-- loop and every program still passes, in both READ_REG modes; Vivado quietly
-- inserts false paths ("[Synth 8-326] inferred exception to break timing
-- loop") and carries on. This target is the only thing that says no.
--
-- Both buses are driven by the most aggressive legal slave: never stalling,
-- and acknowledging combinationally in the accept cycle. The read data is a
-- function of the address so that it cannot be optimised to a constant.

library ieee;
   use ieee.std_logic_1164.all;

entity zero_latency_loop is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      inst_done_o : out std_logic;
      halt_o      : out std_logic
   );
end entity zero_latency_loop;

architecture synthesis of zero_latency_loop is

   signal wbi_cyc   : std_logic;
   signal wbi_stb   : std_logic;
   signal wbi_stall : std_logic;
   signal wbi_ack   : std_logic;
   signal wbi_addr  : std_logic_vector(15 downto 0);
   signal wbi_data  : std_logic_vector(15 downto 0);

   signal wbd_cyc   : std_logic;
   signal wbd_stb   : std_logic;
   signal wbd_stall : std_logic;
   signal wbd_we    : std_logic;
   signal wbd_ack   : std_logic;
   signal wbd_addr  : std_logic_vector(15 downto 0);
   signal wbd_dat   : std_logic_vector(15 downto 0);
   signal wbd_data  : std_logic_vector(15 downto 0);

begin

   i_cpu : entity work.cpu
      generic map (
         G_REGISTER_BANK_WIDTH => 8
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         wbi_cyc_o   => wbi_cyc,
         wbi_stb_o   => wbi_stb,
         wbi_stall_i => wbi_stall,
         wbi_addr_o  => wbi_addr,
         wbi_ack_i   => wbi_ack,
         wbi_data_i  => wbi_data,
         wbd_cyc_o   => wbd_cyc,
         wbd_stb_o   => wbd_stb,
         wbd_stall_i => wbd_stall,
         wbd_addr_o  => wbd_addr,
         wbd_we_o    => wbd_we,
         wbd_dat_o   => wbd_dat,
         wbd_ack_i   => wbd_ack,
         wbd_data_i  => wbd_data,
         inst_done_o => inst_done_o,
         halt_o      => halt_o
      ); -- i_cpu

   wbi_stall <= '0';
   wbd_stall <= '0';
   wbi_ack   <= wbi_cyc and wbi_stb and not wbi_stall;
   wbd_ack   <= wbd_cyc and wbd_stb and not wbd_stall;
   wbi_data  <= not wbi_addr;
   wbd_data  <= not wbd_addr;

end architecture synthesis;
