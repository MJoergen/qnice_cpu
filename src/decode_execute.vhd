library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity decode_execute is
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

      -- EXECUTE to FETCH
      fetch_valid_o    : out std_logic;
      fetch_addr_o     : out std_logic_vector(15 downto 0);

      -- DECODE to registerfile
      reg_rd_en_o      : out std_logic;
      reg_src_reg_o    : out std_logic_vector(3 downto 0);
      reg_src_val_i    : in  std_logic_vector(15 downto 0);
      reg_dst_reg_o    : out std_logic_vector(3 downto 0);
      reg_dst_val_i    : in  std_logic_vector(15 downto 0);
      reg_r14_i        : in  std_logic_vector(15 downto 0);

      -- EXECUTE to memory
      mem_req_valid_o  : out std_logic;
      mem_req_ready_i  : in  std_logic;
      mem_req_op_o     : out std_logic_vector(2 downto 0);
      mem_req_addr_o   : out std_logic_vector(15 downto 0);
      mem_req_data_o   : out std_logic_vector(15 downto 0);

      -- Memory to EXECUTE
      mem_src_valid_i  : in  std_logic;
      mem_src_ready_o  : out std_logic;
      mem_src_data_i   : in  std_logic_vector(15 downto 0);
      mem_dst_valid_i  : in  std_logic;
      mem_dst_ready_o  : out std_logic;
      mem_dst_data_i   : in  std_logic_vector(15 downto 0);

      -- EXECUTE to registers
      reg_r14_we_o     : out std_logic;
      reg_r14_o        : out std_logic_vector(15 downto 0);
      reg_we_o         : out std_logic;
      reg_addr_o       : out std_logic_vector(3 downto 0);
      reg_val_o        : out std_logic_vector(15 downto 0)
   );
end entity decode_execute;

architecture synthesis of decode_execute is

   -- DECODE to EXECUTE
   signal decode2exe_valid      : std_logic;
   signal decode2exe_ready      : std_logic;
   signal decode2exe_microcodes : std_logic_vector(11 downto 0);
   signal decode2exe_addr       : std_logic_vector(15 downto 0);
   signal decode2exe_inst       : std_logic_vector(15 downto 0);
   signal decode2exe_immediate  : std_logic_vector(15 downto 0);
   signal decode2exe_src_addr   : std_logic_vector(3 downto 0);
   signal decode2exe_src_mode   : std_logic_vector(1 downto 0);
   signal decode2exe_src_val    : std_logic_vector(15 downto 0);
   signal decode2exe_src_imm    : std_logic;
   signal decode2exe_dst_addr   : std_logic_vector(3 downto 0);
   signal decode2exe_dst_mode   : std_logic_vector(1 downto 0);
   signal decode2exe_dst_val    : std_logic_vector(15 downto 0);
   signal decode2exe_dst_imm    : std_logic;
   signal decode2exe_res_reg    : std_logic_vector(3 downto 0);
   signal decode2exe_r14        : std_logic_vector(15 downto 0);

begin

   ------------------------------------------------------------
   -- Instruction DECODE
   ------------------------------------------------------------

   i_decode_serialized : entity work.decode_serialized
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
         reg_src_addr_o   => reg_src_reg_o,
         reg_src_val_i    => reg_src_val_i,
         reg_dst_addr_o   => reg_dst_reg_o,
         reg_dst_val_i    => reg_dst_val_i,
         reg_r14_i        => reg_r14_i,
         exe_valid_o      => decode2exe_valid,
         exe_ready_i      => decode2exe_ready,
         exe_microcodes_o => decode2exe_microcodes,
         exe_addr_o       => decode2exe_addr,
         exe_inst_o       => decode2exe_inst,
         exe_immediate_o  => decode2exe_immediate,
         exe_src_addr_o   => decode2exe_src_addr,
         exe_src_mode_o   => decode2exe_src_mode,
         exe_src_val_o    => decode2exe_src_val,
         exe_src_imm_o    => decode2exe_src_imm,
         exe_dst_addr_o   => decode2exe_dst_addr,
         exe_dst_mode_o   => decode2exe_dst_mode,
         exe_dst_val_o    => decode2exe_dst_val,
         exe_dst_imm_o    => decode2exe_dst_imm,
         exe_res_reg_o    => decode2exe_res_reg,
         exe_r14_o        => decode2exe_r14
      ); -- i_decode_serialized


   ------------------------------------------------------------
   -- Instruction EXECUTE
   ------------------------------------------------------------

   i_execute : entity work.execute
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         dec_valid_i      => decode2exe_valid,
         dec_ready_o      => decode2exe_ready,
         dec_microcodes_i => decode2exe_microcodes,
         dec_addr_i       => decode2exe_addr,
         dec_inst_i       => decode2exe_inst,
         dec_immediate_i  => decode2exe_immediate,
         dec_src_addr_i   => decode2exe_src_addr,
         dec_src_mode_i   => decode2exe_src_mode,
         dec_src_val_i    => decode2exe_src_val,
         dec_src_imm_i    => decode2exe_src_imm,
         dec_dst_addr_i   => decode2exe_dst_addr,
         dec_dst_mode_i   => decode2exe_dst_mode,
         dec_dst_val_i    => decode2exe_dst_val,
         dec_dst_imm_i    => decode2exe_dst_imm,
         dec_res_reg_i    => decode2exe_res_reg,
         dec_r14_i        => decode2exe_r14,
         mem_req_valid_o  => mem_req_valid_o,
         mem_req_ready_i  => mem_req_ready_i,
         mem_req_op_o     => mem_req_op_o,
         mem_req_addr_o   => mem_req_addr_o,
         mem_req_data_o   => mem_req_data_o,
         mem_src_valid_i  => mem_src_valid_i,
         mem_src_ready_o  => mem_src_ready_o,
         mem_src_data_i   => mem_src_data_i,
         mem_dst_valid_i  => mem_dst_valid_i,
         mem_dst_ready_o  => mem_dst_ready_o,
         mem_dst_data_i   => mem_dst_data_i,
         fetch_valid_o    => fetch_valid_o,
         fetch_addr_o     => fetch_addr_o,
         reg_r14_we_o     => reg_r14_we_o,
         reg_r14_o        => reg_r14_o,
         reg_we_o         => reg_we_o,
         reg_addr_o       => reg_addr_o,
         reg_val_o        => reg_val_o
      ); -- i_execute

end architecture synthesis;

