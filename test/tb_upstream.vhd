-- Differential test: the same programs, run on the UPSTREAM QNICE CPU.
--
-- This is what "make crosscheck_rtl" runs. Its sibling "make crosscheck" runs
-- each test program on QNICE-FPGA's C emulator and diffs the final contents of
-- RAM against what this repo's CPU left behind; this testbench does the same
-- with the other reference the upstream project ships, its own VHDL CPU
-- (vhdl/qnice_cpu.vhd, a multi-cycle FSM).
--
-- The two references are not redundant, because they disagree with each other.
-- Today in three places: the sign of the DIVS remainder and when the EAE
-- recomputes, where the emulator is the odd one out; and what R15 reads as
-- when it is an instruction's destination and its source was the immediate
-- @R15++, where the RTL is. Each is recorded in test/crosscheck.py's
-- KNOWN_DIVERGENCE against the reference it applies to.
--
-- The CPU under test here, and every module below it, is upstream's own source
-- at the commit pinned in the Makefile, extracted into a work directory; none
-- of it is committed to this repository. One file is patched, the register
-- file, by test/upstream.patch, whose header gives every reason -- two so that
-- it simulates under GHDL at all, one so that it powers up in the same
-- architectural state the other two implementations do. What IS ours is this
-- file: the system around that CPU.
--
--
-- THE SYSTEM
--
-- Deliberately the smallest one the test programs need, and NOT upstream's
-- vhdl/hw/*/env1.vhd. That would have brought in mmio_mux, the UART, the VGA
-- and the keyboard, and with them a memory map this repo's programs are not
-- written for: upstream puts ROM at 0x0000-0x7FFF and RAM at 0x8000, while
-- every program in test/ is linked at 0x0000 and stores its results there.
-- So the system here is one writable 32 kW RAM over 0x0000-0x7FFF, the EAE at
-- the addresses the programs already use, and nothing else.
--
-- The RAM is modelled on upstream's own vhdl/block_ram.vhd rather than on
-- src/sub/dp_ram.vhd, because it is upstream's CPU that has to be satisfied
-- here: read and write on the FALLING clock edge (the CPU's FSM drives its
-- control signals on rising edges, so the falling edge is when they have
-- settled), a chip enable that forces the output to zero, and a zero output
-- while writing so that the bus can be a wired OR. WAIT_FOR_DATA is tied low
-- for the same reason it effectively is upstream: block_ram.vhd's "busy" is a
-- constant '0', and mmio_mux derives the CPU's wait signal from nothing else
-- that this system contains.
--
-- The one thing block_ram.vhd cannot do is start from a program, so the array
-- here is initialised from G_ROM, in the same one-binary-word-per-line format
-- src/sub/dp_ram.vhd reads. That is the same test/<prog>.rom file the ordinary
-- simulation uses; nothing is assembled twice.
--
--
-- THE VERDICT, AND WHY THE STATUS WORD IS SEEDED
--
-- At HALT the whole RAM is written to G_DUMP_FILE as "0xADDR 0xVALUE" lines --
-- the format the emulator's SAVE command produces and test/crosscheck.py
-- already reads, so the comparison is the same code for both references.
--
-- Before that, G_STATUS_ADDR is seeded with G_STATUS_SEED as the memory is
-- loaded. A program that FAILS on this CPU halts early, at one of its failure
-- HALTs, without ever writing its status word -- and an unwritten 0x7FFF reads
-- as 0x0000, which is exactly what a passing run writes there. Without the
-- seed such a run is indistinguishable from a pass. crosscheck.py owns the
-- sentinel value and passes it in, so that the two references cannot drift
-- apart on it.
--
--
--
-- THE WRITE LOG
--
-- G_WRITES_FILE, when set, gets every register and memory write this CPU
-- retires, in src/debug.vhd's format. It has two jobs.
--
-- The first is diagnosis. Before it existed, a divergence gave a final-memory
-- diff and nothing else: the R15 divergence in test/prog_r15.asm had to be
-- traced by hand, from the halt address back into upstream's cs_decode. This
-- is not something to "diff -u" against this repo's own log -- a four-stage
-- pipeline and a multi-cycle FSM interleave their register and memory writes
-- quite differently, and neither order is wrong -- it is a readable trace of
-- what the reference did, in the same vocabulary.
--
-- The second is that test/crosscheck.py replays it to reconstruct the final
-- register file, which is the half of the architectural state the memory dump
-- cannot reach. R0-R12 come off the register file's write port, with the bank
-- off sel_rbank; R13 is watched for change instead, because upstream drives SP
-- from fsmSP every rising edge rather than through that port. R14 and R15 are
-- deliberately absent: the SR is flags, which the two implementations are not
-- required to agree on, and upstream's R15 is a real program counter where
-- this CPU's register-file copy is written only by branches. crosscheck.py
-- compares R0-R13 for exactly that reason.
--
-- The register-file signals are reached by VHDL-2008 external names, since
-- they are internal to the CPU under test. They name PORTS of the register
-- file instance rather than signals inside its architecture -- still
-- upstream's identifiers, but the ones its own entity declares -- and if a
-- later QNICE_REF renames one, elaboration fails and says which. That is the
-- alternative to patching a diagnostic window into upstream's source, which
-- would be the wrong trade for the same reason test/upstream.patch is kept to
-- three hunks.
--
--
-- CYCLE COUNTS
--
-- Reported per run and checked against nothing. This CPU takes four to eleven
-- cycles per instruction where the pipelined one averages close to one, so
-- every program takes noticeably longer here: prog.asm costs it 22333 cycles
-- against 15581, and prog_mandel_perf.asm 281583 against 170041. The golden
-- .stats files are what hold this repo's CPU to its own numbers; this is just
-- the other implementation's, for scale.

library ieee;
   use ieee.numeric_std.all;
   use ieee.std_logic_1164.all;

   use std.env.all;
   use std.textio.all;

entity tb_upstream is
   generic (
      -- The test program, as one binary word per line (test/<prog>.rom).
      G_ROM         : string;
      -- Where to write the final contents of RAM, as "0xADDR 0xVALUE" lines.
      G_DUMP_FILE   : string;
      -- Where to log every register and memory write, in src/debug.vhd's
      -- format. An empty string (the default) disables the logging entirely.
      -- See the header.
      G_WRITES_FILE : string := "";
      -- The reserved status word, and the value it is seeded with so that
      -- "never written" is distinguishable from "written as pass". Both are
      -- owned by test/crosscheck.py -- see the header.
      G_STATUS_ADDR : natural := 16#7FFF#;
      G_STATUS_SEED : natural := 16#DEAD#;
      -- A program that has not halted within this many clock cycles is
      -- considered hung. The longest program here, prog_mandel_perf.asm,
      -- retires its HALT after 281583 cycles, so this leaves about a factor of
      -- seven -- the same margin test/tb_cpu.vhd's watchdog leaves, and for the
      -- same reason: that program exists to measure performance, so a slowdown
      -- is what it is expected to show. Cycles rather than time, so that it can
      -- be overridden from the ghdl command line.
      G_TIMEOUT     : natural := 2000000
   );
end entity tb_upstream;

architecture simulation of tb_upstream is

   constant C_RAM_ADDR_BITS : natural := 15;

   type t_mem is array (0 to 2 ** C_RAM_ADDR_BITS - 1) of std_logic_vector(15 downto 0);

   -- Initial memory contents: the program, with the status word seeded. A
   -- short file leaves the remaining words at zero.
   impure function init_ram (file_name : string) return t_mem is
      file     init_file : text;
      variable init_line : line;
      variable mem       : t_mem := (others => (others => '0'));
   begin
      if file_name /= "" then
         file_open(init_file, file_name, read_mode);

         for i in t_mem'range loop
            readline(init_file, init_line);
            read(init_line, mem(i));
            if endfile(init_file) then
               exit;
            end if;
         end loop;

      end if;
      mem(G_STATUS_ADDR) := std_logic_vector(to_unsigned(G_STATUS_SEED, 16));
      return mem;
   end function init_ram;

   signal clk : std_logic := '1';
   signal rst : std_logic := '1';

   signal cpu_addr       : std_logic_vector(15 downto 0);
   signal cpu_data_in    : std_logic_vector(15 downto 0);
   signal cpu_data_out   : std_logic_vector(15 downto 0);
   signal cpu_data_dir   : std_logic;
   signal cpu_data_valid : std_logic;
   signal cpu_halt       : std_logic;
   signal cpu_ins_cnt    : std_logic;
   signal cpu_igrant_n   : std_logic;

   signal ram      : t_mem := init_ram(G_ROM);
   signal ram_ce   : std_logic;
   signal ram_out  : std_logic_vector(15 downto 0) := (others => '0');
   signal ram_data : std_logic_vector(15 downto 0);

   signal eae_en   : std_logic;
   signal eae_we   : std_logic;
   signal eae_data : std_logic_vector(15 downto 0);

   -- Purely diagnostic: the address of the instruction being fetched, so that
   -- a failing run can report where it halted the way the emulator does.
   -- INS_CNT_STROBE is combinational and high during cs_fetch, which is the
   -- state in which ADDR carries the PC, so the two can simply be sampled
   -- together.
   signal inst_addr  : std_logic_vector(15 downto 0) := (others => '0');
   signal cycle_cnt  : natural                       := 0;
   signal inst_count : natural                       := 0;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 5 ns;
      wait for 10 ns; -- 100 MHz
   end process p_clk;

   p_rst : process
   begin
      rst <= '1';
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';
      wait;
   end process p_rst;

   ---------------------------------------------------------------------------
   -- The CPU under test: upstream's, unmodified.
   ---------------------------------------------------------------------------

   i_qnice_cpu : entity work.qnice_cpu
      port map (
         clk            => clk,
         reset          => rst,
         wait_for_data  => '0',
         addr           => cpu_addr,
         data_in        => cpu_data_in,
         data_out       => cpu_data_out,
         data_dir       => cpu_data_dir,
         data_valid     => cpu_data_valid,
         halt           => cpu_halt,
         ins_cnt_strobe => cpu_ins_cnt,
         int_n          => '1',
         igrant_n       => cpu_igrant_n
      );

   ---------------------------------------------------------------------------
   -- The bus: a wired OR of every slave, each of which drives zero unless
   -- selected. This is upstream's convention, not ours -- see vhdl/sim/dev_int.vhd.
   ---------------------------------------------------------------------------

   cpu_data_in <= ram_data or eae_data;

   ---------------------------------------------------------------------------
   -- RAM, 0x0000-0x7FFF. Modelled on upstream's vhdl/block_ram.vhd; see the
   -- header for why it is that model rather than src/sub/dp_ram.vhd.
   ---------------------------------------------------------------------------

   ram_ce <= not cpu_addr(15);

   p_ram : process (clk)
      variable addr_v : natural range 0 to 2 ** C_RAM_ADDR_BITS - 1;
   begin
      if falling_edge(clk) then
         addr_v := to_integer(unsigned(cpu_addr(C_RAM_ADDR_BITS - 1 downto 0)));
         if ram_ce = '1' and cpu_data_dir = '1' then
            ram(addr_v) <= cpu_data_out;
         end if;
         if ram_ce = '1' then
            ram_out <= ram(addr_v);
         else
            ram_out <= (others => '0');
         end if;
      end if;
   end process p_ram;

   -- Zero while not selected, and zero while writing, so that the wired OR
   -- above sees nothing from a slave that is not answering a read.
   ram_data <= (others => '0') when ram_ce = '0' or cpu_data_dir = '1' else
               ram_out;

   ---------------------------------------------------------------------------
   -- EAE, 0xFF18-0xFF1F. Upstream's own device, and upstream's own decode
   -- (vhdl/mmio_mux.vhd's "Block FF18"), so that the aliasing every 8 words
   -- matches. This repo's test/eae.vhd is a Wishbone adaptation of the same
   -- device; comparing the two is part of the point of this testbench.
   ---------------------------------------------------------------------------

   eae_en <= '1' when cpu_addr(15 downto 3) = "1111111100011" else
             '0';
   eae_we <= eae_en and cpu_data_dir and cpu_data_valid;

   i_eae : entity work.eae
      port map (
         clk      => clk,
         reset    => rst,
         en       => eae_en,
         we       => eae_we,
         reg      => cpu_addr(2 downto 0),
         data_in  => cpu_data_out,
         data_out => eae_data
      );

   ---------------------------------------------------------------------------
   -- Diagnostics and the run's end.
   ---------------------------------------------------------------------------

   p_trace : process (clk)
   begin
      if rising_edge(clk) then
         if cpu_ins_cnt = '1' then
            inst_addr  <= cpu_addr;
            inst_count <= inst_count + 1;
         end if;
         if rst = '0' and cpu_halt = '0' then
            cycle_cnt <= cycle_cnt + 1;
         end if;
      end if;
   end process p_trace;

   -- Every register and memory write, in src/debug.vhd's format. See the
   -- header: this is both the diagnostic trace and what test/crosscheck.py
   -- replays to reconstruct the final register file.
   --
   -- The edges are upstream's, not a choice: its register file writes R0-R12
   -- on the FALLING edge, which is also when the RAM above latches a store, so
   -- both are read there; SP moves on the rising edge. A store can hold
   -- DATA_DIR over more than one falling edge -- the RAM simply writes the same
   -- word again -- so a write is logged on the cycle DATA_DIR rises, giving one
   -- line per store rather than one per cycle.

   p_writes : process
      -- The register file's write port, and the bank it lands in. External
      -- names because these are internal to the CPU under test; see the header
      -- for why they name ports of the instance rather than signals inside it.
      -- They are declared HERE rather than with the architecture's signals
      -- because an alias in that declarative part is elaborated before the
      -- instances are, and GHDL rejects it with "component instance
      -- i_qnice_cpu is not yet elaborated".
      alias up_wr_en   is << signal .tb_upstream.i_qnice_cpu.registers.write_en : std_logic >>;
      alias up_wr_addr is
      << signal .tb_upstream.i_qnice_cpu.registers.write_addr : std_logic_vector(3 downto 0) >>;
      alias up_wr_data is
      << signal .tb_upstream.i_qnice_cpu.registers.write_data : std_logic_vector(15 downto 0) >>;
      alias up_bank    is
      << signal .tb_upstream.i_qnice_cpu.registers.sel_rbank : std_logic_vector(7 downto 0) >>;
      alias up_sp      is
      << signal .tb_upstream.i_qnice_cpu.registers.sp : std_logic_vector(15 downto 0) >>;

      file     write_file : text;
      variable write_line : line;
      variable sp_v       : std_logic_vector(15 downto 0) := (others => '0');
      variable dir_v      : std_logic                     := '0';
   begin
      if G_WRITES_FILE = "" then
         wait;
      end if;

      file_open(write_file, G_WRITES_FILE, write_mode);
      wait until rst = '0';
      sp_v := up_sp;

      main_loop : loop
         wait on clk;

         if falling_edge(clk) then
            -- R0-R12. R13 is watched below, R14 and R15 are deliberately not
            -- logged at all -- see the header.
            if up_wr_en = '1' and up_wr_addr /= X"D"
               and up_wr_addr /= X"E" and up_wr_addr /= X"F" then
               write(write_line, "Write value 0x" & to_hstring(up_wr_data)
                     & " to register " & to_hstring(up_wr_addr));
               if up_wr_addr(3) = '0' then
                  write(write_line, " bank 0x" & to_hstring(up_bank));
               end if;
               writeline(write_file, write_line);
            end if;

            if ram_ce = '1' and cpu_data_dir = '1' and dir_v = '0' then
               write(write_line, "Write value 0x" & to_hstring(cpu_data_out)
                     & " to memory 0x" & to_hstring(cpu_addr));
               writeline(write_file, write_line);
            end if;
            dir_v := cpu_data_dir;
         end if;

         if rising_edge(clk) and up_sp /= sp_v then
            write(write_line, "Write value 0x" & to_hstring(up_sp) & " to register D");
            writeline(write_file, write_line);
            sp_v := up_sp;
         end if;
      end loop main_loop;

      file_close(write_file);
   end process p_writes;

   -- Dump the whole of RAM at HALT and end the simulation. Unlike
   -- test/test_monitor.vhd this does not judge the run: the status word is
   -- part of the dump, and test/crosscheck.py reads it from there together
   -- with everything else.
   p_dump : process
      file     dump_file : text;
      variable dump_line : line;
   begin
      wait until rising_edge(clk) and cpu_halt = '1';

      -- The last store retires before the HALT does, and lands on the
      -- following falling edge; give it one.
      wait until rising_edge(clk);

      file_open(dump_file, G_DUMP_FILE, write_mode);

      for i in t_mem'range loop
         write(dump_line, string'("0x") & to_hstring(std_logic_vector(to_unsigned(i, 16)))
               & " 0x" & to_hstring(ram(i)));
         writeline(dump_file, dump_line);
      end loop;

      file_close(dump_file);

      report "HALT at 0x" & to_hstring(inst_addr) &
             " after " & integer'image(cycle_cnt) & " cycles, " &
             integer'image(inst_count) & " instructions";
      finish(0);
   end process p_dump;

   p_timeout : process
   begin
      for i in 1 to G_TIMEOUT loop
         wait until rising_edge(clk);
      end loop;

      report "TIMEOUT: no HALT within " & integer'image(G_TIMEOUT) & " cycles";
      stop(1);
      wait;
   end process p_timeout;

end architecture simulation;
