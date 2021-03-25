# MEMORY module

## Interfaces
The top-level interface of the MEMORY module is as follows:
```
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
```


## Implementation

## Formal verification

