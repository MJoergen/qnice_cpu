library ieee;
use ieee.std_logic_1164.all;

entity cpu is
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
      wbd_data_i  : in  std_logic_vector(15 downto 0)
   );
end entity cpu;

architecture synthesis of cpu is

   -- Fetch to pause
   signal fetch2pause_valid   : std_logic;
   signal fetch2pause_ready   : std_logic;
   signal fetch2pause_addr    : std_logic_vector(15 downto 0);
   signal fetch2pause_data    : std_logic_vector(15 downto 0);

   -- Pause to icache
   signal pause2seq_valid     : std_logic;
   signal pause2seq_ready     : std_logic;
   signal pause2seq_addr      : std_logic_vector(15 downto 0);
   signal pause2seq_data      : std_logic_vector(15 downto 0);

   -- Icache to decode
   signal seq2decode_valid    : std_logic;
   signal seq2decode_ready    : std_logic;
   signal seq2decode_double_valid  : std_logic;
   signal seq2decode_addr     : std_logic_vector(15 downto 0);
   signal seq2decode_data     : std_logic_vector(31 downto 0);
   signal seq2decode_double_consume  : std_logic;

   -- Decode to Register file
   signal dec2reg_src_reg     : std_logic_vector(3 downto 0);
   signal dec2reg_src_val     : std_logic_vector(15 downto 0);
   signal dec2reg_dst_reg     : std_logic_vector(3 downto 0);
   signal dec2reg_dst_val     : std_logic_vector(15 downto 0);
   signal reg2dec_r14         : std_logic_vector(15 downto 0);

   -- Decode to serializer
   signal decode2seq_valid      : std_logic;
   signal decode2seq_ready      : std_logic;
   signal decode2seq_microcodes : std_logic_vector(23 downto 0);
   signal decode2seq_addr       : std_logic_vector(15 downto 0);
   signal decode2seq_inst       : std_logic_vector(15 downto 0);
   signal decode2seq_immediate  : std_logic_vector(15 downto 0);
   signal decode2seq_src_addr   : std_logic_vector(3 downto 0);
   signal decode2seq_src_val    : std_logic_vector(15 downto 0);
   signal decode2seq_src_imm    : std_logic;
   signal decode2seq_dst_addr   : std_logic_vector(3 downto 0);
   signal decode2seq_dst_val    : std_logic_vector(15 downto 0);
   signal decode2seq_dst_imm    : std_logic;
   signal decode2seq_res_reg    : std_logic_vector(3 downto 0);
   signal decode2seq_r14        : std_logic_vector(15 downto 0);

   -- Serializer to execute
   signal seq2exe_valid       : std_logic;
   signal seq2exe_ready       : std_logic;
   signal seq2exe_microcodes  : std_logic_vector(7 downto 0);
   signal seq2exe_addr        : std_logic_vector(15 downto 0);
   signal seq2exe_inst        : std_logic_vector(15 downto 0);
   signal seq2exe_immediate   : std_logic_vector(15 downto 0);
   signal seq2exe_src_addr    : std_logic_vector(3 downto 0);
   signal seq2exe_src_val     : std_logic_vector(15 downto 0);
   signal seq2exe_src_imm     : std_logic;
   signal seq2exe_dst_addr    : std_logic_vector(3 downto 0);
   signal seq2exe_dst_val     : std_logic_vector(15 downto 0);
   signal seq2exe_dst_imm     : std_logic;
   signal seq2exe_res_reg     : std_logic_vector(3 downto 0);
   signal seq2exe_r14         : std_logic_vector(15 downto 0);

   -- Execute to memory
   signal exe2mem_req_valid   : std_logic;
   signal exe2mem_req_ready   : std_logic;
   signal exe2mem_req_op      : std_logic_vector(2 downto 0);
   signal exe2mem_req_addr    : std_logic_vector(15 downto 0);
   signal exe2mem_req_data    : std_logic_vector(15 downto 0);

   -- Memory to execute
   signal mem2exe_src_valid   : std_logic;
   signal mem2exe_src_ready   : std_logic;
   signal mem2exe_src_data    : std_logic_vector(15 downto 0);
   signal mem2exe_dst_valid   : std_logic;
   signal mem2exe_dst_ready   : std_logic;
   signal mem2exe_dst_data    : std_logic_vector(15 downto 0);

   -- Execute to registers
   signal exe2reg_r14_we      : std_logic;
   signal exe2reg_r14         : std_logic_vector(15 downto 0);
   signal exe2reg_we          : std_logic;
   signal exe2reg_addr        : std_logic_vector(3 downto 0);
   signal exe2reg_val         : std_logic_vector(15 downto 0);

   -- Execute to fetch
   signal exe2fetch_valid     : std_logic;
   signal exe2fetch_addr      : std_logic_vector(15 downto 0);

   signal icache_rst          : std_logic;

begin

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
         dc_valid_o => fetch2pause_valid,
         dc_ready_i => fetch2pause_ready,
         dc_addr_o  => fetch2pause_addr,
         dc_data_o  => fetch2pause_data,
         dc_valid_i => exe2fetch_valid,
         dc_addr_i  => exe2fetch_addr
      ); -- i_fetch


   i_axi_pause : entity work.axi_pause
      generic map (
         G_TDATA_SIZE => 32,
         G_PAUSE_SIZE => -8
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         s_tvalid_i => fetch2pause_valid,
         s_tready_o => fetch2pause_ready,
         s_tdata_i(31 downto 16)  => fetch2pause_addr,
         s_tdata_i(15 downto 0)   => fetch2pause_data,
         m_tvalid_o => pause2seq_valid,
         m_tready_i => pause2seq_ready,
         m_tdata_o(31 downto 16)  => pause2seq_addr,
         m_tdata_o(15 downto 0)   => pause2seq_data
      ); -- i_axi_pause


   i_icache : entity work.icache
      port map (
         clk_i           => clk_i,
         rst_i           => icache_rst,
         fetch_valid_i   => pause2seq_valid,
         fetch_ready_o   => pause2seq_ready,
         fetch_addr_i    => pause2seq_addr,
         fetch_data_i    => pause2seq_data,
         decode_valid_o  => seq2decode_valid,
         decode_ready_i  => seq2decode_ready,
         decode_double_o => seq2decode_double_valid,
         decode_addr_o   => seq2decode_addr,
         decode_data_o   => seq2decode_data,
         decode_double_i => seq2decode_double_consume
      ); -- i_icache

   icache_rst <= rst_i or exe2fetch_valid;


   i_decode : entity work.decode
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         fetch_valid_i    => seq2decode_valid,
         fetch_ready_o    => seq2decode_ready,
         fetch_double_i   => seq2decode_double_valid,
         fetch_addr_i     => seq2decode_addr,
         fetch_data_i     => seq2decode_data,
         fetch_double_o   => seq2decode_double_consume,
         reg_src_addr_o   => dec2reg_src_reg,
         reg_src_val_i    => dec2reg_src_val,
         reg_dst_addr_o   => dec2reg_dst_reg,
         reg_dst_val_i    => dec2reg_dst_val,
         reg_r14_i        => reg2dec_r14,
         exe_valid_o      => decode2seq_valid,
         exe_ready_i      => decode2seq_ready,
         exe_microcodes_o => decode2seq_microcodes,
         exe_addr_o       => decode2seq_addr,
         exe_inst_o       => decode2seq_inst,
         exe_immediate_o  => decode2seq_immediate,
         exe_src_addr_o   => decode2seq_src_addr,
         exe_src_val_o    => decode2seq_src_val,
         exe_src_imm_o    => decode2seq_src_imm,
         exe_dst_addr_o   => decode2seq_dst_addr,
         exe_dst_val_o    => decode2seq_dst_val,
         exe_dst_imm_o    => decode2seq_dst_imm,
         exe_res_reg_o    => decode2seq_res_reg,
         exe_r14_o        => decode2seq_r14
      ); -- i_decode


   i_serializer : entity work.serializer
      port map (
         clk_i               => clk_i,
         rst_i               => rst_i,
         decode_valid_i      => decode2seq_valid,
         decode_ready_o      => decode2seq_ready,
         decode_microcodes_i => decode2seq_microcodes,
         decode_addr_i       => decode2seq_addr,
         decode_inst_i       => decode2seq_inst,
         decode_immediate_i  => decode2seq_immediate,
         decode_src_addr_i   => decode2seq_src_addr,
         decode_src_val_i    => decode2seq_src_val,
         decode_src_imm_i    => decode2seq_src_imm,
         decode_dst_addr_i   => decode2seq_dst_addr,
         decode_dst_val_i    => decode2seq_dst_val,
         decode_dst_imm_i    => decode2seq_dst_imm,
         decode_res_reg_i    => decode2seq_res_reg,
         decode_r14_i        => decode2seq_r14,
         exe_valid_o         => seq2exe_valid,
         exe_ready_i         => seq2exe_ready,
         exe_microcodes_o    => seq2exe_microcodes,
         exe_addr_o          => seq2exe_addr,
         exe_inst_o          => seq2exe_inst,
         exe_immediate_o     => seq2exe_immediate,
         exe_src_addr_o      => seq2exe_src_addr,
         exe_src_val_o       => seq2exe_src_val,
         exe_src_imm_o       => seq2exe_src_imm,
         exe_dst_addr_o      => seq2exe_dst_addr,
         exe_dst_val_o       => seq2exe_dst_val,
         exe_dst_imm_o       => seq2exe_dst_imm,
         exe_res_reg_o       => seq2exe_res_reg,
         exe_r14_o           => seq2exe_r14
      ); -- i_serializer


   i_registers : entity work.registers
      port map (
         clk_i         => clk_i,
         rst_i         => rst_i,
         src_reg_i     => dec2reg_src_reg,
         src_val_o     => dec2reg_src_val,
         dst_reg_i     => dec2reg_dst_reg,
         dst_val_o     => dec2reg_dst_val,
         r14_o         => reg2dec_r14,
         r14_we_i      => exe2reg_r14_we,
         r14_i         => exe2reg_r14,
         reg_we_i      => exe2reg_we,
         reg_addr_i    => exe2reg_addr,
         reg_val_i     => exe2reg_val
      ); -- i_registers


   -- Writes to R15 are forwarded back to the fetch stage as well.
   exe2fetch_valid <= and(exe2reg_addr) and exe2reg_we;
   exe2fetch_addr  <= exe2reg_val;

   i_execute : entity work.execute
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         dec_valid_i      => seq2exe_valid,
         dec_ready_o      => seq2exe_ready,
         dec_microcodes_i => seq2exe_microcodes,
         dec_addr_i       => seq2exe_addr,
         dec_inst_i       => seq2exe_inst,
         dec_immediate_i  => seq2exe_immediate,
         dec_src_addr_i   => seq2exe_src_addr,
         dec_src_val_i    => seq2exe_src_val,
         dec_src_imm_i    => seq2exe_src_imm,
         dec_dst_addr_i   => seq2exe_dst_addr,
         dec_dst_val_i    => seq2exe_dst_val,
         dec_dst_imm_i    => seq2exe_dst_imm,
         dec_res_reg_i    => seq2exe_res_reg,
         dec_r14_i        => seq2exe_r14,
         mem_req_valid_o  => exe2mem_req_valid,
         mem_req_ready_i  => exe2mem_req_ready,
         mem_req_op_o     => exe2mem_req_op,
         mem_req_addr_o   => exe2mem_req_addr,
         mem_req_data_o   => exe2mem_req_data,
         mem_src_valid_i  => mem2exe_src_valid,
         mem_src_ready_o  => mem2exe_src_ready,
         mem_src_data_i   => mem2exe_src_data,
         mem_dst_valid_i  => mem2exe_dst_valid,
         mem_dst_ready_o  => mem2exe_dst_ready,
         mem_dst_data_i   => mem2exe_dst_data,
         reg_r14_we_o     => exe2reg_r14_we,
         reg_r14_o        => exe2reg_r14,
         reg_we_o         => exe2reg_we,
         reg_addr_o       => exe2reg_addr,
         reg_val_o        => exe2reg_val
      ); -- i_execute


   i_memory : entity work.memory
      port map (
         clk_i           => clk_i,
         rst_i           => rst_i,
         mreq_valid_i    => exe2mem_req_valid,
         mreq_ready_o    => exe2mem_req_ready,
         mreq_op_i       => exe2mem_req_op,
         mreq_addr_i     => exe2mem_req_addr,
         mreq_data_i     => exe2mem_req_data,
         msrc_valid_o    => mem2exe_src_valid,
         msrc_ready_i    => mem2exe_src_ready,
         msrc_data_o     => mem2exe_src_data,
         mdst_valid_o    => mem2exe_dst_valid,
         mdst_ready_i    => mem2exe_dst_ready,
         mdst_data_o     => mem2exe_dst_data,
         wb_cyc_o        => wbd_cyc_o,
         wb_stb_o        => wbd_stb_o,
         wb_stall_i      => wbd_stall_i,
         wb_addr_o       => wbd_addr_o,
         wb_we_o         => wbd_we_o,
         wb_dat_o        => wbd_dat_o,
         wb_ack_i        => wbd_ack_i,
         wb_data_i       => wbd_data_i
      ); -- i_memory

   p_debug : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if not rst_i and exe2reg_we then
            report "Write value 0x" & to_hstring(exe2reg_val) & " to register " & to_hstring(exe2reg_addr);
         end if;

         if not rst_i and wbd_stb_o and wbd_we_o and not wbd_stall_i then
            report "Write value 0x" & to_hstring(wbd_dat_o) & " to memory 0x" & to_hstring(wbd_addr_o);
         end if;
      end if;
   end process p_debug;

end architecture synthesis;


