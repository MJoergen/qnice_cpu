# DECODE

## Interfaces
```
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
exe_microcodes_o : out std_logic_vector(35 downto 0);
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
```

## Instruction decoding

The first step in the instruction decoding is to categorize the instuction
depending on:
* Does the instruction have a source operand?
* Does the instruction have a destination operand?
* Is the source operand an immediate value, i.e. `@PC++`?
* Is the destination operand an immediate value, i.e. `@PC++`?
* Does instruction read from destination operand?
* Does instruction write to destination operand?
* Does source operand involve memory?
* Does destination operand involve memory?

Based on the last four questions, the Decode module generates a list of up to three microcode
instructions.

Below are some examples of instruction decodings.  In the table below I use the
following abreviations:
* `MRS` : Read from memory to source operand buffer
* `MRD` : Read from memory to destination operand buffer
* `MW`  : Write to memory
* `RW`  : Write to register

For `MOVE`-like instructions (that writes to but does not read from destination):
```
               | MRS | MRD |  MW |  RW |
               +-----+-----+-----+-----+
MOVE R, R      |  .  |  .  |  .  |  X  |
               |-----|-----+-----+-----+
MOVE R, @R     |  .  |  .  |  X  |  .  |
               |-----|-----+-----+-----+
MOVE @R, R     |  X  |  .  |  .  |  .  |
               |  .  |  .  |  .  |  X  |
               |-----|-----+-----+-----+
MOVE @R, @R    |  X  |  .  |  .  |  .  |
               |  .  |  .  |  X  |  .  |
               +-----+-----+-----+-----+
```

For `CMP`-like instructions (that reads from but does not write to destination):
```
               | MRS | MRD |  MW |  RW |
               +-----+-----+-----+-----+
CMP R, R       |  .  |  .  |  .  |  .  |
               |-----|-----+-----+-----+
CMP R, @R      |  .  |  X  |  .  |  .  |
               |  .  |  .  |  .  |  .  |
               |-----|-----+-----+-----+
CMP @R, R      |  X  |  .  |  .  |  .  |
               |  .  |  .  |  .  |  .  |
               |-----|-----+-----+-----+
CMP @R, @R     |  X  |  .  |  .  |  .  |
               |  .  |  X  |  .  |  .  |
               |-----|-----+-----+-----+
```

For `ADD`-like instructions (that reads from and writes to destination):
```
               | MRS | MRD |  MW |  RW |
               +-----+-----+-----+-----+
ADD R, R       |  .  |  .  |  .  |  X  |
               |-----|-----+-----+-----+
ADD R, @R      |  .  |  X  |  .  |  .  |
               |  .  |  .  |  X  |  .  |
               |-----|-----+-----+-----+
ADD @R, R      |  X  |  .  |  .  |  .  |
               |  .  |  .  |  .  |  X  |
               |-----|-----+-----+-----+
ADD @R, @R     |  X  |  .  |  .  |  .  |
               |  .  |  X  |  .  |  .  |
               |  .  |  .  |  X  |  .  |
               +-----+-----+-----+-----+
```

For control and jump instructions that neither reads from nor writes to destination:

```
               | MRS | MRD |  MW |  RW |
               +-----+-----+-----+-----+
JMP R          |  .  |  .  |  .  |  .  |
               |-----|-----+-----+-----+
JMP @R         |  X  |  .  |  .  |  .  |
               |  .  |  .  |  .  |  .  |
               |-----|-----+-----+-----+
ASUB R         |  .  |  .  |  X  |  .  |
               |-----|-----+-----+-----+
ASUB @R        |  X  |  .  |  .  |  .  |
               |  .  |  .  |  X  |  .  |
               |-----|-----+-----+-----+
```

One thing to note in the above is that `MW` and `RW` are never true in the same
clock cycle.

To the Execute module we have a number of signals for each clock cycle:
* `MEM_WAIT_SRC` : Wait for source operand from memory
* `MEM_WAIT_DST` : Wait for destination operand from memory
* `MEM_WRITE`    : Write to memory
* `MEM_READ_SRC` : Read from memory and store in source buffer
* `MEM_READ_DST` : Read from memory and store in destination buffer
* `REG_WRITE`    : Write to register

The above signals are copied three times for the up to three clock cycles an
instruction make take.

Then there are some additional signals
* `OPER`     : ALU operation. This is almost identical to the instruction opcode.
* `CTRL`     : CTRL command. This is identical to corresponding field in the instruction.
* `SRC_REG`  : Source register number
* `SRC_MODE` : Source mode
* `SRC_IMM`  : Source immediate mode (i.e. `@PC++`)
* `SRC_VAL`  : Source register value
* `DST_REG`  : Destination register number
* `DST_MODE` : Destination mode
* `DST_IMM`  : Destination immediate mode (i.e. `@PC++`)
* `DST_VAL`  : Destination register value
* `R14`      : Current value of Status Register


