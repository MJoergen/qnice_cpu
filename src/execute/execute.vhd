library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.cpu_constants.all;

entity execute is
   port (
      clk_i            : in  std_logic;
      rst_i            : in  std_logic;

      -- From decode
      dec_valid_i      : in  std_logic;
      dec_ready_o      : out std_logic;
      dec_microcodes_i : in  std_logic_vector(11 downto 0);
      dec_addr_i       : in  std_logic_vector(15 downto 0);
      dec_inst_i       : in  std_logic_vector(15 downto 0);
      dec_immediate_i  : in  std_logic_vector(15 downto 0);
      dec_src_addr_i   : in  std_logic_vector(3 downto 0);
      dec_src_mode_i   : in  std_logic_vector(1 downto 0);
      dec_src_val_i    : in  std_logic_vector(15 downto 0);
      dec_src_imm_i    : in  std_logic;
      dec_dst_addr_i   : in  std_logic_vector(3 downto 0);
      dec_dst_mode_i   : in  std_logic_vector(1 downto 0);
      dec_dst_val_i    : in  std_logic_vector(15 downto 0);
      dec_dst_imm_i    : in  std_logic;
      dec_res_reg_i    : in  std_logic_vector(3 downto 0);
      dec_r14_i        : in  std_logic_vector(15 downto 0);

      -- Memory
      mem_req_valid_o  : out std_logic;                        -- combinatorial
      mem_req_ready_i  : in  std_logic;
      mem_req_op_o     : out std_logic_vector(2 downto 0);     -- combinatorial
      mem_req_addr_o   : out std_logic_vector(15 downto 0);    -- combinatorial
      mem_req_data_o   : out std_logic_vector(15 downto 0);    -- combinatorial

      mem_src_valid_i  : in  std_logic;
      mem_src_ready_o  : out std_logic;                        -- combinatorial
      mem_src_data_i   : in  std_logic_vector(15 downto 0);
      mem_dst_valid_i  : in  std_logic;
      mem_dst_ready_o  : out std_logic;                        -- combinatorial
      mem_dst_data_i   : in  std_logic_vector(15 downto 0);

      -- Register file
      reg_r14_we_o     : out std_logic;
      reg_r14_o        : out std_logic_vector(15 downto 0);
      reg_we_o         : out std_logic;
      reg_addr_o       : out std_logic_vector(3 downto 0);
      reg_val_o        : out std_logic_vector(15 downto 0);
      fetch_valid_o    : out std_logic;
      fetch_addr_o     : out std_logic_vector(15 downto 0);

      inst_done_o      : out std_logic
   );
end entity execute;

architecture synthesis of execute is

   signal prep_valid      : std_logic;
   signal prep_ready      : std_logic;
   signal prep_microcodes : std_logic_vector(11 downto 0);
   signal prep_addr       : std_logic_vector(15 downto 0);
   signal prep_inst       : std_logic_vector(15 downto 0);
   signal prep_immediate  : std_logic_vector(15 downto 0);
   signal prep_src_addr   : std_logic_vector(3 downto 0);
   signal prep_src_mode   : std_logic_vector(1 downto 0);
   signal prep_src_val    : std_logic_vector(15 downto 0);
   signal prep_src_imm    : std_logic;
   signal prep_dst_addr   : std_logic_vector(3 downto 0);
   signal prep_dst_mode   : std_logic_vector(1 downto 0);
   signal prep_dst_val    : std_logic_vector(15 downto 0);
   signal prep_dst_imm    : std_logic;
   signal prep_res_reg    : std_logic_vector(3 downto 0);
   signal prep_r14        : std_logic_vector(15 downto 0);
   signal alu_oper        : std_logic_vector(3 downto 0);
   signal alu_ctrl        : std_logic_vector(5 downto 0);
   signal alu_flags       : std_logic_vector(15 downto 0);
   signal alu_src_val     : std_logic_vector(15 downto 0);
   signal alu_dst_val     : std_logic_vector(15 downto 0);
   signal update_reg      : std_logic;

begin

   i_prepare : entity work.prepare
      port map (
         clk_i            => clk_i,
         rst_i            => rst_i,
         dec_valid_i      => dec_valid_i,
         dec_ready_o      => dec_ready_o,
         dec_microcodes_i => dec_microcodes_i,
         dec_addr_i       => dec_addr_i,
         dec_inst_i       => dec_inst_i,
         dec_immediate_i  => dec_immediate_i,
         dec_src_addr_i   => dec_src_addr_i,
         dec_src_mode_i   => dec_src_mode_i,
         dec_src_val_i    => dec_src_val_i,
         dec_src_imm_i    => dec_src_imm_i,
         dec_dst_addr_i   => dec_dst_addr_i,
         dec_dst_mode_i   => dec_dst_mode_i,
         dec_dst_val_i    => dec_dst_val_i,
         dec_dst_imm_i    => dec_dst_imm_i,
         dec_res_reg_i    => dec_res_reg_i,
         dec_r14_i        => dec_r14_i,
         mem_src_valid_i  => mem_src_valid_i,
         mem_src_ready_o  => mem_src_ready_o,
         mem_src_data_i   => mem_src_data_i,
         mem_dst_valid_i  => mem_dst_valid_i,
         mem_dst_ready_o  => mem_dst_ready_o,
         mem_dst_data_i   => mem_dst_data_i,
         exe_valid_o      => prep_valid,
         exe_ready_i      => prep_ready,
         exe_microcodes_o => prep_microcodes,
         exe_addr_o       => prep_addr,
         exe_inst_o       => prep_inst,
         exe_immediate_o  => prep_immediate,
         exe_src_addr_o   => prep_src_addr,
         exe_src_mode_o   => prep_src_mode,
         exe_src_val_o    => prep_src_val,
         exe_src_imm_o    => prep_src_imm,
         exe_dst_addr_o   => prep_dst_addr,
         exe_dst_mode_o   => prep_dst_mode,
         exe_dst_val_o    => prep_dst_val,
         exe_dst_imm_o    => prep_dst_imm,
         exe_res_reg_o    => prep_res_reg,
         exe_r14_o        => prep_r14,
         alu_oper_o       => alu_oper,
         alu_ctrl_o       => alu_ctrl,
         alu_flags_o      => alu_flags,
         alu_src_val_o    => alu_src_val,
         alu_dst_val_o    => alu_dst_val,
         update_reg_o     => update_reg
      ); -- i_prepare

   i_write : entity work.write
      port map (
         clk_i             => clk_i,
         rst_i             => rst_i,
         prep_valid_i      => prep_valid,
         prep_ready_o      => prep_ready,
         prep_microcodes_i => prep_microcodes,
         prep_addr_i       => prep_addr,
         prep_inst_i       => prep_inst,
         prep_immediate_i  => prep_immediate,
         prep_src_addr_i   => prep_src_addr,
         prep_src_mode_i   => prep_src_mode,
         prep_src_val_i    => prep_src_val,
         prep_src_imm_i    => prep_src_imm,
         prep_dst_addr_i   => prep_dst_addr,
         prep_dst_mode_i   => prep_dst_mode,
         prep_dst_val_i    => prep_dst_val,
         prep_dst_imm_i    => prep_dst_imm,
         prep_res_reg_i    => prep_res_reg,
         prep_r14_i        => prep_r14,
         alu_oper_i        => alu_oper,
         alu_ctrl_i        => alu_ctrl,
         alu_flags_i       => alu_flags,
         alu_src_val_i     => alu_src_val,
         alu_dst_val_i     => alu_dst_val,
         update_reg_i      => update_reg,
         mem_req_valid_o   => mem_req_valid_o,
         mem_req_ready_i   => mem_req_ready_i,
         mem_req_op_o      => mem_req_op_o,
         mem_req_addr_o    => mem_req_addr_o,
         mem_req_data_o    => mem_req_data_o,
         reg_r14_we_o      => reg_r14_we_o,
         reg_r14_o         => reg_r14_o,
         reg_we_o          => reg_we_o,
         reg_addr_o        => reg_addr_o,
         reg_val_o         => reg_val_o,
         fetch_valid_o     => fetch_valid_o,
         fetch_addr_o      => fetch_addr_o,
         inst_done_o       => inst_done_o
      ); -- i_write

end architecture synthesis;

