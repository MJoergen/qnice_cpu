# Formal verification

Guidance for Claude Code when working in `formal/`. Claude Code loads this file on demand,
when it touches a file in this directory; the repository-wide rules stay in the top-level
[CLAUDE.md](../CLAUDE.md). Per-module property notes live in each module's README, and the bypass
trap that BMC reports as a non-bug is in [src/registers/CLAUDE.md](../src/registers/CLAUDE.md).

`make formal` runs `make -C formal`, which uses SymbiYosys (`sby`) with the GHDL plugin to
check the modules listed in the `DUTS` variable at the top of
[formal/Makefile](Makefile). CI runs it too, in its own workflow
[.github/workflows/formal.yml](../.github/workflows/formal.yml), taking the whole toolchain from a
pinned OSS CAD Suite release and using `make -C formal -k` so one failing DUT does not hide the
rest. All thirteen DUTs are currently enabled and **the whole suite
passes** (39 tasks); if you want to narrow scope while iterating, comment lines out there — but
put them back. Twelve of the DUTs are CPU modules under `src/`; `wb_mux` is the exception, a
testbench component under `test/`, verified because the CPU's correctness depends on it keeping
responses in order. The Makefile tracks each job with a `<dut>.stamp` file whose prerequisites are read
from that job's own `[files]` section, so `make` re-runs exactly the jobs whose `.sby`, `.psl`, or
VHDL sources changed, and nothing otherwise. A stamp exists only if that job's last run passed
(the recipe deletes it before invoking `sby`), so a failure is always retried. Note `make` still
stops at the first failing job — pass `-k` to attempt the whole suite. To run/inspect a single
module directly:

```
cd formal
sby --yosys "yosys -m ghdl" -f memory.sby          # e.g. run just the memory module
gtkwave memory_bmc/engine_0/trace.vcd memory.gtkw  # inspect a failing counterexample trace
```

Each module has a matching `<name>.psl` (PSL assertions/assumptions, usually embedded as VHDL
comments inside or alongside the `.vhd` file), a `<name>.sby` (SymbiYosys job config: bmc/cover
tasks, file list, top-level generics), and a `<name>.gtkw` (GTKWave save file for viewing
counterexamples). When adding formal properties to a new module, follow this same
`.psl` + `.sby` + `.gtkw` triplet pattern next to the existing ones in `formal/`.

`make -C formal` finishes by running `formal/check_gtkw.py`, which verifies that every signal
named in a `.gtkw` still exists — against the **traces** a run leaves behind, not against the
source, since the VCD is what GTKWave is actually handed and it spells a record element
`stage<field>` where the VHDL says `stage.field`. This exists because a save file is the one
artifact here that nothing else reads: it is not compiled, not linted, and not an input to any
`sby` job, and GTKWave drops an unresolvable row without saying so, which reads as a broken tool
rather than a stale file. Six of the nine save files predating the check had rotted against RTL
renames, 161 dead names between them. CI runs the script as a step of its own (`if: always()`),
because the make target hangs off the stamps and `-k` would skip it on exactly the red build where
someone wants a trace.
