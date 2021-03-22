# A pipelined implementation of the QNICE CPU

This version of the QNICE CPU (from the QNICE-FPGA project) is not a drop-in
replacement, for the following three reasons:
* This design uses the Wishbone memory bus.
* This design uses separate instruction and data interfaces.
* This design expects a one-clock-cycle delay when reading from instruction and/or data memory.

However, it should be a simple operation to modify the QNICE-FPGA project to
support this implementation.

The overall idea of this implementation is to convert each instruction into a
sequence of micro-operations:
* Read from memory to source operand buffer
* Read from memory to destination operand buffer
* Write to memory
* Write to register

The reason is that e.g. the instruction `ADD @R0, @R1` performs two memory
reads (from `@R0` and `@R1`) and one memory write (to `@R1`). Since only one
memory operation is possible in each clock cycle, such an instruction will
need to be serialized and will take a total of three clock cycles.


## Architecture
This is essentially a three-stage pipeline consisting of:

* FETCH: Fetches two words at a time from the instruction memory.
* DECODE: Outputs a sequence of single micro-operations.
* EXECUTE: Executes one micro-operation.

See the following block diagram:

![Block Diagram](doc/cpu.png)


## Interfaces
From the FETCH to the DECODE stage we have the following signals:
```
valid          : std_logic;
ready          : std_logic;
double_valid   : std_logic;
addr           : std_logic_vector(15 downto 0);
data           : std_logic_vector(31 downto 0);
double_consume : std_logic;
```

Here `valid` and `ready` are the usual handshaking signals, `addr` is the
address of the current instruction, and `data` contains one or two words of
data, as indicated by the signal `double_valid`. In either case `data(15 downto
0)` is the instruction, and `data(31 downto 16)` is the immediate operand if
present.

In conjunction with the `ready` signal, the signal `double_consume` indicates
whether one or two words are consumed in this clock cycle. Therefore, this
signal must depend combinatorially on the input signals.

From the DECODE stage to the EXECUTE stage
```
valid      : std_logic;
ready      : std_logic;
microcodes : std_logic_vector(11 downto 0);
addr       : std_logic_vector(15 downto 0);
inst       : std_logic_vector(15 downto 0);
immediate  : std_logic_vector(15 downto 0);
src_addr   : std_logic_vector(3 downto 0);
src_mode   : std_logic_vector(1 downto 0);
src_val    : std_logic_vector(15 downto 0);
src_imm    : std_logic;
dst_addr   : std_logic_vector(3 downto 0);
dst_mode   : std_logic_vector(1 downto 0);
dst_val    : std_logic_vector(15 downto 0);
dst_imm    : std_logic;
res_reg    : std_logic_vector(3 downto 0);
r14        : std_logic_vector(15 downto 0);
```

Between the DECODE stage and the register file we have:
```
rd_en   : std_logic;
src_reg : std_logic_vector(3 downto 0);
src_val : std_logic_vector(15 downto 0);
dst_reg : std_logic_vector(3 downto 0);
dst_val : std_logic_vector(15 downto 0);
r14     : std_logic_vector(15 downto 0);
```

Between the EXECUTE stage and the register file we have:
```
r14_we : std_logic;
r14    : std_logic_vector(15 downto 0);
we     : std_logic;
addr   : std_logic_vector(3 downto 0);
val    : std_logic_vector(15 downto 0);
```

Between the EXECUTE stage and the memory module we have:
```
req_valid : std_logic;
req_ready : std_logic;
req_op    : std_logic_vector(2 downto 0);
req_addr  : std_logic_vector(15 downto 0);
req_data  : std_logic_vector(15 downto 0);
src_valid : std_logic;
src_ready : std_logic;
src_data  : std_logic_vector(15 downto 0);
dst_valid : std_logic;
dst_ready : std_logic;
dst_data  : std_logic_vector(15 downto 0);
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


## TODO
* Cleanup code.
* Formal verification.
* Cycle Optimizations (see below).
* Add interrupts.
* Timing optimizations.


## Cycle Optimizations:
1. Eliminate the NOP cycle from the CMP @R1, @PC++ instruction.
2. Optimize conditional jumps, so they don't execute superfluous microoperations.
3. Optimize FETCH module. It currently takes three clock cycles after a jump. This could be reduced to one clock cycle.

## Utilization

|   Name    | LUTs | Regs | Slices |
| --------- | ---- | ---- | ------ |
| Fetch     |   84 |  152 |    51  |
| Decode    |   77 |   78 |    55  |
| Execute   |  524 |    0 |   198  |
| Registers |  112 |  141 |    83  |
| Memory    |   46 |   37 |    40  |
| TOTAL     |  843 |  408 |   291  |


