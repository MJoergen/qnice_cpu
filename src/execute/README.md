# EXECUTE

## Interfaces
```
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
```

