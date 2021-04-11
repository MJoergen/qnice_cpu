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

## Interfaces
In the following I'll describe in detail the interfaces to the various surrounding blocks.

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
