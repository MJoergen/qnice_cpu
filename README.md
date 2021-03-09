# A pipelined implementation of the QNICE CPU

This version of the QNICE CPU (from the QNICE-FPGA project) is not a drop-in
replacement, for the following two reasons:
* This design uses the Wishbone memory bus.
* This design uses separate instruction and data interfaces.

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
This is essentially a five-stage pipeline consisting of:

* Fetch: Fetches one word at a time from the instruction memory.
* Instruction Cache: Forwards two words at a time to the decoder.
* Decode: Generates a list of micro-operations.
* Serializer: Outputs a sequence of single micro-operations.
* Execute: Executes one micro-operation.

TBD: The Fetch and Instruction Cache will be merged into one stage, and
the Serializer and Execute will be merged too.

See the following block diagram:

![Block Diagram](doc/cpu.png)


## Interfaces
From the Fetch into the Instruction Cache module we have the following signals:
```
valid_i : in  std_logic;
ready_o : out std_logic;
addr_i  : in  std_logic_vector(15 downto 0);
data_i  : in  std_logic_vector(15 downto 0);
```

Here `valid_i` and `ready_o` are the usual handshaking signals, `addr_i` is the
current address, and `data_i` is the corresponding data. Except for branches,
`addr_i` will automatically increment.


From the ICache into the Decode module we have the following signals:
```
valid_i  : in  std_logic;
ready_o  : out std_logic;
double_i : in  std_logic;
addr_i   : in  std_logic_vector(15 downto 0);
data_i   : in  std_logic_vector(31 downto 0);
double_o : out std_logic;
```

Here `valid_i` and `ready_o` are the usual handshaking signals, `addr_i` is the
address of the current instruction, and `data_i` contains one or two words of
data, as indicated by the signal `double_i`. In either case `data_i(15 downto
0)` is the instruction, and `data_i(31 downto 16)` is the immediate operand if
present.

In conjunction with the `ready_o` signal, the signal `double_o` indicates
whether one or two words are consumed in this clock cycle. Therefore, this
signal must depend combinatorially on the input signals.

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
| Fetch     |   45 |   86 |    30  |
| Decode    |   53 |   82 |    44  |
| Execute   |  489 |    0 |   171  |
| Registers |   71 |   56 |    39  |
| Memory    |   43 |   37 |    45  |
| TOTAL     |  748 |  333 |   255  |


