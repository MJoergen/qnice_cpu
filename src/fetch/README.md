# FETCH module

## Interfaces
The top-level interface of the FETCH module is as follows:
```
-- From EXECUTE stage
s_valid_i   : in  std_logic;
s_addr_i    : in  std_logic_vector(15 downto 0);

-- Instruction Memory
wbi_cyc_o   : out std_logic;
wbi_stb_o   : out std_logic;
wbi_stall_i : in  std_logic;
wbi_addr_o  : out std_logic_vector(15 downto 0);
wbi_ack_i   : in  std_logic;
wbi_data_i  : in  std_logic_vector(15 downto 0);

-- To DECODE stage
m_valid_o   : out std_logic;
m_ready_i   : in  std_logic;
m_double_o  : out std_logic;
m_addr_o    : out std_logic_vector(15 downto 0);
m_data_o    : out std_logic_vector(31 downto 0);
m_double_i  : in  std_logic
```

Here `m_valid_o` and `m_ready_i` are the usual handshaking signals, `m_addr_o`
is the address of the current instruction, and `m_data_o` contains one or two
words of data, as indicated by the signal `m_double_o`. In either case `data(15
downto 0)` is the instruction, and `data(31 downto 16)` is the immediate
operand if present.

In conjunction with the `m_ready_i` signal, the signal `m_double_i` indicates
whether one or two words are consumed in this clock cycle. Therefore, this
signal must depend combinatorially on the input signals.

## Implementation
The FETCH module consists of a simpler one-word-at-a-time file fetch.vhd and a
simple instruction cache icache.vhd.

## Formal verification
Currently, only the file fetch.vhd is formally verified.

