# Progress Log

Running context for this project. Read this first at the start of a session to
know where things stand. Update it at the end of any session that changed
meaningful state.

**Repo:** https://github.com/RodeanAzari/riscv-rv32i-tmr-core (private)
**Local:** `~/riscv-rv32i-tmr-core`
**Phase:** A — working core (branches and jumps done; RVFI port next)

---

## Where things stand

**Position: Phase A, all five pipeline stages built.** The core executes
straight-line programs end to end: results write back to the register file in
WB, and loads and stores go through an external, BRAM-timed data memory port.
The temporary `wb_rd_*_i` testbench port is gone; tests set registers by
executing instructions.

Working today: **37 of the 40 RV32I instructions** — every ALU instruction,
`lui`, `auipc`, all eight loads and stores, all six branches, `jal` and
`jalr` — with full data-hazard handling (EX/MEM→EX and MEM/WB→EX forwarding,
WB→ID through the register file, a one-cycle load-use stall) and branches
resolved in EX with static not-taken prediction: a taken branch or jump
flushes IF/ID and ID/EX and costs two cycles, not taken costs none. FENCE,
ECALL and EBREAK decode **inert** (`rd_we = 0`, no memory access, no
redirect).

**Timing margin is now gone: +0.059 ns at 100 MHz out-of-context**, and the
paths that cross the memory ports are not yet timed at all. The critical path
is branch resolution ending in the ID/EX flush. See the synthesis trend notes;
the two levers are in Next up.

Both memories are now BRAM-timed in the testbench as well as in the design.
The IF timing bug found during MEM + WB is fixed — see Decisions.

Everything is committed but **not yet pushed** — the MEM + WB, IF-fix,
forwarding and branch commits are local only (`git push` to sync, and CI runs on push). `make lint`, `make sim` and
`make synth` all pass from a clean checkout.

### Working and verified

| Check | Result |
|---|---|
| `make lint` | clean, Verilator 5.050 |
| `make sim` | 113/113 passing across 7 toplevels (core, alu, regfile, decoder, mem_align, hazard, branch) |
| `make synth` | routes clean, 0 errors, ~40 s |
| CI on push | green (lint + sim) |

### Implemented

`rtl/core/riscv_core.sv` — IF (PC, fetch, IF/ID), ID (decoder, register file,
ID/EX), EX (operand selection, ALU, EX/MEM), MEM (DMEM port, store alignment,
MEM/WB) and WB (load alignment, writeback mux).

- PC resets to `0x0000_0000`, advances `pc + 4`
- **Synchronous, active-high `rst_i`** per CLAUDE.md §4 — flops map to FDRE/FDSE
  on their dedicated SR pin, with no inverter and no async recovery/removal arc
- IMEM is an **external port**, synchronous read, 1-cycle latency — matches
  BRAM timing on the Arty A7 so Phase D bring-up needs no rewrite. The core
  presents **`pc_next`** (the reset vector during reset), so the BRAM and the
  pc register latch the same address on the same edge
- IF/ID resets to a NOP (`0x0000_0013`) so ID never sees X on cycle one
  (heads off the X-propagation failure mode in CLAUDE.md §9)
- `if_id_pc_o` / `if_id_instr_o` / `id_ex_*` exposed as outputs for ILA probing
  later, and carrying the RVFI shadow fields — see [rvfi-plan.md](rvfi-plan.md)
- **DMEM is an external port** — word-aligned address straight off the EX/MEM
  register, byte strobes, synchronous read. Load data arrives in WB and is
  **not** re-registered in MEM/WB: the BRAM's output register already is that
  pipeline register for it
- WB's register write is exposed as `wb_rd_*_o` **outputs** — what the tests
  observe, and `rvfi_rd_addr`/`rvfi_rd_wdata` in waiting
- **Branches and jumps resolve in EX.** `redirect` (a jump, or a branch whose
  condition holds) puts `redirect_target` on `pc_next`, so the pc and the BRAM
  take the target on the same edge, and loads NOPs into IF/ID and ID/EX — the
  two younger words already fetched. Redirect outranks stall in the `pc_next`
  mux, though the two cannot coincide (see Decisions). The target is a
  dedicated adder, `(jalr ? rs1 : pc) + imm` on the **forwarded** rs1, with
  bits [1:0] masked off. A jump's link address `pc + 4` replaces the ALU
  result going into EX/MEM, so it forwards like any other result

`rtl/core/riscv_decoder.sv` — register addresses, all five RV32I immediate
formats (I/S/B/U/J), the EX control signals, `branch`/`jump`/`jalr`, and
`mem_read`/`mem_write`/`mem_funct3`. `mem_funct3` is `instr[14:12]`
unconditionally, so it also carries a branch's condition. `mem_read` remains
the only writeback select: a jump's link address enters in EX, not WB.

`rtl/core/riscv_branch.sv` — the branch condition from funct3 and the two
forwarded operands. One magnitude comparison serves BLT and BLTU: when the sign
bits agree, signed and unsigned order are the same; when they differ, the
operand with its sign bit set is smaller. Reserved funct3 010/011 never take.

`rtl/core/riscv_hazard.sv` — forwarding selects for EX and load-use detection
for ID, purely combinational. Selects are one-hot per operand with priority
already resolved (EX/MEM beats MEM/WB: the younger write), so the core holds
no second copy of an encoding. Writes to x0 are never forwarded. The stall
compares the rs1/rs2 **fields** whether or not the instruction uses them — a
false match costs a cycle, never correctness. In the core, a stall holds the
pc and IF/ID (the pc mux re-presents `pc`, so the BRAM re-reads the word it
holds) and loads a NOP-decode bubble into ID/EX. Store data in EX/MEM is the
**forwarded** rs2.

`rtl/core/riscv_mem_align.sv` — byte lanes for both directions: stores
replicate data across lanes and raise strobes; loads pick the lane and sign- or
zero-extend. One module so the little-endian lane convention lives in one
place. Implements the misalignment assumption (see Decisions).

`rtl/core/riscv_alu.sv` — the ten RV32I arithmetic/logic operations. Selected by
the ISA's own `funct3` plus the ADD/SUB and SRL/SRA "alt" bit rather than a
private enum, so there is no second copy of an encoding to drift, and no
SystemVerilog package — which CLAUDE.md §4 flags as a Yosys risk that cannot be
verified until SymbiYosys is installed in Phase B.

`rtl/core/riscv_regfile.sv` — 32 x 32, two read ports, one write port.
**No reset on the array, deliberately**, and the synthesis report confirms why:
it inferred RAMD32/RAMS32 distributed RAM (44 LUTs), not the 992 flops a reset
would have forced. x0 invariance and WB→ID write-first forwarding are both
implemented here rather than in the surrounding pipeline, because both are
formal properties in CLAUDE.md §5.5.

`tb/cocotb/` — 113 tests across seven toplevels: `test_core` (52), `test_alu`
(16), `test_regfile` (8), `test_decoder` (29), `test_mem_align` (4, each an
exhaustive sweep), `test_hazard` (2; one sweeps all 17,496 input combinations
over x0–x2), `test_branch` (2: corner pairs, and random pairs that are equal,
one apart or opposite in sign, against a reference using Python's own signed
compare rather than the RTL's sign-bit shortcut). In `test_core` **both** memories are BRAM-timed models that
sample 1 ns before each rising edge, like a flop's setup window. `feed()`
writes an instruction at the address being fetched, and `feed_to()` walks it to
a named pipeline register, so no test hand-counts the fetch latency. `feed()`
assumes no stall — a stall re-presents the same address, and feed() would
overwrite it — so anything with a load-use pair goes through `run()`, whose
`timed=True` records the cycle each instruction retires. That is how the
load-use tests prove the stall costs **exactly** one cycle, and that a load
followed by an unrelated instruction, or a load to x0, costs none — and how
the branch tests prove a taken branch costs exactly two and a not-taken one
none. `run(cycles=n)` lifts the default budget for programs with backward
branches. Tests that depend on forwarding preset the registers first: the
register file has no reset, so a stale value could otherwise happen to equal
the forwarded one and pass vacuously.

`tb/cocotb/rv32i_model.py` — the golden model (CLAUDE.md §11): one instruction
at a time, no pipeline, written from the ISA spec. It follows one design
decision rather than the spec — the misalignment rule, for data and for jump
targets — and raises on everything not yet implemented rather than guessing.
Its B- and J-immediate decode was checked against **GNU `as`**, an encoder
independent of anything written here: 211 instructions, every single-bit
offset and both extremes, plus the test encoders `enc_b`/`enc_jal`/`enc_jalr`
bit for bit. `test_core` runs random
programs over x0–x4 against it, comparing **retirement order** (not just final
state, which a dropped or doubled instruction can survive) and final memory:
120 instructions padded (validates the model), 400 dense (finds hazards).
Random branches and jumps go **forward only**, 1–6 words, so every program
terminates; offset 2 skips exactly the word in IF/ID. Each run asserts a floor
on taken redirects (5 padded, 20 dense, against measured minimums of 8 and 35
over 200 seeds) so a generator that stops branching fails rather than passing
vacuously. `SEED=n` reruns a seed; seeds 1–20 pass.

Submodules get their own toplevel rather than being
poked through the core's hierarchy, so a unit test survives refactoring and can
drive ports the core does not expose.

`scripts/setup-vivado-env.sh`, `constr/core_ooc.xdc`, `syn/synth_ooc.tcl` —
out-of-context synthesis and implementation of the core alone, no board-level
top yet. Runs through `route_design` because post-synthesis timing is an
estimate and post-route is measured.

### Not started

FENCE / ECALL / EBREAK, the RVFI port itself, the official `riscv-tests`
suite, formal, UVM, TMR, hardware bring-up, and all of Stage 2.

**Instructions not yet implemented decode inert** (`rd_we = 0`) rather than
half-working. A branch or load that wrote a plausible-looking value would later
surface as a riscv-formal mismatch that reads like a forwarding bug, sending the
hunt to the wrong part of the design.

---

## Synthesis trend

**This table is the one append-only thing in this file.** Everything else here
is a snapshot of current reality; this is deliberately history, because the
whole point is the deltas. Never rewrite a past row — if an old number turns
out to be wrong, add a row saying so.

Add a row after every RTL slice lands. `make synth`, then copy the numbers
straight out of `docs/reports/summary_ooc.txt` — do not retype them from
memory or from the terminal scrollback.

All rows out-of-context on `xc7a100tcsg324-1`, constrained at 10.000 ns
(100 MHz, the Arty's oscillator), unless a row says otherwise.

| Date | Slice | LUT | FF | CARRY4 | WNS (ns) | Fmax (MHz) | Δ Fmax |
|---|---|---|---|---|---|---|---|
| 2026-09-05 | PC + IF (43 lines) | 2 | 92 | 8 | +7.338 | 375.7 | — (baseline) |
| 2026-09-17 | Sync-high reset + `_i`/`_o` ports | 1 | 92 | 8 | +7.338 | 375.7 | 0.0 |
| 2026-09-17 | ID: decode + regfile + ID/EX | 108 | 249 | 8 | +6.029 | 251.8 | −123.9 |
| 2026-09-17 | EX: ALU + operand sel + EX/MEM | 592 | 352 | 24 | +3.095 | 144.8 | −107.0 |
| 2026-10-07 | MEM + WB: DMEM port, lane align, MEM/WB, writeback | 682 | 484 | 24 | +2.696 | 136.9 | −7.9 |
| 2026-10-07 | IF fix: IMEM driven from `pc_next` | 712 | 489 | 24 | +2.846 | 139.8 | +2.9 |
| 2026-10-07 | Forwarding + load-use stall (hazard unit) | 818 | 489 | 24 | +0.942 | 110.4 | −29.4 |
| 2026-10-07 | Branches + JAL/JALR: comparator, target adder, flush | 963 | 492 | 47 | +0.059 | 100.6 | −9.8 |

Device totals for the percentages: 63,400 LUT / 126,800 FF / 135 BRAM /
240 DSP.

### Reading these numbers

**Fmax here is not a board number.** Out-of-context leaves `HD.CLK_SRC` unset,
so Vivado cannot estimate clock delay or skew. Read it as the core's logic
limit. A real board number arrives with the Arty A7 top, and when it does it
gets its own table rather than being mixed into this one — measurement
conditions travel with the measurement or the measurement is worthless.

The FF count doubles as a correctness check on the flow. The RTL has 3 x 32 =
96 registers; 4 constant-fold away because `pc[1:0]` and `if_id_pc_o[1:0]` are
always zero on a `pc + 4` increment. 92 is right, and the tools proving they
understood the design is a good sign the flow is wired up correctly.

Expect Fmax to fall sharply once there is an ALU. **That fall is the data.**
A single number at the end of the project is a claim; a table showing what each
pipeline stage cost in MHz and LUTs is evidence of engineering. It also
localises regressions — if Fmax halves, the row tells you which slice did it,
instead of bisecting months of commits.

The MEM + WB row: **the critical path did not move.** It is still
`id_ex_a_sel_zero` → ALU carry chain → `ex_mem_alu_result_o[31]`, 12 levels,
61% route. The −7.9 MHz is the same EX path routing worse among ~90 more LUTs,
not a new path through MEM or WB. The FF count reconciles exactly: the RTL adds
148 flops (ID/EX +5, EX/MEM +37, MEM/WB +106); 2 constant-fold
(`mem_wb_pc_o[1:0]`), and Vivado merges 14 pairs of flops that always hold the
same bit — `mem_funct3` equals `instr[14:12]` in three stages, and
`mem_wb_rd_addr` equals `instr[11:7]`. 352 + 148 − 16 = 484. Checked in the
routed netlist, not assumed: `mem_wb_instr_o` keeps 29 flops (its funct3 bits
merged into `mem_wb_mem_funct3`), and `mem_wb_rd_addr` keeps none.

The IF-fix row: **+30 LUTs** is the reset gating on `imem_addr_o`, one LUT for
each of the 30 bits that are not constant zero. **+5 FFs** is `pc[1]`, which no
longer constant-folds in any of the five PC registers (seen in the routed
netlist: each holds bits 31:1). It is always zero, and before this change
Vivado knew it; the cause is not established. The +2.9 MHz is placement
variation, not an improvement.

**The fix moved logic onto a path this table cannot see.** `imem_addr_o` now
comes out of the `pc + 4` adder rather than straight off a flop, and the
out-of-context constraints set no output delays, so the path from the pc
register through the adder to the BRAM address pins is **untimed** here. It
gets timed when the board-level top puts a real BRAM on the other end — see
Next up.

The forwarding row is the largest single-feature cost so far, and the shape
of the critical path is the textbook one: `ex_mem_rd_we` → hazard comparator →
`fwd_rs2_ex_mem` (fanout 32) → forwarding mux → `alu_b[2]` (fanout 115, the
shifter's shift amount) → `ex_mem_alu_result[26]`. A loop from EX/MEM back to
EX/MEM with the forwarding **decision** in series ahead of the ALU; 79% of it
is routing. **Not acted on yet**, recorded as an option: compute the selects
one stage early — compare ID's rs1/rs2 against ID/EX's and EX/MEM's rd — and
register them into ID/EX, so in EX they come straight off flops. FF count is
unchanged because the stall uses clock enables and the bubble reuses the reset
values.

The branch row: **the critical path moved to branch resolution, and it ends
in the flush.** `mem_wb` rd → hazard comparator (fo 99) → forward select
(fo 54) → forwarding mux → the comparator's `ltu` carry chain (4 CARRY4) →
`redirect` (fo 33) → the synchronous reset pins of ID/EX, fanout **171**. 11
levels, 77% routing. The forwarding decision is still in series at the front,
so registering the selects in ID still helps; the new lever is the back end
(Next up). FF +3 is exactly `id_ex_branch`/`jump`/`jalr`. CARRY4 +23 is the
three new carry structures: the target adder, the `pc + 4` link adder, and
the comparator.

**The out-of-context slack is optimistic, now +0.059 ns.** Three
paths that matter on the board cross the core's ports and are untimed here:
`pc + 4` / stall mux → `imem_addr_o`, the stall comparator and now the whole
branch-resolution path → `imem_addr_o`, and
`dmem_rdata_i` → load alignment → writeback mux → forwarding mux → ALU — the
last one starts at a BRAM clock-to-out of roughly 2 ns on Artix-7. The board-
level run will say whether 100 MHz survives.

---

## Toolchain

| Tool | Version | Location |
|---|---|---|
| Verilator | 5.050 | `~/.local/bin/verilator` (built from source; tree at `~/.local/src/verilator`) |
| cocotb | 2.1.0 | `~/cocotb-env` |
| riscv gcc | 16.1.0 | `~/riscv-toolchain/bin/riscv32-unknown-elf-gcc` |
| spike | — | `~/riscv-toolchain/bin/spike` |
| gh CLI | 2.100.0 | `~/.local/bin/gh`, authed as RodeanAzari |
| **Vivado** | 2025.2 | `~/Xilinx/2025.2/Vivado` — ML Standard, no license file. Run `vivado-env` first |
| **yosys / SymbiYosys** | — | **not installed** — needed for Phase B, and for the ASIC flow's synthesis step |
| **OpenLane + Sky130** | — | **not installed** — needed closing Phase E (CLAUDE.md §6.4 run #1) |

`~/.local/bin` is first on PATH, so the source-built Verilator shadows the
Debian 5.032 package automatically.

### Environment gotchas

- **`sudo` cannot prompt for a password through Claude Code** (no TTY). Anything
  needing root must be run in a separate WSL terminal.
- **Vivado needs `libncurses.so.5`, which Ubuntu 26.04 does not package.**
  Symptom is nastier than a missing-library error: batch runs **hang at 0% CPU
  with no output** instead of failing. Fixed with compat symlinks onto
  ncurses 6 in `~/.local/lib/vivado-compat`, which `vivado-env` puts on
  `LD_LIBRARY_PATH`. Details in vivado-setup.md §3.
- **Vivado 2026.1 forced `LC_ALL=en_US.UTF-8`**, which Ubuntu does not
  generate, and crashed on launch. Worked around without root via `~/.locale`
  and `LOCPATH`. 2025.2 does not have this problem; the workaround is retained
  anyway since the other Xilinx binaries are unchecked.
- Debian's Verilator is 5.032, below cocotb 2.x's 5.036 floor. This is why
  Verilator was built from source both locally and in CI.

---

## Build targets

| Target | Does | State |
|---|---|---|
| `make lint` | Verilator lint of `rtl/` | working |
| `make sim` | cocotb regression | working |
| `make sw` | build `sw/**/*.c` → `.elf` / `.hex` | untested, no source yet |
| `make spike` | run `.elf` on spike | untested, no source yet |
| `make synth` | OOC synth + impl of the core, reports to `docs/reports/` | working |
| `make prog` | — | stub; blocked on USB passthrough (§6 of vivado-setup.md) |
| `make formal` / `uvm` / `impl` / `asic` | — | stubs that name their phase and what they wait on |

---

## CI

`.github/workflows/ci.yml`, single `verilate` job: builds Verilator 5.050 from
source, caches it on key `verilator-Linux-v5.050`, installs cocotb from
`tb/cocotb/requirements.txt`, then runs lint and sim. `make formal` joins this
job in Phase B — yosys and SymbiYosys install in minutes on a hosted runner.

First run took 11m53s (the compile). Cached runs should be under a minute.
The regression is now three elaborations (core, regfile, decoder) rather than
one; each gets its own build directory and results file.
Bumping `VERILATOR_VERSION` forces a rebuild.

**Not in CI:** synthesis. Vivado is large and slow; a self-hosted runner may be
the honest answer rather than pretending it fits on a hosted one.

---

## Decisions made, and why

- **`~/Xilinx` over `/tools/Xilinx`** for the pending Vivado install — avoids
  needing root, which is awkward here.
- **Never source `settings64.sh` in `.bashrc`** — it shadows system libraries
  and breaks `git`/`curl`. Use an opt-in `vivado-env` shell function.
  Details in [vivado-setup.md](vivado-setup.md).
- **IMEM external to the core** rather than an internal array — BRAM-shaped
  from the start.
- **Target part is `xc7a100tcsg324-1`** — the board is an **Arty A7-100T**
  (confirmed 2026-09-05). 63,400 LUTs / 126,800 FFs / 135 BRAM / 240 DSP; these
  are the denominators for every utilization percentage in the README. The
  100T's headroom matters for Phase E: three core copies plus a voter would be
  tight on a 35T's 20,800 LUTs.
- **Pinned to Vivado 2025.2, not the latest** (decided 2026-09-04). AMD made
  the free tier Windows-only in **2026.1** and put it on annual renewal; a
  Linux 2026.1 seat costs ~$1,200–$1,800/yr. Everything up to 2025.2 keeps
  Vivado ML Standard free on Linux with no license file. 2026.1 was installed
  first (63 GB) before this surfaced — `vlm` shows no free option on Linux,
  only a 60-day trial. The trial was rejected: it expires mid-Phase-D. Nothing
  in Phase D needs a 2026.1 feature.
- **Repo named `riscv-rv32i-tmr-core`** — puts the differentiator (TMR) in the
  name rather than burying it.
- **Private until there's something to show**, then flip:
  `gh repo edit --visibility public`.
- **Synchronous, active-high reset** (decided 2026-09-17). The core was written
  with async active-low `rst_n`; CLAUDE.md §4 requires sync active-high `rst`,
  so the RTL moved. Changed while the core was one file — reset convention is
  viral, and every module, testbench and the Phase E TMR wrapper inherits it.
  Confirmed in the synthesis report rather than assumed: the 92 flops went
  FDCE/FDPE (async clear/preset) → FDRE/FDSE (sync reset/set), and one of the
  two LUT1s disappeared with the active-low inverter. Zero timing cost — the
  critical path is the `pc + 4` carry chain, which reset style does not touch.
- **`_i`/`_o` suffixes on every port, clock and reset included** (2026-09-17).
  CLAUDE.md §4 mandates the suffixes and carves out no exception, and the
  convention it comes from (lowRISC/OpenTitan) suffixes `clk_i`/`rst_i` too.
  Done in the same session as the reset change for the same reason: the port
  list is one module long today. The **clock object stays named `clk`** while
  the port is `clk_i` — `syn/synth_ooc.tcl` finds it with `get_clocks clk` and
  every committed report identifies it that way, so a timing object should not
  be renamed whenever RTL naming conventions shift. Verified the constraint
  still binds: the timing report shows `clk` at 10.000 ns / 100 MHz, not the
  empty-path fallback the script prints when `create_clock` matches nothing.
- **Nested layout adopted early, empty directories not created** (2026-09-17).
  `rtl/core/` and `tb/cocotb/` now hold the two existing files; the other eight
  directories in CLAUDE.md §3 appear when they have contents. The real fix was
  not the move but the **globs**: `rtl/*.sv` matched one level, and the failure
  modes were asymmetric — Verilator errors on a missing module, but Vivado
  black-boxes it with a critical warning and finishes, emitting a utilization
  report for a design with a hole in it. Every source glob is now recursive,
  sorted for reproducible ordering, and errors on an empty match, and
  `synth_ooc.tcl` additionally rejects any netlist containing a black box
  (`IS_BLACKBOX`, property name verified against Vivado rather than assumed).
- **Hosted CI runs lint + sim + formal; synthesis stays local** (2026-09-17).
  CLAUDE.md §4 previously demanded synth in CI, which this file already argued
  against. The line that was missing is that **cost, not principle**, separates
  them: yosys and SymbiYosys install in minutes and belong in CI from Phase B,
  while Vivado's ~54 GB does not fit a hosted runner. Committed reports in
  `docs/reports/` are the substitute; a self-hosted runner is the upgrade path.
- **Measurement discipline restored to CLAUDE.md §10** (2026-09-17). The
  rewrite deleted it, but `syn/synth_ooc.tcl` and this file's trend table both
  rest on it. Three rules are back — measure every increment, numbers come from
  generated files, conditions travel with the number. The fourth (p50/p99
  latency distributions) stayed deleted: nothing here reports a latency
  distribution, so it was framing borrowed from a different kind of project.
- **RVFI: design in now, connect the port at WB** (2026-09-17). CLAUDE.md §5.4
  wants RVFI from Phase A. The shadow fields ride the pipeline registers from
  this slice on, but the *port* waits for a retirement to report: with no WB,
  `rvfi_valid` could only be tied low, and wiring riscv-formal to a core that
  never retires makes every ISA property pass **vacuously** — the exact failure
  §5.5 and §9 warn about. A green formal run that proves nothing is worse than
  no run. Full reasoning and the per-field capture points in
  [rvfi-plan.md](rvfi-plan.md); the one that bites is `rs1_rdata`/`rs2_rdata`,
  whose taps must move to the forwarding-mux outputs when EX lands.
- **Register file has no reset on the array** (2026-09-17). RV32I leaves x1–x31
  undefined at reset, so resetting them buys nothing architecturally and costs
  992 flops plus the loss of RAM inference. Measured rather than assumed: the
  synthesis report shows RAMD32 x68 and RAMS32 x20 — 44 LUTs of distributed RAM
  — and the FF count landed at 249, which is the pipeline registers alone. The
  simulation cost is X on the read ports until a register is written; that is a
  testbench problem, not a hardware one.
- **cocotb 2.0.1 → 2.1.0** (2026-09-17). Forced, not cosmetic. Under 2.0.1,
  adding the register file's 32 x 32 array made **reading a top-level output
  port segfault** in the VPI layer. Reduced to a 15-line module with one array
  and twelve 32-bit outputs: 12/12 reads on 2.1.0, 4/12 on 2.0.1, and the
  crash point moved with unrelated build flags, which is what memory corruption
  looks like. Ruled out first: our RTL (lint clean, generated C++ symmetric
  across the ports), signal naming, port count, packed vs. unpacked array, and
  the trace flags. Verilator VPI array support is a known weak spot in cocotb
  (issues #1851, #3446, #3611). Anyone on 2.0.1 will see this the moment a
  register file appears, hence the pin in `tb/cocotb/requirements.txt`.
- **EX slice excludes branches, loads/stores and forwarding** (2026-09-17). Not
  laziness — each is blocked on something that does not exist yet. Forwarding
  sources are the EX/MEM and MEM/WB registers, so there is literally nothing to
  forward from. Branch resolution needs the flush machinery, which belongs with
  the hazard unit. Loads and stores need MEM. Half a branch is worse than none,
  so the unimplemented classes decode inert instead.
- **The hazard slice was split: data hazards first, branches second**
  (2026-10-07). The plan bundled forwarding, the load-use stall and branches.
  Forwarding is independent of control flow and removes the NOP padding every
  test needed; branches bring their own flush machinery. Two slices also mean
  two trend rows, so each feature's cost is visible on its own.
- **Golden model before RTL, and proven on both sides of the change**
  (2026-10-07). The model and random tests were written before any hazard RTL.
  Padded programs passed against the old core (the model is right); dense ones
  failed at writeback #11 (the test can see hazards); after the hazard unit,
  both passed. The first padded run failed for a third reason worth
  remembering: the register file has no reset, so a random program reading a
  register before writing it got Verilator's initial value in the core and 0
  in the model. Random programs now load x1–x4 first, as real software would.
- **Branch resolution has its own comparator and target adder** (2026-10-07).
  Not the ALU: during a jump the ALU's result is replaced by the link address,
  and routing the redirect through the ALU's result mux would lengthen the
  path that now sets Fmax anyway. The comparator shares one carry chain
  between BLT and BLTU (sign bits decide when they differ).
- **A jump's link address replaces the ALU result in EX** (2026-10-07). The
  plan left open whether `pc + 4` is a third writeback source or goes through
  the ALU. Neither: a third WB source would break EX/MEM→EX forwarding of the
  link, and feeding a constant 4 into the ALU puts a mux on `alu_b`, which was
  already on the critical path at fanout 115. A 2:1 mux after the ALU, selected
  off a flop, costs the least. (No correct-path instruction can actually
  consume a link from EX/MEM — a jump's successor arrives two flushed cycles
  later and reads it through the register file — but the value is right on
  every path, which is what Phase B will check.)
- **Stall and redirect cannot coincide** (2026-10-07). The plan called for a
  directed test of both firing in one cycle. They cannot: the stall needs a
  load in EX and the redirect a branch or jump in EX, and EX holds one
  instruction. Redirect still outranks stall in the mux, at no cost.
  Confirmed by mutation: swapping the priority passes all 52 core tests.
  Belongs in Phase B as `!(stall && redirect)`.
- **Misaligned jump and branch targets drop bits [1:0]** (2026-10-07). Same
  reasoning as data misalignment: RV32I would trap, traps are out of scope.
  Masked off the sum rather than left out of the add, since `rs1[1:0] +
  imm[1:0]` can carry into bit 2. The directed test reads the landing pc with
  `auipc`: checking which instruction ran is not enough, because IMEM ignores
  the low bits too — a first version of the test missed a planted bug for
  exactly that reason, and only the random tests caught it.
- **Store data is forwarded** (2026-10-07). Not in the original plan. EX/MEM
  was copying rs2 out of ID/EX, so `addi x1; sw x1` back to back would have
  stored a stale x1. Found while designing the muxes, not in test, and covered
  by `test_store_data_is_forwarded`.
- **IMEM is driven from `pc_next`, not `pc`** (2026-10-07). Fixes a bug found
  during the MEM + WB slice: a BRAM latches its address at a clock edge and
  answers during the next cycle, so presenting `pc` made it return `mem[P]`
  while the pc already held `P + 4`. Every instruction reached IF/ID tagged
  with the next instruction's PC — `auipc x5, 0` at pc 8 wrote 12. It went
  unseen because the testbench answered IMEM within the cycle, which no BRAM
  can do. Now the BRAM and the pc register latch the same address on the same
  edge. The alternative, keeping a registered address and delaying the pc by a
  cycle to match, gives the address path better timing but adds one more
  wrong-path fetch to discard on every taken branch. Branch redirect and the
  stall both enter at `pc_next`, so one mux feeds both the pc and the BRAM.
  Proven both ways: the new testbench fails 4 tests on the old RTL (including
  the exact `auipc` symptom) and passes on the new.
- **Testbench memories sample just before the clock edge, not at the falling
  edge** (2026-10-07). `imem_addr_o` depends on `rst_i` combinationally, so a
  test releasing reset at the falling edge changes it in the same instant a
  falling-edge sampler reads it. Sampling 1 ns before the rising edge removes
  the race, and it is also how a real flop behaves (setup window).
- **Misaligned loads/stores are assumed not to happen** (decided 2026-10-07).
  RV32I demands support or a trap; traps are out of scope (§5.1) and hardware
  support means a MEM-stage FSM and a stall before any hazard unit exists.
  Defined behaviour rather than undefined: **address bits below the access size
  are ignored**, so a misaligned access touches the aligned word or halfword
  that contains it, never two words. Pinned by
  `test_misaligned_access_uses_the_containing_word`. **Open for Phase B:**
  riscv-formal must be told; check what `RISCV_FORMAL_ALIGNED_MEM` expects of a
  misaligned access (it may expect `rvfi_trap`) before relying on it, otherwise
  constrain the harness to aligned addresses. The same question now applies to
  misaligned jump and branch targets.
- **Load/store width is its own field, not the ALU's `funct3`** (2026-10-07).
  The earlier plan said the carried `funct3` doubled as the width. It cannot:
  loads and stores use the ALU to compute `rs1 + imm`, so the ALU's `funct3`
  must say ADD. `mem_funct3` rides alongside. It costs nothing in the end —
  Vivado merges each copy with the `instr[14:12]` shadow bits it always equals,
  keeping one flop per bit.
- **Store data is replicated, not shifted** (2026-10-07). `SB` puts rs2's byte
  in all four lanes and the strobes pick one; replication is wiring, a shifter
  is muxes. The unit test checks the memory *outcome*, not `wdata`'s unwritten
  lanes, so it would still pass on a correct shifting redesign.
- **The ALU is selected by `funct3` + `alt`, not a private opcode enum**
  (2026-09-17). Using the ISA's own encoding means the decoder and the ALU
  cannot drift out of step, because there is only one encoding. It also avoids a
  SystemVerilog package, which §4 lists among the constructs to check against
  Yosys before committing — and yosys is not installed until Phase B, so an
  unverifiable construct was worth designing around rather than adopting.
  The `alt` bit is where the classic decode bug lives: on OP-IMM it is `instr[30]`
  **only** for the two shift forms. Everywhere else `instr[30]` is immediate bit
  10, so forwarding it unconditionally turns `addi rd, rs1, -1` into a subtract —
  wrong only for immediates with bit 10 set, which small positive random values
  never produce. Directed tests cover it at both the decoder and the core level.

---

## Next up

### 1. Timing margin (decide before RVFI)

+0.059 ns is no margin, and the board-level run will be worse (the memory-port
paths are untimed here). Two levers, each its own measured slice:

- **Flush only the control bits of ID/EX.** The flush drives the sync-reset
  pin of all 171 ID/EX flops. A bubble only needs to be inert: `rd_we`,
  `mem_read`, `mem_write`, `branch`, `jump` low. Clearing those five and
  letting the data fields hold wrong-path junk cuts the fanout ~30x. Cost: the
  ILA/RVFI view of ID/EX shows junk in a bubble — which the RVFI valid bit has
  to cover anyway.
- **Register the forwarding selects in ID** (from the forwarding row): takes
  the hazard comparators off the front of both the ALU path and this one.

### 2. RVFI port + riscv-formal

Needs a **valid bit** through the pipeline first: a load-use bubble and a flush
bubble are both NOP decodes today, indistinguishable from a real NOP.
`rvfi_pc_wdata` is `redirect ? redirect_target : pc + 4` in EX.

Once WB retires instructions there is something non-vacuous to prove. Needs
yosys and SymbiYosys installed, which is also the first thing `make formal`
stops complaining about. Check reachability on every property — a vacuous pass
proves nothing (§5.5, §9).

### 3. FENCE, ECALL, EBREAK; `riscv-tests`

FENCE can decode as a NOP on an in-order core with no caches. ECALL/EBREAK
need a decision — no traps are in scope, but `riscv-tests` signals pass/fail
with ECALL — then the official suite (a Phase A box).

### 4. Board-level top

Deferred until the core executes instructions: `constr/arty_a7.xdc` pin
constraints, a top with BRAM instruction memory and clocking, then `make prog`
(still blocked on WSL2 USB passthrough, §6 of vivado-setup.md). Only then does
Fmax become a board number, and it gets its own table. It is also the first run
that times `pc + 4` → `imem_addr_o` → BRAM address, which the out-of-context
flow leaves unconstrained; expect it, plus the branch-target mux added in §1,
to be a candidate critical path — it now carries the branch comparator and
target adder too.

---

## How to maintain this file

Update at the end of any session that changed meaningful state. Keep it a
snapshot of *current* reality, not an append-only diary — stale claims here are
worse than no file. Specifically:

- Move items between "Implemented" and "Not started" as they land
- Re-run `make lint` and `make sim` and record what actually happened, not what
  should have
- **Run `make synth` and append a row to the synthesis trend table** after any
  RTL change. Copy the numbers from `docs/reports/summary_ooc.txt`; commit the
  regenerated reports in the same commit as the RTL that produced them, so a
  report always matches the code beside it in history
- Add decisions with their rationale, since the reasoning is the part that
  gets forgotten
- Update the toolchain table when anything is installed or upgraded

---

*Last updated: 2026-10-07 — branches, JAL and JALR landed (committed, not
pushed): `riscv_branch` comparator, target adder, link address in EX, IF/ID +
ID/EX flush, 2-cycle taken penalty. Golden model gained control flow, checked
against GNU `as`; random programs now branch. 113 tests. Fmax 110.4 → 100.6
MHz, +0.059 ns at 100 MHz. Next session: decide on the timing levers (Next up
§1), then RVFI.*
