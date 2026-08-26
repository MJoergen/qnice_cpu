# VHDL coding style

This document records the conventions the VHDL in this repository already follows, so that new
code — and edits to old code — look like they came from the same hand. Where the repository is
currently inconsistent, the rule below states the *majority* form, and
[Known deviations](#known-deviations) lists the files that still differ.

All VHDL here is **VHDL-2008** (`ghdl --std=08`, `read_vhdl -vhdl2008` in Vivado). Use 2008
constructs freely.

## 1. File layout

Every file is one design unit (or one package + package body) and is laid out in this order:

```vhdl
-- <module description: what it is, THEORY OF OPERATION, INTERFACE CONTRACTS, RESET>

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.cpu_constants.t_stage;

entity foo is
   generic (...);
   port (...);
end entity foo;

architecture synthesis of foo is
   -- declarations
begin
   -- statements
end architecture synthesis;
```

* **Header comment first, `library` second.** The descriptive block sits *above* `library`, not
  between the `use` clauses and the `entity`. Rationale: the header is what a reader wants to see
  first, before wading through boilerplate imports.
* `library ieee;` itself is not indented, but every `use` clause is indented 3 spaces —
  including `use work.*` clauses, which have no `library work;` line of their own.
* A blank line separates the `ieee` `use` clauses from the `work` ones.
* Architecture name is `synthesis`, or `simulation` for a unit that is simulation-only
  (`debug.vhd`, `tb_cpu.vhd`, `test_monitor.vhd`).
* Close with the full form: `end entity foo;`, `end architecture synthesis;`,
  `end package cpu_constants;`, `end package body cpu_constants;`.
* A single blank line follows the final `end architecture`. No trailing whitespace and
  no tabs anywhere.

### Header comments

A non-trivial module gets a prose header. The established structure, in the order it appears, is:

```
-- <one-paragraph summary of what the module is>
--
-- THEORY OF OPERATION
-- <how it works, what the invariants are>
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) ...
-- b) ...
--
-- RESET
-- <synchronous? does it double as a flush? what is gated combinationally?>
```

Not every section is mandatory — a leaf module may need only the summary — but use these headings
when the content exists, rather than inventing new ones. Contracts are lettered `a)`, `b)`, `c)`.

Header comments are plain `--` lines at column 0. **Do not** wrap them in `-- ----------` boxes.

## 2. Naming

| Kind | Convention | Example |
|---|---|---|
| Entity, architecture, file | `lower_snake_case`, file named after the entity | `two_stage_fifo.vhd` |
| Port | `lower_snake_case` + `_i` / `_o` | `mem_req_valid_o` |
| Generic | `G_UPPER_SNAKE` | `G_REGISTER_BANK_WIDTH` |
| Constant | `C_UPPER_SNAKE` | `C_OPCODE_JMP` |
| Bit-field `subtype` / bit index into an instruction word | `R_UPPER_SNAKE` | `R_SRC_MODE`, `R_JMP_NEG` |
| Type | `t_` prefix | `t_stage` |
| Signal, variable | `lower_snake_case` | `wb_outstanding` |
| Process label | `p_` prefix | `p_wishbone` |
| Instance label | `i_` prefix | `i_two_stage_fifo_addr` |
| Generate label | `gen_` prefix | `gen_block_ram` |
| Loop label | plain, descriptive | `main_loop` |

Every port ends in `_i` or `_o` and every generic starts with `G_` — this is currently 100 %
consistent, keep it that way. `clk_i` and `rst_i` come first in every port list.

Optional signal suffixes, used where the distinction earns its keep:

* `_r` — a register (`m_valid_r`, `s_data_r`).
* `_d` — a one-cycle-delayed copy of something (`wr_en_d`, `halt_d`).
* `_s` — a combinational alias of an output that is also read internally (`s_ready_s`).
* `_v` — a process variable (`stale_v`, `cancel_v`).

These are conventions, not requirements; a plainly-named register (`index`, `count`, `reg_sr`) is
fine when there is nothing to disambiguate it from. Do not *rename* existing signals to add a
suffix.

**Instance labels name the entity plus the role**, not an abbreviation:
`i_two_stage_fifo_addr`, `i_one_stage_buffer_wb`, `i_ram_lower_src`. When a module instantiates
exactly one of something, `i_<entity>` alone is enough (`i_alu`, `i_sequencer`).

**Signals connecting two sub-modules in a structural entity** are named `<from>2<to>_<what>`:
`fetch2icache_valid`, `wr2mem_req_addr`, `icache2decode_data`. See `src/cpu.vhd`.

## 3. Formatting

* **Indent is 3 spaces.** No tabs.
* **Continuation lines align to the expression they continue**, not to the 3-space grid.
* Aim to keep lines under **100 columns**. This is a target, not a hard limit — a long
  `when ... else` chain that reads better on one line may exceed it.
* Colons in a `port`/`generic`/`signal`/`variable` declaration block are **aligned within each
  blank-line-separated group**, not across the whole declarative region:

  ```vhdl
     signal tsf_req_in_valid  : std_logic;
     signal tsf_req_in_ready  : std_logic;
     signal tsf_req_fill      : natural range 0 to 2;

     signal tsb_src_in_valid  : std_logic;
     signal tsb_src_in_ready  : std_logic;
  ```

* Port modes are written `in ` / `out` with **a single alignment space after `in`**:

  ```vhdl
        clk_i     : in  std_logic;
        s_ready_o : out std_logic;
  ```

* No spaces around `-` in a width expression: `std_logic_vector(G_DATA_SIZE-1 downto 0)`.
  Spaces around arithmetic in ordinary expressions: `addr_v + 1`, `pending_v + stale_v`.
* `when ... else` chains put `else` at the **end** of the line and align the conditions:

  ```vhdl
     alu_src_val <= seq_stage.immediate when seq_stage.src_imm = '1'                    else
                    mem_src_data_i      when seq_stage.microcodes(C_MEM_WAIT_SRC) = '1' else
                    src_val_pc;
  ```

* One statement per line. The exception is a deliberate *table* — see the opcode/flag matrix in
  `alu_flags.vhd`, where the alignment is the point.
* Instantiations always close with a label comment:

  ```vhdl
        ); -- i_sequencer
  ```

* Section separators inside an architecture are exactly **60 dashes at indent 3**, with the title
  between two of them and a blank line either side:

  ```vhdl
     ------------------------------------------------------------
     -- Instruction FETCH
     ------------------------------------------------------------
  ```

  Use them only in files large enough to need navigation aids.

## 4. Coding idioms

* **Direct entity instantiation** (`entity work.foo`) everywhere. No component declarations,
  no configurations.
* **Synchronous, active-high reset**, sampled inside `if rising_edge(clk_i) then`, and written as
  the **last** `if` in the process so that it overrides everything above it:

  ```vhdl
     p_output : process (clk_i)
     begin
        if rising_edge(clk_i) then
           -- normal operation
           ...

           if rst_i = '1' then
              valid_o <= '0';
           end if;
        end if;
     end process p_output;
  ```

  Do not use asynchronous reset. Do not reset data registers that are qualified by a valid bit —
  only the control bit is reset (see `one_stage_fifo.vhd`).

* **Compare `std_logic` explicitly**: `if halt_i = '1' then`, `when src_imm = '1' else`. Do not
  rely on the VHDL-2008 implicit condition operator (`if halt_i then`) — it reads as a boolean and
  hides the type.
* Reduction operators are written `or(vec) = '1'` when used as a condition and `or(vec)` when the
  result is itself a `std_logic` being assigned. Do not write `or(vec) /= '0'`.
* **`numeric_std_unsigned` is the default** numeric package: `std_logic_vector` is treated as
  unsigned and `+`/`-`/comparison work directly on it. Import `numeric_std` only in a file that
  genuinely needs explicit `signed`/`unsigned` types (`alu_data.vhd`, `alu_flags.vhd`). **Do not
  import a numeric package a file does not use.**
* Import from `work.cpu_constants` **selectively** when a module needs only a handful of names
  (`use work.cpu_constants.C_REG_SR;`), and with `.all` in the DECODE/PREPARE/WRITE family, which
  uses dozens.
* Signal initializers (`:= '0'`, `:= (others => '0')`) are used on registers whose power-up state
  matters for simulation or for the formal environment. They are not a substitute for `rst_i`; see
  the note in `one_stage_buffer.vhd`'s header.
* Every `process`, instantiation and `generate` carries a label, and the label is repeated on the
  closing keyword (`end process p_fsm;`, `end generate gen_block_ram;`).
* **No shared variables.** VHDL-2008 requires a shared variable to be of a protected type, and a
  protected type is not synthesisable, so a plain one compiles only under GHDL's `-frelaxed` —
  which this repository deliberately does not pass (see below). A memory array is an ordinary
  signal with exactly one driver, written from one process; see `src/sub/dp_ram.vhd` for the
  consequences that has for RAM inference.
* **The GHDL command line carries no `-frelaxed`.** Every `ghdl` invocation in the `Makefile` is
  plain `--std=08`, so the whole design is LRM-conformant VHDL-2008 rather than
  conformant-plus-waivers. If a new file needs the flag, fix the file.

## 5. Simulation-only code

Guard it with **`-- pragma synthesis_off` / `-- pragma synthesis_on`**, written at **column 0** so
the guard is impossible to miss:

```vhdl
-- pragma synthesis_off
   p_debug : process (clk_i)
   begin
      ...
   end process p_debug;
-- pragma synthesis_on
```

`-- pragma translate_off` is the older spelling and means the same thing to every tool in this
flow; prefer `synthesis_off` in new code.

Assertions are written with the `report`/`severity` clauses each on their own line, indented under
the `assert`:

```vhdl
   assert (s_valid_i'stable(0 ns))
      report "one_stage_buffer: s_valid_i deasserted while stalled (s_ready_o was '0')"
      severity error;
```

Use `severity error` for a protocol violation that a testbench should notice, and
`severity failure` for something that must kill the run (see `p_unimplemented` in `write.vhd`).
Prefix the message with the module name.

## 6. Comments

* Sentence case, full sentences, one space after a period.
* Use `--` surrounded by spaces as an em-dash in prose (` -- like this -- `), not a single `-`.
* Comment the **why**, not the what. Several comments in this repo record a measurement or a
  rejected alternative (`is_crb` in `write.vhd`, the `TRIED AND REJECTED` block in
  `registers.vhd`, the `null` arms in `alu_data.vhd`). That is the house style for anything whose
  obvious "simplification" would break the design — write down what was measured, so the next
  person does not have to re-measure it.
* Mark unfinished work with `TBD:` and say what "done" would look like.

## 7. Formal verification

A formally-verified module has a `formal/<name>.psl` + `<name>.sby` + `<name>.gtkw` triplet.
When you touch RTL that has PSL, re-run it (`cd formal && sby --yosys "yosys -m ghdl" -f <name>.sby`)
— several properties in this repo hold only because of non-obvious interactions. See
[CLAUDE.md](CLAUDE.md#formal-verification).

## Known deviations

The rules above describe the majority style. These files currently differ; fixing them is
low-risk, cosmetic work, best done a file at a time.

| Deviation | Files |
|---|---|
| Implicit `std_logic` condition (`if x then`) | `debug.vhd:44,49` |
| Unused numeric import | `test/wb_dp_mem.vhd` |
| Colons aligned across the whole declarative region | `cpu.vhd` |
| Generic declarations not colon-aligned | `test/system.vhd`, `test/tb_cpu.vhd` |
| `end cpu_constants;` instead of `end package cpu_constants;` | `cpu_constants.vhd` (both package and body) |
| No trailing blank line after `end architecture` | `test/test_monitor.vhd` |
