# The main QNICE pipeline

This is a detailed design description of the main CPU pipeline, particularly
the stages DECODE, PREPARE, and WRITE.

Table of contents:
* [Block diagram](#Block-diagram)
* [Microcoding of instructions](#Microcoding-of-instructions)
* [Interfaces](#Interfaces)
* [Bypass](#Bypass)

## Block diagram

![Block Diagram](../../doc/cpu.png)

The remaining blocks are described else-where, see [main documentation](../../doc/README.md#Detailed-design-description).

The three stages DECODE, PREPARE, and WRITE are combined into a single module
`cpu_main`. This is mainly to simplify the formal verification.

## Microcoding of instructions

The really cool feature of this implementation is the conversion from the
CISC-like QNICE instructions to more RISC-like micro-operations. This conversion
is done dynamically, i.e. on-the-fly by the DECODE stage with the help
of a small ROM containing micro-code for the various instruction types.

The main purpose of this micro-coding is to reduce the complexity of the
instructions. And the complexity arises not so much from the advanced
addressing modes, but rather from the fact that each instruction performs up to
three memory operations. For instance, the instruction `ADD @R0, @R1` performs
a read from @R0, then a read from @R1, and finally a write to @R1.  It is these
memory operations that are "serialized" by the micro-coding. In other words,
each micro-operation performs a most one memory operation (read or write).

So to perform this translation we must essentially classify each instruction
depending on which (if any) memory operations it performs. This is done by
examining the addressing mode of the source and destination operand.

Note that this microcoding only concerns with splitting up the memory
operations. Therefore, any optional pre- or post-increment of the registers has
not influence on the micro-coding. This once again simplifies since we need
only to distinguish between pure register addressing mode against any of the
three memory adressing modes.

With the above we have classified the instructions into four classes:
* INST register, register : 1 clock cycle  : Write to register.
* INST register, memory   : 2 clock cycles : Read from destination memory,
  write to destination memory.
* INST memory, register   : 2 clock cycles : Read from source memory, write to
  register.
* INST memory, memory     : 3 clock cycles : Read from source memory, read
  from destination memory, write to destination memory.
Here `INST` is a general instruction like e.g. `ADD`.

I should note, that some instructions don't have two operands. This includes
the Control instructions and the Jump instructions. These are treated
separately.

We could stop here, but I've added several optimizations to this scheme.

### First optimization
First of all, some instructions don't need to read from destination memory.
This is e.g. the `MOVE` instruction.  Likewise, other instructions don't need
to write to destination memory. This is e.g. the 'CMP' instruction.  So we have
additional optimized versions for these instructions:
* MOVE register, register : 1 clock cycle : Write to register.
* MOVE register, memory   : 1 clock cycles : Write to destination memory.
* MOVE memory, register   : 2 clock cycles : Read from source memory, write to
  register.
* MOVE memory, memory     : 2 clock cycles : Read from source memory, write to
  destination memory.

* CMP register, register  : 1 clock cycle : Update Status Register.
* CMP register, memory    : 2 clock cycles : Read from destination memory, update Status Register.
* CMP memory, register    : 2 clock cycles : Read from source memory, update Status Register.
* CMP memory, memory      : 3 clock cycles : Read from source memory, read from
  destination memory, update Status Register.
Note that even tough the `CMP` instruction to not need to write to memory, they
still expand to the same number of micro-operations. This is because we need
one micro-operation to wait for the result read back from memory.

### Second optimization
Another optimization is that I treat immediate operands as a special case. An
immediate operand is encoded as @R15++ in the instruction, but there is no beed
to perform a read from memory in this case, because the value is already given
by the FETCH module.

What about instructions with @R15++ in both operands, e.g. `ADD @R15++, @R15++`.
This FETCH module only provides the first immediate operand. The second immediate operand
is handled using a regular memory read.

Furthermore, other addressing modes involving the Program Counter, i,e. `@R15`
and `@--R15` are handled as any other memory operation. Note that `@--R15` will
decrement the Program Counter, which in turn (as described below) will be
interpreted as a jump instruction.

### Pre- and post-increment
Special care must be taken when handling instructions like `ADD @R0++, @R0++`
since both the source and destination operands refer to the same register, and
this register is updated in both operands. It is therefore essential that the
source register is updated before issuing the read for the destination operand.

### Description of micro-operations
Each micro-operation consists of an array of 12 bits with the following meaning:

* 11: Indicates the last micro-operation for this instruction.
* 10-8: Not used.
* 7: Optionally modify source register (`@R++` or `@--R`).
* 6: Optionally modify destination register (`@R++` or `@--R`).
* 5: Wait from source operand from memory.
* 4: Wait from destination operand from memory.
* 3: Write to destination register.
* 2: Read from memory to source.
* 1: Read from memory to destination.
* 0: Write to destination memory.

### Examples

Here I'll show a detailed description of some example instructions.

We'll start with a simple `MOVE R0, R1`. Since this instruction has no memory operations at all,
it simplifies to the following:
|      Micro     |  One  |  Two  | Three |
|      -----     | ----- | ----- | ----- |
|`LAST         ` |   X   |       |       |
|`REG_MOD_SRC  ` |       |       |       |
|`REG_MOD_DST  ` |       |       |       |
|`MEM_WAIT_SRC ` |       |       |       |
|`MEM_WAIT_DST ` |       |       |       |
|`REG_WRITE    ` |   X   |       |       |
|`MEM_READ_SRC ` |       |       |       |
|`MEM_READ_DST ` |       |       |       |
|`MEM_WRITE    ` |       |       |       |

An instruction like `MOVE @R0, @R1` performs two memory instructions:
|      Micro     |  One  |  Two  | Three |
|      -----     | ----- | ----- | ----- |
|`LAST         ` |       |   X   |       |
|`REG_MOD_SRC  ` |   X   |       |       |
|`REG_MOD_DST  ` |       |   X   |       |
|`MEM_WAIT_SRC ` |       |   X   |       |
|`MEM_WAIT_DST ` |       |       |       |
|`REG_WRITE    ` |       |       |       |
|`MEM_READ_SRC ` |   X   |       |       |
|`MEM_READ_DST ` |       |       |       |
|`MEM_WRITE    ` |       |   X   |       |

* The first micro-operation issues a read to source operand and simultaneously
  (optionally) updates the source register. This latter operation has no effect
  for this particular instruction.
* The second micro-operation waits for the source operand to be read from
  memory, issues a write to destination memory, and optionally updates the
  destination register

An instruction like `ADD @R0, @R1` performs three memory instructions:
|      Micro     |  One  |  Two  | Three |
|      -----     | ----- | ----- | ----- |
|`LAST         ` |       |       |   X   |
|`REG_MOD_SRC  ` |   X   |       |       |
|`REG_MOD_DST  ` |       |       |   X   |
|`MEM_WAIT_SRC ` |       |       |   X   |
|`MEM_WAIT_DST ` |       |       |   X   |
|`REG_WRITE    ` |       |       |       |
|`MEM_READ_SRC ` |   X   |       |       |
|`MEM_READ_DST ` |       |   X   |       |
|`MEM_WRITE    ` |       |       |   X   |

* The first micro-operation again issues a read to source operand and
  simultaneously (optionally) updates the source register, in case it is needed
  by the destination operand.
* The second micro-operations just issues a read to destination operand. Note
  that here the destination register is not updated, because the same value
  will be used during the memory write in the next micro-operation.
* The third and last micro-operation optinally updates the destination
  register, waits for both memory operands to be ready, and writes the result
  back to memory.

## Interfaces
In the following I'll describe in detail the interfaces to the various
surrounding blocks.

### From FETCH to DECODE
```
fetch_valid_i  : in  std_logic;
fetch_ready_o  : out std_logic;
fetch_double_i : in  std_logic;
fetch_addr_i   : in  std_logic_vector(15 downto 0);
fetch_data_i   : in  std_logic_vector(31 downto 0);
fetch_double_o : out std_logic;
```
This AXI-interface accepts one or two words from the FETCH module. The signal
`fetch_double_i` from the FETCH module indicates whether the signal
`fetch_data_i` contains one or two words.
Correspondingly, the signal `fetch_double_o` back to the FETCH module indicates
whether we wish to consume one or two words.

The idea behind this is that some instructions contain an immediate operand.
Transferring two words (i.e. instruction and immediate operand) simultaneously
greatly simplifies the implementation of the DECODE stage.  Furthermore, this
allows [interleaving](../../doc/README.md#Interleaving) of consecutive
instructions.

The instruction is always present in bits 15-0 and any immediate operand (or
possibly next instruction) is optionally present in bits 31-16. The signal
`fetch_addr_i` contains the address (i.e. Program Counter) of the instruction.
In other words, even though the Register module contains all the CPU registers,
the only exception is that the Program Counter (`R15`) is stored in the FETCH
module and forwarded through the pipeline as a separate signal.

### From DECODE to Register
```
reg_rd_en_o   : out std_logic;
reg_src_reg_o : out std_logic_vector(3 downto 0);
reg_src_val_i : in  std_logic_vector(15 downto 0);
reg_dst_reg_o : out std_logic_vector(3 downto 0);
reg_dst_val_i : in  std_logic_vector(15 downto 0);
reg_r14_i     : in  std_logic_vector(15 downto 0);
```
The DECODE stage reads from the Register module. Note that the values read back
(in `reg_src_val_i` and `reg_dst_val_i`) are valid on the following clock
cycle. I.e. there is a fixed one-clock-cycle latency.

We could have used the standard AXI-interface with `VALID` and `READY` signals,
but since the latency is constant, I've chosen not to. However, we do need the
signal `reg_rd_en_o` because when back-pressure is received from the PREPARE
stage, we don't want to issue new read requests, i.e. we don't want the values
`reg_src_val_i` and `reg_dst_val_i` to change.

The signal `reg_r14_i` always returns the current value of the Status Register
`R14`. This is needed in the WRITE stage for the ALU and for conditional
branching.

### From WRITE to Register
```
reg_we_o     : out std_logic;
reg_addr_o   : out std_logic_vector(3 downto 0);
reg_val_o    : out std_logic_vector(15 downto 0);
reg_r14_we_o : out std_logic;
reg_r14_o    : out std_logic_vector(15 downto 0);
```

The WRITE stage calculates new value for the destination register and
simultaneously a new value for the Status Register `R14`. There is a separate
Write-Enable for the destination and status registers. There is no support for
back-pressure, simply because the Register file always accepts and performs a
write.

### From WRITE to Memory
```
mem_req_valid_o : out std_logic;
mem_req_ready_i : in  std_logic;
mem_req_op_o    : out std_logic_vector(2 downto 0);
mem_req_addr_o  : out std_logic_vector(15 downto 0);
mem_req_data_o  : out std_logic_vector(15 downto 0);
```
It is the WRITE stage that issues both read and write requests to the Memory
module. This is because the DECODE stage generates micro-operations that each
perform at most one memory operation.

This interface is close linked together with how the [Wishbone
interface](../../doc/README.md#Wishbone) works and how the [Memory
module](../memory/README.md) is designed.

Note we have the standard AXI-interface controlling when the Memory module
accepts a transaction request (read or write). The type of request is
controlled by the one-hot-encoded `mem_req_op_o` signal:
* Bit 2 : Read from memory and store in Source buffer.
* Bit 1 : Read from memory and store in Destination buffer.
* Bit 0 : Write to memory.
Exactly one of these three bits must be set for any transaction.

Since all memory transactions are controlled by the same stage (WRITE), this
greatly simplifies the Memory module. Correspondingly, since the Memory module
contains buffers for both Source and Destination operands, this greatly
simplifies the PREPARE module, see below.

### From Memory to PREPARE
```
mem_src_valid_i : in  std_logic;
mem_src_ready_o : out std_logic;
mem_src_data_i  : in  std_logic_vector(15 downto 0);
mem_dst_valid_i : in  std_logic;
mem_dst_ready_o : out std_logic;
mem_dst_data_i  : in  std_logic_vector(15 downto 0);
```

The PREPARE module receives optionally a Source and/or a Destination operand
from the Memory module. The interface uses two parallel AXI-interfaces; this
significantly simplifies the PREPARE stage.


### From WRITE to FETCH
The interfaces described so far works for almost all instructions and
addressing modes.  However, during branches the Program Counter `R15` inside
the FETCH module must be updated. This is controlled by the following two
signals generated by the WRITE stage.
```
fetch_valid_o : out std_logic;
fetch_addr_o  : out std_logic_vector(15 downto 0);
```

## Bypass
Whenever one has a pipelined architecture, where later stages write back to
storage (i.e. register file) that is read in an earlier stage, we have a data
hazard. In other words, we need to ensure that the register values read in the
DECODE stage are not stale compared to the values writte in the WRITE stage.
This is handled by various bypass operations.
