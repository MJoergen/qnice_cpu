library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.cpu_constants.all;

entity cpu is
   generic (
      G_REGISTER_BANK_WIDTH : integer;
      -- Simulation only: file to log every register and memory write to.
      -- An empty string (the default) disables the logging entirely.
      G_WRITES_FILE         : string := ""
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;

      -- Instruction Memory
      wbi_cyc_o   : out std_logic;
      wbi_stb_o   : out std_logic;
      wbi_stall_i : in  std_logic;
      wbi_addr_o  : out std_logic_vector(15 downto 0);
      wbi_ack_i   : in  std_logic;
      wbi_data_i  : in  std_logic_vector(15 downto 0);

      -- Data Memory
      wbd_cyc_o   : out std_logic;
      wbd_stb_o   : out std_logic;
      wbd_stall_i : in  std_logic;
      wbd_addr_o  : out std_logic_vector(15 downto 0);
      wbd_we_o    : out std_logic;
      wbd_dat_o   : out std_logic_vector(15 downto 0);
      wbd_ack_i   : in  std_logic;
      wbd_data_i  : in  std_logic_vector(15 downto 0);

      -- Asserted from the moment a HALT instruction retires until the next reset
      halt_o      : out std_logic
   );
end entity cpu;

architecture synthesis of cpu is

   -- FETCH to ICACHE
   signal fetch2icache_valid : std_logic;
   signal fetch2icache_ready : std_logic;
   signal fetch2icache_addr  : std_logic_vector(15 downto 0);
   signal fetch2icache_data  : std_logic_vector(15 downto 0);

   -- Halt
   signal halt         : std_logic;
   signal halt_d       : std_logic := '0';
   signal halt_fetched : std_logic := '0';

   -- ICACHE to DECODE
   signal icache_rst                   : std_logic;
   signal icache2decode_valid          : std_logic;
   signal icache2decode_ready          : std_logic;
   signal icache2decode_double_valid   : std_logic;
   signal icache2decode_addr           : std_logic_vector(15 downto 0);
   signal icache2decode_data           : std_logic_vector(31 downto 0);
   signal icache2decode_double_consume : std_logic;

   -- Same three signals, gated off once a HALT has been fetched (p_halt_fetched)
   signal icache2decode_valid_gated          : std_logic;
   signal icache2decode_ready_gated          : std_logic;
   signal icache2decode_double_consume_gated : std_logic;

   -- WRITE to FETCH (branches: the new PC, which also flushes the pipeline)
   signal wr2fetch_valid : std_logic;
   signal wr2fetch_addr  : std_logic_vector(15 downto 0);

   -- DECODE read from register file
   signal decode2reg_rd_en   : std_logic;
   signal decode2reg_src_reg : std_logic_vector(3 downto 0);
   signal decode2reg_src_val : std_logic_vector(15 downto 0);
   signal decode2reg_dst_reg : std_logic_vector(3 downto 0);
   signal decode2reg_dst_val : std_logic_vector(15 downto 0);
   signal reg2decode_r14     : std_logic_vector(15 downto 0);

   -- WRITE to register file
   signal wr2reg_r14_we : std_logic;
   signal wr2reg_r14    : std_logic_vector(15 downto 0);
   signal wr2reg_we     : std_logic;
   signal wr2reg_addr   : std_logic_vector(3 downto 0);
   signal wr2reg_val    : std_logic_vector(15 downto 0);

   -- WRITE request to memory
   signal wr2mem_req_valid : std_logic;
   signal wr2mem_req_ready : std_logic;
   signal wr2mem_req_op    : std_logic_vector(2 downto 0);
   signal wr2mem_req_addr  : std_logic_vector(15 downto 0);
   signal wr2mem_req_data  : std_logic_vector(15 downto 0);

   -- Memory response back to PREPARE
   signal mem2prep_src_valid : std_logic;
   signal mem2prep_src_ready : std_logic;
   signal mem2prep_src_data  : std_logic_vector(15 downto 0);
   signal mem2prep_dst_valid : std_logic;
   signal mem2prep_dst_ready : std_logic;
   signal mem2prep_dst_data  : std_logic_vector(15 downto 0);

begin

   ------------------------------------------------------------
   -- Instruction FETCH
   ------------------------------------------------------------

   i_fetch : entity work.fetch
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         wb_cyc_o   => wbi_cyc_o,
         wb_stb_o   => wbi_stb_o,
         wb_stall_i => wbi_stall_i,
         wb_addr_o  => wbi_addr_o,
         wb_ack_i   => wbi_ack_i,
         wb_data_i  => wbi_data_i,
         dc_valid_o => fetch2icache_valid,
         dc_ready_i => fetch2icache_ready,
         dc_addr_o  => fetch2icache_addr,
         dc_data_o  => fetch2icache_data,
         dc_valid_i => wr2fetch_valid,
         dc_addr_i  => wr2fetch_addr
      ); -- i_fetch


   ------------------------------------------------------------
   -- Instruction ICACHE
   ------------------------------------------------------------

   icache_rst <= rst_i or wr2fetch_valid;

   i_icache : entity work.icache
      generic map (
         G_ADDR_SIZE => 16,
         G_DATA_SIZE => 16
      )
      port map (
         clk_i      => clk_i,
         rst_i      => icache_rst,
         s_valid_i  => fetch2icache_valid,
         s_ready_o  => fetch2icache_ready,
         s_addr_i   => fetch2icache_addr,
         s_data_i   => fetch2icache_data,
         m_valid_o  => icache2decode_valid,
         m_ready_i  => icache2decode_ready_gated,
         m_double_o => icache2decode_double_valid,
         m_addr_o   => icache2decode_addr,
         m_data_o   => icache2decode_data,
         m_double_i => icache2decode_double_consume_gated
      ); -- i_icache


   -- HALT stops the pipeline. The gate is placed here, on the handshake that
   -- hands instructions to DECODE, rather than on the HALT retiring three
   -- stages later: by then the next one or two instructions have already been
   -- accepted, and would retire after the HALT, executing whatever data happens
   -- to follow it in memory. Gating here means the HALT is the last instruction
   -- that ever enters the pipeline, so it is also the last one to retire.
   --
   -- Both directions of the handshake are gated by the same signal, so the
   -- Icache and DECODE always agree on whether a beat was accepted. Only a
   -- reset restarts execution.
   icache2decode_valid_gated          <= icache2decode_valid          and not halt_fetched;
   icache2decode_ready_gated          <= icache2decode_ready          and not halt_fetched;
   icache2decode_double_consume_gated <= icache2decode_double_consume and not halt_fetched;

   -- NOTE: the set condition deliberately uses the UNGATED valid and ready,
   -- even though the handshake it is detecting is the gated one. The two agree
   -- whenever halt_fetched is still '0', which is the only case that matters,
   -- and once it is '1' the ungated condition can do no more than set an
   -- already-set flag. Using the gated signals instead would put halt_fetched
   -- in its own D-input cone (halt_fetched -> gate -> set condition), costing a
   -- level of logic and tying this register's placement to the gating LUTs.
   p_halt_fetched : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if icache2decode_valid = '1' and icache2decode_ready = '1' and
            icache2decode_data(R_OPCODE) = C_OPCODE_CTRL and
            icache2decode_data(R_CTRL_CMD) = C_CTRL_HALT then
            halt_fetched <= '1';
         end if;

         -- A HALT that DECODE has accepted is not necessarily a HALT that will
         -- execute: an older branch still in the pipeline flushes DECODE and
         -- PREPARE when it retires (see the reset of i_decode and i_prepare in
         -- cpu_main.vhd), discarding it. prog_pipeline.asm does exactly this --
         -- it branches over twelve HALTs used as padding. Without this clear the
         -- CPU would gate itself off forever on a HALT that never ran.
         if wr2fetch_valid = '1' or rst_i = '1' then
            halt_fetched <= '0';
         end if;
      end if;
   end process p_halt_fetched;


   ------------------------------------------------------------
   -- CPU MAIN
   ------------------------------------------------------------

   i_cpu_main : entity work.cpu_main
      port map (
         clk_i           => clk_i,
         rst_i           => rst_i,
         fetch_valid_i   => icache2decode_valid_gated,
         fetch_ready_o   => icache2decode_ready,
         fetch_double_i  => icache2decode_double_valid,
         fetch_addr_i    => icache2decode_addr,
         fetch_data_i    => icache2decode_data,
         fetch_double_o  => icache2decode_double_consume,
         reg_rd_en_o     => decode2reg_rd_en,
         reg_src_reg_o   => decode2reg_src_reg,
         reg_src_val_i   => decode2reg_src_val,
         reg_dst_reg_o   => decode2reg_dst_reg,
         reg_dst_val_i   => decode2reg_dst_val,
         reg_r14_i       => reg2decode_r14,
         mem_req_valid_o => wr2mem_req_valid,
         mem_req_ready_i => wr2mem_req_ready,
         mem_req_op_o    => wr2mem_req_op,
         mem_req_addr_o  => wr2mem_req_addr,
         mem_req_data_o  => wr2mem_req_data,
         mem_src_valid_i => mem2prep_src_valid,
         mem_src_ready_o => mem2prep_src_ready,
         mem_src_data_i  => mem2prep_src_data,
         mem_dst_valid_i => mem2prep_dst_valid,
         mem_dst_ready_o => mem2prep_dst_ready,
         mem_dst_data_i  => mem2prep_dst_data,
         fetch_valid_o   => wr2fetch_valid,
         fetch_addr_o    => wr2fetch_addr,
         reg_r14_we_o    => wr2reg_r14_we,
         reg_r14_o       => wr2reg_r14,
         reg_we_o        => wr2reg_we,
         reg_addr_o      => wr2reg_addr,
         reg_val_o       => wr2reg_val,
         halt_o          => halt
      ); -- i_cpu_main


   ------------------------------------------------------------
   -- Halt
   ------------------------------------------------------------

   -- halt_o is the level "this CPU has executed a HALT", as opposed to the
   -- single-cycle pulse cpu_main reports when the HALT retires.
   p_halt : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if halt = '1' then
            halt_d <= '1';
         end if;
         if rst_i = '1' then
            halt_d <= '0';
         end if;
      end if;
   end process p_halt;

   halt_o <= halt or halt_d;


   ------------------------------------------------------------
   -- Register file
   ------------------------------------------------------------

   i_registers : entity work.registers
      generic map (
         G_REGISTER_BANK_WIDTH => G_REGISTER_BANK_WIDTH
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         rd_en_i     => decode2reg_rd_en,
         src_reg_i   => decode2reg_src_reg,
         src_val_o   => decode2reg_src_val,
         dst_reg_i   => decode2reg_dst_reg,
         dst_val_o   => decode2reg_dst_val,
         wr_en_i     => wr2reg_we,
         wr_reg_i    => wr2reg_addr,
         wr_val_i    => wr2reg_val,
         sr_val_o    => reg2decode_r14,
         wr_sr_en_i  => wr2reg_r14_we,
         wr_sr_val_i => wr2reg_r14
      ); -- i_registers


   ------------------------------------------------------------
   -- Memory interface
   ------------------------------------------------------------

   i_memory : entity work.memory
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         mreq_valid_i => wr2mem_req_valid,
         mreq_ready_o => wr2mem_req_ready,
         mreq_op_i    => wr2mem_req_op,
         mreq_addr_i  => wr2mem_req_addr,
         mreq_data_i  => wr2mem_req_data,
         msrc_valid_o => mem2prep_src_valid,
         msrc_ready_i => mem2prep_src_ready,
         msrc_data_o  => mem2prep_src_data,
         mdst_valid_o => mem2prep_dst_valid,
         mdst_ready_i => mem2prep_dst_ready,
         mdst_data_o  => mem2prep_dst_data,
         wb_cyc_o     => wbd_cyc_o,
         wb_stb_o     => wbd_stb_o,
         wb_stall_i   => wbd_stall_i,
         wb_addr_o    => wbd_addr_o,
         wb_we_o      => wbd_we_o,
         wb_dat_o     => wbd_dat_o,
         wb_ack_i     => wbd_ack_i,
         wb_data_i    => wbd_data_i
      ); -- i_memory


-- pragma synthesis_off
   i_debug : entity work.debug
      generic map (
         G_FILE_NAME => G_WRITES_FILE
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         reg_we_i   => wr2reg_we,
         reg_addr_i => wr2reg_addr,
         reg_data_i => wr2reg_val,
         mem_we_i   => std_logic(wbd_stb_o and wbd_we_o and not wbd_stall_i),
         mem_addr_i => wbd_addr_o,
         mem_data_i => wbd_dat_o
      ); -- i_debug
-- pragma synthesis_on

end architecture synthesis;

