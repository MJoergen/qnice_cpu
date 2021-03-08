library ieee;
use ieee.std_logic_1164.all;

use work.cpu_constants.all;

entity memory is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- From execute
      mreq_valid_i : in  std_logic;
      mreq_ready_o : out std_logic;
      mreq_op_i    : in  std_logic_vector(2 downto 0);
      mreq_addr_i  : in  std_logic_vector(15 downto 0);
      mreq_data_i  : in  std_logic_vector(15 downto 0);

      -- To execute
      msrc_valid_o : out std_logic;
      msrc_ready_i : in  std_logic;
      msrc_data_o  : out std_logic_vector(15 downto 0);

      mdst_valid_o : out std_logic;
      mdst_ready_i : in  std_logic;
      mdst_data_o  : out std_logic_vector(15 downto 0);

      -- Memory
      wb_cyc_o     : out std_logic;
      wb_stb_o     : out std_logic;
      wb_stall_i   : in  std_logic;
      wb_addr_o    : out std_logic_vector(15 downto 0);
      wb_we_o      : out std_logic;
      wb_dat_o     : out std_logic_vector(15 downto 0);
      wb_ack_i     : in  std_logic;
      wb_data_i    : in  std_logic_vector(15 downto 0)
   );
end entity memory;

architecture synthesis of memory is

   signal osf_mem_in_valid  : std_logic;
   signal osf_mem_in_ready  : std_logic;
   signal osf_mem_out_valid : std_logic;
   signal osf_mem_out_ready : std_logic;
   signal osf_mem_out_data  : std_logic;

   signal osb_src_in_valid  : std_logic;
   signal osb_src_in_ready  : std_logic;
   signal osb_dst_in_valid  : std_logic;
   signal osb_dst_in_ready  : std_logic;

   signal wait_for_ack      : std_logic;

begin

   mreq_ready_o <= not (mreq_op_i(C_MEM_READ_SRC) and msrc_valid_o and not msrc_ready_i)
               and not (mreq_op_i(C_MEM_READ_DST) and mdst_valid_o and not mdst_ready_i);


   -- WISHBONE request interface is combinatorial
   wb_cyc_o  <= ((mreq_valid_i and mreq_ready_o) or wait_for_ack) and not rst_i;
   wb_stb_o  <= wb_cyc_o and mreq_valid_i and mreq_ready_o;
   wb_addr_o <= mreq_addr_i;
   wb_we_o   <= mreq_valid_i and mreq_op_i(C_MEM_WRITE);
   wb_dat_o  <= mreq_data_i;

   p_wait_for_ack : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wb_cyc_o and wb_ack_i then
            wait_for_ack <= '0';
         end if;

         if wb_cyc_o and wb_stb_o and not wb_stall_i then
            wait_for_ack <= '1';
         end if;

         if rst_i = '1' then
            wait_for_ack <= '0';
         end if;
      end if;
   end process p_wait_for_ack;


   ----------------------
   -- Store the request
   ----------------------

   osf_mem_in_valid <= mreq_valid_i and mreq_ready_o and (mreq_op_i(C_MEM_READ_SRC) or mreq_op_i(C_MEM_READ_DST));

   i_one_stage_fifo_mem : entity work.one_stage_fifo
      generic map (
         G_DATA_SIZE => 1
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         s_valid_i   => osf_mem_in_valid,
         s_ready_o   => osf_mem_in_ready,
         s_data_i(0) => mreq_op_i(C_MEM_READ_SRC),
         m_valid_o   => osf_mem_out_valid,
         m_ready_i   => wb_cyc_o and wb_ack_i,
         m_data_o(0) => osf_mem_out_data
      ); -- i_one_stage_fifo_mem


   ------------------------------------------
   -- Store the response for the SRC output
   ------------------------------------------

   osb_src_in_valid <= wb_ack_i and osf_mem_out_valid and osf_mem_out_data;

   i_one_stage_buffer_src : entity work.one_stage_buffer
      generic map (
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         s_valid_i => osb_src_in_valid,
         s_ready_o => osb_src_in_ready,
         s_data_i  => wb_data_i,
         m_valid_o => msrc_valid_o,
         m_ready_i => msrc_ready_i,
         m_data_o  => msrc_data_o
      ); -- i_one_stage_buffer_src


   ------------------------------------------
   -- Store the response for the DST output
   ------------------------------------------

   osb_dst_in_valid <= wb_ack_i and osf_mem_out_valid and not osf_mem_out_data;

   i_one_stage_buffer_dst : entity work.one_stage_buffer
      generic map (
         G_DATA_SIZE => 16
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         s_valid_i => osb_dst_in_valid,
         s_ready_o => osb_dst_in_ready,
         s_data_i  => wb_data_i,
         m_valid_o => mdst_valid_o,
         m_ready_i => mdst_ready_i,
         m_data_o  => mdst_data_o
      ); -- i_one_stage_buffer_dst

end architecture synthesis;

