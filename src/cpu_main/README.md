# The main QNICE pipeline

## Block diagram

![Block Diagram](../../doc/cpu.png)

## Interface
From FETCH
```
fetch_valid_i   : in  std_logic;
fetch_ready_o   : out std_logic;
fetch_double_i  : in  std_logic;
fetch_addr_i    : in  std_logic_vector(15 downto 0);
fetch_data_i    : in  std_logic_vector(31 downto 0); -- 2 words from instruction memory
fetch_double_o  : out std_logic;
```

From DECODE to Register
```
reg_rd_en_o     : out std_logic;
reg_src_reg_o   : out std_logic_vector(3 downto 0);
reg_src_val_i   : in  std_logic_vector(15 downto 0);
reg_dst_reg_o   : out std_logic_vector(3 downto 0);
reg_dst_val_i   : in  std_logic_vector(15 downto 0);
reg_r14_i       : in  std_logic_vector(15 downto 0);
```

From Memory to PREPARE
```
mem_src_valid_i : in  std_logic;
mem_src_ready_o : out std_logic;
mem_src_data_i  : in  std_logic_vector(15 downto 0);
mem_dst_valid_i : in  std_logic;
mem_dst_ready_o : out std_logic;
mem_dst_data_i  : in  std_logic_vector(15 downto 0);
```

From WRITE to Memory
```
mem_req_valid_o : out std_logic;
mem_req_ready_i : in  std_logic;
mem_req_op_o    : out std_logic_vector(2 downto 0);
mem_req_addr_o  : out std_logic_vector(15 downto 0);
mem_req_data_o  : out std_logic_vector(15 downto 0);
```

From WRITE to Register
```
reg_r14_we_o    : out std_logic;
reg_r14_o       : out std_logic_vector(15 downto 0);
reg_we_o        : out std_logic;
reg_addr_o      : out std_logic_vector(3 downto 0);
reg_val_o       : out std_logic_vector(15 downto 0);
```

From WRITE to FETCH
```
fetch_valid_o   : out std_logic;
fetch_addr_o    : out std_logic_vector(15 downto 0);
```

