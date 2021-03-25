# REGISTERS module

## Interfaces
The top-level interface of the REGISTERS module is as follows:
```
-- Read interface
rd_en_i       : in  std_logic;
src_reg_i     : in  std_logic_vector(3 downto 0);
src_val_o     : out std_logic_vector(15 downto 0);
dst_reg_i     : in  std_logic_vector(3 downto 0);
dst_val_o     : out std_logic_vector(15 downto 0);
r14_o         : out std_logic_vector(15 downto 0);
-- Write interface
wr_r14_en_i   : in  std_logic;
wr_r14_i      : in  std_logic_vector(15 downto 0);
wr_en_i       : in  std_logic;
wr_addr_i     : in  std_logic_vector(3 downto 0);
wr_val_i      : in  std_logic_vector(15 downto 0)
```


## Implementation


## Formal verification

