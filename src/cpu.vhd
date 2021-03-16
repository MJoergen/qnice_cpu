library ieee;
use ieee.std_logic_1164.all;

entity cpu is
   generic (
      G_REGISTER_BANK_WIDTH : integer
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
      wbd_data_i  : in  std_logic_vector(15 downto 0)
   );
end entity cpu;

architecture synthesis of cpu is

   -- From FETCH to DECODE
   signal fetch2decode_valid          : std_logic;
   signal fetch2decode_ready          : std_logic;
   signal fetch2decode_double_valid   : std_logic;
   signal fetch2decode_addr           : std_logic_vector(15 downto 0);
   signal fetch2decode_data           : std_logic_vector(31 downto 0);
   signal fetch2decode_double_consume : std_logic;

   -- Decode to Register file
   signal dec2reg_src_reg     : std_logic_vector(3 downto 0);
   signal dec2reg_src_val     : std_logic_vector(15 downto 0);
   signal dec2reg_dst_reg     : std_logic_vector(3 downto 0);
   signal dec2reg_dst_val     : std_logic_vector(15 downto 0);
   signal reg2dec_r14         : std_logic_vector(15 downto 0);

   subtype R_SER_ADDR      is natural range  15 downto 0;
   subtype R_SER_INST      is natural range  31 downto 16;
   subtype R_SER_IMMEDIATE is natural range  47 downto 32;
   subtype R_SER_SRC_ADDR  is natural range  51 downto 48;
   subtype R_SER_SRC_MODE  is natural range  53 downto 52;
   subtype R_SER_SRC_VAL   is natural range  69 downto 54;
   constant R_SER_SRC_IMM  : integer := 70;
   subtype R_SER_DST_ADDR  is natural range  74 downto 71;
   subtype R_SER_DST_MODE  is natural range  76 downto 75;
   subtype R_SER_DST_VAL   is natural range  92 downto 77;
   constant R_SER_DST_IMM  : integer := 93;
   subtype R_SER_RES_REG   is natural range  97 downto 94;
   subtype R_SER_R14       is natural range 113 downto 98;
   constant C_SERIALIZER_SIZE : integer := 114;

   -- Decode to serializer
   signal decode2seq_valid      : std_logic;
   signal decode2seq_ready      : std_logic;
   signal decode2seq_microcodes : std_logic_vector(35 downto 0);
   signal decode2seq_user       : std_logic_vector(C_SERIALIZER_SIZE-1 downto 0);

   -- Serializer to execute
   signal seq2exe_valid       : std_logic;
   signal seq2exe_ready       : std_logic;
   signal seq2exe_microcodes  : std_logic_vector(11 downto 0);
   signal seq2exe_user        : std_logic_vector(C_SERIALIZER_SIZE-1 downto 0);

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

   i_fetch_cache : entity work.fetch_cache
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         s_valid_i   => exe2fetch_valid,
         s_addr_i    => exe2fetch_addr,
         wbi_cyc_o   => wbi_cyc_o,
         wbi_stb_o   => wbi_stb_o,
         wbi_stall_i => wbi_stall_i,
         wbi_addr_o  => wbi_addr_o,
         wbi_ack_i   => wbi_ack_i,
         wbi_data_i  => wbi_data_i,
         m_valid_o   => fetch2decode_valid,
         m_ready_i   => fetch2decode_ready,
         m_double_o  => fetch2decode_double_valid,
         m_addr_o    => fetch2decode_addr,
         m_data_o    => fetch2decode_data,
         m_double_i  => fetch2decode_double_consume
      ); -- i_fetch_cache


   i_decode : entity work.decode
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         fetch_valid_i    => fetch2decode_valid,
         fetch_ready_o    => fetch2decode_ready,
         fetch_double_i   => fetch2decode_double_valid,
         fetch_addr_i     => fetch2decode_addr,
         fetch_data_i     => fetch2decode_data,
         fetch_double_o   => fetch2decode_double_consume,
         reg_src_addr_o   => dec2reg_src_reg,
         reg_src_val_i    => dec2reg_src_val,
         reg_dst_addr_o   => dec2reg_dst_reg,
         reg_dst_val_i    => dec2reg_dst_val,
         reg_r14_i        => reg2dec_r14,
         exe_valid_o      => decode2seq_valid,
         exe_ready_i      => decode2seq_ready,
         exe_microcodes_o => decode2seq_microcodes,
         exe_addr_o       => decode2seq_user(R_SER_ADDR),
         exe_inst_o       => decode2seq_user(R_SER_INST),
         exe_immediate_o  => decode2seq_user(R_SER_IMMEDIATE),
         exe_src_addr_o   => decode2seq_user(R_SER_SRC_ADDR),
         exe_src_mode_o   => decode2seq_user(R_SER_SRC_MODE),
         exe_src_val_o    => decode2seq_user(R_SER_SRC_VAL),
         exe_src_imm_o    => decode2seq_user(R_SER_SRC_IMM),
         exe_dst_addr_o   => decode2seq_user(R_SER_DST_ADDR),
         exe_dst_mode_o   => decode2seq_user(R_SER_DST_MODE),
         exe_dst_val_o    => decode2seq_user(R_SER_DST_VAL),
         exe_dst_imm_o    => decode2seq_user(R_SER_DST_IMM),
         exe_res_reg_o    => decode2seq_user(R_SER_RES_REG),
         exe_r14_o        => decode2seq_user(R_SER_R14)
      ); -- i_decode


   i_serializer : entity work.serializer
      generic map (
         G_DATA_SIZE => 12,
         G_USER_SIZE => C_SERIALIZER_SIZE
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         s_valid_i => decode2seq_valid,
         s_ready_o => decode2seq_ready,
         s_data_i  => decode2seq_microcodes,
         s_user_i  => decode2seq_user,
         m_valid_o => seq2exe_valid,
         m_ready_i => seq2exe_ready,
         m_data_o  => seq2exe_microcodes,
         m_user_o  => seq2exe_user
      ); -- i_serializer


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
         dec_addr_i       => seq2exe_user(R_SER_ADDR),
         dec_inst_i       => seq2exe_user(R_SER_INST),
         dec_immediate_i  => seq2exe_user(R_SER_IMMEDIATE),
         dec_src_addr_i   => seq2exe_user(R_SER_SRC_ADDR),
         dec_src_mode_i   => seq2exe_user(R_SER_SRC_MODE),
         dec_src_val_i    => seq2exe_user(R_SER_SRC_VAL),
         dec_src_imm_i    => seq2exe_user(R_SER_SRC_IMM),
         dec_dst_addr_i   => seq2exe_user(R_SER_DST_ADDR),
         dec_dst_mode_i   => seq2exe_user(R_SER_DST_MODE),
         dec_dst_val_i    => seq2exe_user(R_SER_DST_VAL),
         dec_dst_imm_i    => seq2exe_user(R_SER_DST_IMM),
         dec_res_reg_i    => seq2exe_user(R_SER_RES_REG),
         dec_r14_i        => seq2exe_user(R_SER_R14),
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


   i_registers : entity work.registers
      generic map (
         G_REGISTER_BANK_WIDTH => G_REGISTER_BANK_WIDTH
      )
      port map (
         clk_i         => clk_i,
         rst_i         => rst_i,
         src_reg_i     => dec2reg_src_reg,
         src_val_o     => dec2reg_src_val,
         dst_reg_i     => dec2reg_dst_reg,
         dst_val_o     => dec2reg_dst_val,
         r14_o         => reg2dec_r14,
         wr_r14_en_i   => exe2reg_r14_we,
         wr_r14_i      => exe2reg_r14,
         wr_en_i       => exe2reg_we,
         wr_addr_i     => exe2reg_addr,
         wr_val_i      => exe2reg_val
      ); -- i_registers


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


