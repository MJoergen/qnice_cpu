library ieee;
use ieee.std_logic_1164.all;

entity decode_serialized is
   port (
      clk_i            : in  std_logic;
      rst_i            : in  std_logic;

      -- From Instruction fetch
      fetch_valid_i    : in  std_logic;
      fetch_ready_o    : out std_logic;                     -- combinatorial
      fetch_double_i   : in  std_logic;
      fetch_addr_i     : in  std_logic_vector(15 downto 0);
      fetch_data_i     : in  std_logic_vector(31 downto 0);
      fetch_double_o   : out std_logic;                     -- combinatorial

      -- Register file. Value arrives on the next clock cycle
      reg_rd_en_o      : out std_logic;
      reg_src_addr_o   : out std_logic_vector(3 downto 0);  -- combinatorial
      reg_dst_addr_o   : out std_logic_vector(3 downto 0);  -- combinatorial
      reg_src_val_i    : in  std_logic_vector(15 downto 0);
      reg_dst_val_i    : in  std_logic_vector(15 downto 0);
      reg_r14_i        : in  std_logic_vector(15 downto 0);

      -- To Execute stage
      exe_valid_o      : out std_logic;
      exe_ready_i      : in  std_logic;
      exe_microcodes_o : out std_logic_vector(11 downto 0);
      exe_addr_o       : out std_logic_vector(15 downto 0);
      exe_inst_o       : out std_logic_vector(15 downto 0);
      exe_immediate_o  : out std_logic_vector(15 downto 0);
      exe_src_addr_o   : out std_logic_vector(3 downto 0);
      exe_src_mode_o   : out std_logic_vector(1 downto 0);
      exe_src_val_o    : out std_logic_vector(15 downto 0);
      exe_src_imm_o    : out std_logic;
      exe_dst_addr_o   : out std_logic_vector(3 downto 0);
      exe_dst_mode_o   : out std_logic_vector(1 downto 0);
      exe_dst_val_o    : out std_logic_vector(15 downto 0);
      exe_dst_imm_o    : out std_logic;
      exe_res_reg_o    : out std_logic_vector(3 downto 0);
      exe_r14_o        : out std_logic_vector(15 downto 0)
   );
end entity decode_serialized;

architecture synthesis of decode_serialized is

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

begin

   i_decode : entity work.decode
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         fetch_valid_i    => fetch_valid_i,
         fetch_ready_o    => fetch_ready_o,
         fetch_double_i   => fetch_double_i,
         fetch_addr_i     => fetch_addr_i,
         fetch_data_i     => fetch_data_i,
         fetch_double_o   => fetch_double_o,
         reg_rd_en_o      => reg_rd_en_o,
         reg_src_addr_o   => reg_src_addr_o,
         reg_src_val_i    => reg_src_val_i,
         reg_dst_addr_o   => reg_dst_addr_o,
         reg_dst_val_i    => reg_dst_val_i,
         reg_r14_i        => reg_r14_i,
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
         m_valid_o => exe_valid_o,
         m_ready_i => exe_ready_i,
         m_data_o  => exe_microcodes_o,
         m_user_o(R_SER_ADDR)      => exe_addr_o,
         m_user_o(R_SER_INST)      => exe_inst_o,
         m_user_o(R_SER_IMMEDIATE) => exe_immediate_o,
         m_user_o(R_SER_SRC_ADDR)  => exe_src_addr_o,
         m_user_o(R_SER_SRC_MODE)  => exe_src_mode_o,
         m_user_o(R_SER_SRC_VAL)   => exe_src_val_o,
         m_user_o(R_SER_SRC_IMM)   => exe_src_imm_o,
         m_user_o(R_SER_DST_ADDR)  => exe_dst_addr_o,
         m_user_o(R_SER_DST_MODE)  => exe_dst_mode_o,
         m_user_o(R_SER_DST_VAL)   => exe_dst_val_o,
         m_user_o(R_SER_DST_IMM)   => exe_dst_imm_o,
         m_user_o(R_SER_RES_REG)   => exe_res_reg_o,
         m_user_o(R_SER_R14)       => exe_r14_o
      ); -- i_serializer

end architecture synthesis;

