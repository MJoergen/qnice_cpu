library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;
use std.textio.all;

-- A dual-port RAM with a single clock, optionally initialised from a text
-- file. Port A reads; port B reads and writes.
--
-- THEORY OF OPERATION
-- The memory is an ordinary signal with exactly ONE driver, because only port
-- B writes it. Each port has its own process; port A's merely reads, and reads
-- create no driver.
--
-- WHY PORT A DOES NOT WRITE
-- The vendor template for a RAM whose two ports can BOTH write is two
-- processes over a "shared variable". That is not legal VHDL-2008 -- the LRM
-- requires a shared variable to be of a protected type, and a protected type
-- is not synthesisable -- so it compiles only under GHDL's -frelaxed. Nor can
-- the two writes simply be merged into one process: Vivado refuses to infer a
-- RAM from that ("RAM has multiple writes via different ports in same process.
-- If RAM inferencing intended, write to one port per process", Synth 8-4767),
-- and falls back to 131072 flip-flops. There is no LRM-conformant VHDL that
-- Vivado will infer a two-writer RAM from.
--
-- Dropping the second writer costs nothing here. Port A carries the
-- instruction bus, which never wrote: test/system.vhd used to tie its write
-- enable to '0'. This is a Harvard machine -- the program arrives through
-- G_INIT_FILE, and self-modifying code stores over the data bus, which is
-- port B. See doc/README.md.
--
-- This file was called tdp_ram.vhd for as long as it had two write ports, "t"
-- for TRUE dual-port. It no longer does, hence the rename. "mem" rather than
-- "ram" because src/sub/dp_ram.vhd already owns that entity name in the same
-- library; that one is the register file's 1-write/1-read primitive, this one
-- is the testbench memory model.
--
-- READ/WRITE ORDERING (read-first, on both ports)
-- Signal assignment schedules the write for the end of the delta cycle, so a
-- read and the write in the same cycle -- on port B itself, or on port A
-- against port B -- returns the OLD contents; the freshly written value is
-- observable from the next read. This matches src/sub/dp_ram.vhd and the BRAM
-- primitive's READ_FIRST mode. It also matches what the shared-variable
-- version happened to do, whose cross-port ordering was formally undefined
-- because the LRM does not order two processes against each other.
--
-- RESET
-- None. Memory contents come from G_INIT_FILE (or zero) and are not reset by
-- rst_i. rst_i is unused and kept only for interface uniformity.
--
-- GENERICS
--   G_INIT_FILE : text file of one binary word per line; "" leaves memory zero.
--   G_RAM_STYLE : passed through to the synthesiser's ram_style attribute.
--   G_ADDR_SIZE : address width; memory depth is 2**G_ADDR_SIZE words.
--   G_DATA_SIZE : data word width in bits.

entity dp_mem is
   generic (
      G_INIT_FILE : string := "";
      G_RAM_STYLE : string := "block";
      G_ADDR_SIZE : integer;
      G_DATA_SIZE : integer
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;                                   -- unused (see header)
      -- Port A: read only
      a_addr_i    : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      a_rd_data_o : out std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0');
      -- Port B: read and write
      b_addr_i    : in  std_logic_vector(G_ADDR_SIZE-1 downto 0);
      b_wr_en_i   : in  std_logic;
      b_wr_data_i : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      b_rd_data_o : out std_logic_vector(G_DATA_SIZE-1 downto 0) := (others => '0')
   );
end entity dp_mem;

architecture synthesis of dp_mem is

   type t_ram is array (0 to 2**G_ADDR_SIZE-1) of std_logic_vector(G_DATA_SIZE-1 downto 0);

   -- This reads the ROM contents from a text file
   impure function init_ram_from_file(ram_file_name : in string) return t_ram is
      file     ram_file      : text;
      variable ram_file_line : line;
      variable ram           : t_ram := (others => (others => '0'));
   begin
      if ram_file_name /= "" then
         file_open(ram_file, ram_file_name, read_mode);
         for i in t_ram'range loop
            readline(ram_file, ram_file_line);
            read(ram_file_line, ram(i));
            if endfile(ram_file) then
               return ram;
            end if;
         end loop;
      end if;
      return ram;
   end function init_ram_from_file;

   -- Initial memory contents
   signal dp_mem_r : t_ram := init_ram_from_file(G_INIT_FILE);

   attribute ram_style : string;
   attribute ram_style of dp_mem_r : signal is G_RAM_STYLE;

begin

   p_a : process (clk_i)
   begin
      if rising_edge(clk_i) then
         a_rd_data_o <= dp_mem_r(to_integer(a_addr_i));
      end if;
   end process p_a;

   -- The sole driver of dp_mem_r; see THEORY OF OPERATION above.
   p_b : process (clk_i)
   begin
      if rising_edge(clk_i) then
         b_rd_data_o <= dp_mem_r(to_integer(b_addr_i));

         if b_wr_en_i = '1' then
            dp_mem_r(to_integer(b_addr_i)) <= b_wr_data_i;
         end if;
      end if;
   end process p_b;

end architecture synthesis;

