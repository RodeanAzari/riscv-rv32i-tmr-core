# Progress Log

Running context for this project. Read this first at the start of a session to
know where things stand. Update it at the end of any session that changed
meaningful state.

**Repo:** https://github.com/RodeanAzari/riscv-rv32i-tmr-core (private)
**Local:** `~/riscv-rv32i-tmr-core`
**Phase:** B (formal) **done** 2026-10-17: every §5.5 property by k-induction, riscv-formal 46/46 with each check reached or shown to fail. C (UVM) **done** 2026-10-17: 205/205 coverage bins, every retirement checked against a C golden model. D — first light on the Arty A7 2026-10-17; CoreMark on the board 2026-10-17, 0.962 CoreMark/MHz, IPC 0.691. Phase A **done** 2026-10-08, CI run 37817380686

---

## Where things stand

**Position: Phase A complete; every box in CLAUDE.md §8 checked.** All 40 RV32I
instructions run, with forwarding (EX/MEM→EX, MEM/WB→EX, WB→ID through the
register file), a one-cycle load-use stall, and branches resolved in EX with
static not-taken prediction (taken costs two cycles, not taken none). Every
exception (ECALL, EBREAK, misaligned access, taken misaligned target) halts the
core; FENCE is a NOP. Both memories are external, BRAM-timed ports, in the
testbench as well as the design. The official **`riscv-tests` rv32ui suite
passes 40 of 42** (exclusions below).

**Timing: the board runs at 100 MHz** (WNS +1.550 ns in context, Fmax estimate
118.3 MHz; out of context 122.7 MHz) since data memory is accessed from EX
(2026-10-17). The critical path is branch resolution into the instruction
memory's address: forwarding select → branch comparator → redirect → pc mux.

`make lint`, `make sim` and `make synth` pass locally; lint and sim pass in CI,
including the official suite, assembled there by Ubuntu's GCC 13.2 rather than
the local GCC 16.

### Working and verified

| Check | Result |
|---|---|
| `make lint` | clean, Verilator 5.050 |
| `make sim` | 176/176 passing across 10 entries (core, alu, regfile, decoder, mem_align, hazard, branch, uart_tx, soc ×2), including the 40 official `riscv-tests`, the first-light firmware and one CoreMark iteration on the whole SoC (CRCs checked, IPC counted through RVFI, ~50 s), UART decoded at 115200 |
| `make synth` | routes clean, 0 errors, ~40 s |
| `make formal` | x0 invariance, stall correctness (S1–S4), forwarding (F1/F2/L1), reset-commits-nothing (X1), branch-flush correctness (B1/B2), no regfile structural hazard (SH1) and no X into committed state (XP) proven by k-induction, XT by BMC to depth 10; **riscv-formal 46/46 checks and 46/46 cover runs** (37 `insn`, `reg`, `pc_fwd`, `pc_bwd`, `unique`, `causal`, `causal_mem`, `liveness`, `hang`, `ill`), ~6 min (XT's BMC is ~5 of it) — see [formal-properties.md](formal-properties.md) |
| `make impl` | board-level route + bitstream, timing met at 100 MHz (WNS +1.550 ns), ~2 min |
| `make model-test` | the C golden model alone: rv32ui **40/40**; a planted SRA bug fails exactly `sra` |
| `make uvm` | XSim, 300 random programs, ~45 s: **205/205 coverage bins (100%)** on seeds 1, 2, 3, ~45,000 retirements each compared with the model, 0 mismatches. Planted RTL faults caught: forwarding priority (in the hazard unit), LBU sign-extending, no rs2 load-use stall |
| **On the board** | 2026-10-17, programmed from Windows (Lab Edition 2025.2), core at 50 MHz: "hello from rv32i", "sum 1..100 = 5050", then the count printing continuously with LD4-LD7 counting in binary. All three first-light goals seen; photo in [img/fpgafirstlight.jpg](img/fpgafirstlight.jpg) (Phase D's photo box; low-resolution, retake for the README) |
| **CoreMark on the board** | 2026-10-17, 2000 iterations at **100 MHz** (`make prog` from WSL): **0.962 CoreMark/MHz, about 96 CoreMark**, "Correct operation validated", 2,077,692,270 cycles ([coremark_board.txt](reports/coremark_board.txt)); the 50 MHz run before the clock change gave the same cycles per iteration. **IPC 0.691** (CPI 1.447) over the timed region, counted in RTL simulation of the same SoC ([coremark_sim.txt](reports/coremark_sim.txt)); simulated cycles per iteration match the board's to 0.0013%. RV32I without M: every multiply and divide is a libgcc call |
| **ILA on the board** | 2026-10-17, `make impl ILA=1` then `make ila` from WSL (Hardware Manager in batch through `hw_server`): 13 probes, 328 bits (pc and instruction of all four pipeline registers, EX/MEM ALU result, writeback, halt), depth 1024, core clock. First-light program: every EX→MEM→WB shift consistent, 227 stall cycles and 114 flush bubbles in the window ([ila_summary.txt](reports/ila_summary.txt), [ila_capture.csv](reports/ila_capture.csv)). ILA build (at 50 MHz, before the clock change): +2233 LUT, +3772 FF, +10 BRAM, WNS +4.162 ns ([summary_board_ila.txt](reports/summary_board_ila.txt)). CoreMark at 100 MHz with the ILA (WNS +1.066 ns), triggered on `core_state_transition`: stage shifts consistent, 881 retirements in 1023 cycles ([ila_coremark_summary.txt](reports/ila_coremark_summary.txt), [ila_coremark.csv](reports/ila_coremark.csv)) |
| CI on push | green (lint + sim + formal) at `9eaa9a8`, run 39094592781 |

### Implemented, and what to know before touching it

All RTL lives in `rtl/core/` (`riscv_core`, `_decoder`, `_branch`, `_hazard`,
`_mem_align`, `_alu`, `_regfile`); the code and its comments are the detail.
Only the facts that are not obvious from reading it:

- **Both memories are external ports, synchronous read, BRAM-timed.** The core
  presents `pc_next` to IMEM so the BRAM and the pc latch the same address on
  the same edge. **Data memory is accessed from EX** (address from its own
  adder, stores issued there): load data arrives in MEM, is aligned there and
  registered into MEM/WB, so no forward ever starts at a BRAM output. Was in
  MEM until 2026-10-17; the load-use stall is one cycle either way.
- **Branches and jumps resolve in EX**, static not-taken: taken costs two
  cycles, not taken none. A jump's link address replaces the ALU result going
  into EX/MEM. Forwarding selects are decided in ID and registered into ID/EX.
- **Every exception halts the core** (ECALL, EBREAK, illegal instruction,
  misaligned access, taken misaligned target); `halt_o` is sticky until reset.
  FENCE is a NOP. **Illegal** = any word outside the 40 RV32I encodings (CSRs,
  MRET, WFI, FENCE.I, reserved funct3/funct7, all zeros): it traps and does
  nothing else. Was inert (no halt) until 2026-10-17; changed for
  riscv-formal's `ill`.
- **A bubble clears six ID/EX bits** (`rd_we`, `mem_read`, `mem_write`,
  `branch`, `jump`, `halt`), not the whole register, so `id_ex_*_o` show the
  squashed instruction during a bubble. Each bit is pinned by a test that fails
  if it is left set.
- **The register file has no reset, deliberately** (keeps RAM inference). Tests
  that depend on forwarding preset registers first, or they can pass vacuously.
- **RVFI port and `FORMAL` property blocks are compiled out of synthesis**
  (`RISCV_FORMAL` / `FORMAL`); `make lint` runs both configurations.
- **First-light SoC** (`rtl/top/`): `soc.sv` is board-independent (core, one
  32 KiB dual-port RAM for code and data, LED and UART registers; memory map
  in its header) and is what cocotb runs; `arty_a7_top.sv` adds the MMCM
  (100 → 50 MHz) and the reset. Lint reads stand-ins for the Xilinx
  primitives from `tb/models/`; Vivado must never read them. The reset
  release relies on flops powering up to 0 (Xilinx GSR), not on RTL init.
- **UVM environment** (`tb/uvm/`, `make uvm`; Phase C): a sequence item is a
  whole program; the driver loads it into the testbench memory and the C
  model (`sw/model/`, via DPI-C) and resets the core; a reactive responder
  serves both ports with BRAM timing; the scoreboard steps the model per
  RVFI retirement; coverage is one covergroup per group of
  `docs/coverage-plan.md`, flattened so the % is bins hit / bins. White-box
  coverage reads core internals by hierarchical name (tb only).
- **XSim's constraint solver is unreliable; measure the draws.** In 2025.2:
  `x inside {queue}` hangs the elaborator forever; a class whose constraints
  are all conditional on one `kind` gave degenerate draws (K_I never picked);
  a `dist` beside a condition on a non-rand member, or beside implications
  on the same variable, is ignored. The generator randomizes in stages (kind,
  then a small class per kind) and does queue picks and offset alignment
  procedurally. Coverage was 68.8% before this, 100% after.
- **Firmware** (`sw/firstlight/`, `make fw`): no libgcc, so no `*`, `/`, `%`
  in C (RV32I has no M). `hello_sim.hex` has a 20-iteration delay for sim.
- **Testbench:** `feed()` assumes no stall, so anything with a load-use pair
  goes through `run()`. `test_core` checks every retirement against the golden
  model (`tb/cocotb/rv32i_model.py`) through RVFI; `SEED=n` reruns a seed.
  `test_riscv_tests.py` runs upstream rv32ui with our own env
  (`sw/riscv-tests-env/`); 2 of 42 excluded: `fence_i` (Zifencei) and `ma_data`
  (expects misaligned support; this core traps).

### Not started

TMR, all of Stage 2.

---

## Synthesis trend

**This table is the one append-only thing in this file.** Never rewrite a past
row; if an old number turns out to be wrong, add a row saying so. Add a row after
every RTL slice: `make synth`, then copy the numbers from
`docs/reports/summary_ooc.txt`, never from memory or scrollback. Keep the row
to one line; a lesson worth keeping goes under "Reading these numbers".

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
| 2026-10-07 | Bubble clears 5 control bits, not all of ID/EX | 963 | 492 | 47 | +0.073 | 100.7 | +0.1 |
| 2026-10-07 | Forwarding selects decided in ID, registered | 1095 | 496 | 47 | +0.394 | 104.1 | +3.4 |
| 2026-10-07 | RVFI port, under `RISCV_FORMAL` (not synthesized) | 1095 | 496 | 47 | +0.394 | 104.1 | 0.0 |
| 2026-10-08 | FENCE (NOP), ECALL/EBREAK halt | 1107 | 501 | 47 | +0.430 | 104.5 | +0.4 |
| 2026-10-08 | Misaligned access / taken target traps (halts) | 1115 | 501 | 47 | +0.300 | 103.1 | −1.4 |
| 2026-10-08 | Redirect mask as a concatenation (Yosys cast bug) | 1115 | 501 | 47 | +0.300 | 103.1 | 0.0 |
| 2026-10-08 | Stall properties S1–S4, under `FORMAL` (not synthesized) | 1115 | 501 | 47 | +0.300 | 103.1 | 0.0 |
| 2026-10-08 | Reset gates store and writeback; forwarding props (not synthesized) | 1117 | 501 | 47 | +0.317 | 103.3 | +0.2 |
| 2026-10-10 | Branch-flush properties B1/B2, under `FORMAL` (not synthesized) | 1117 | 501 | 47 | +0.317 | 103.3 | 0.0 |
| 2026-10-16 | Regfile structural-hazard property SH1, under `FORMAL` (not synthesized) | 1117 | 501 | 47 | +0.317 | 103.3 | 0.0 |
| 2026-10-16 | `f_regs_o` port for the X-propagation proof, under `FORMAL` (not synthesized) | 1117 | 501 | 47 | +0.317 | 103.3 | 0.0 |
| 2026-10-17 | Illegal instructions trap (legality decode in ID) | 1130 | 501 | 47 | +0.382 | 104.0 | +0.7 |
| 2026-10-17 | Data memory accessed from EX; load data registered in MEM/WB | 964 | 467 | 55 | +1.850 | 122.7 | +18.7 |

Device totals for the percentages: 63,400 LUT / 126,800 FF / 135 BRAM /
240 DSP.

### Reading these numbers

**Fmax here is not a board number.** Out-of-context leaves `HD.CLK_SRC` unset,
so Vivado cannot estimate clock delay or skew. Read it as the core's logic
limit. A real board number arrives with the Arty A7 top and gets its own table;
measurement conditions travel with the measurement.

**The critical path, through 2026-10-16:** `mem_wb` writeback select or load
lane select → writeback mux → forwarding mux → branch comparator carry chain
→ `redirect` → IF/ID flush and ID/EX bubble clear, 9-11 levels, about 75%
routing. Since data memory moved to EX (2026-10-17) the forward starts at a
flop: out of context it is now forwarding select → ALU → EX/MEM (7.8 ns, 6
levels, 79% routing). The remaining lever is the redirect fanout (IF/ID flush
via a valid bit; see Next up).

**The out-of-context slack is optimistic.** Paths that cross the core's ports
are untimed here (no output delays are set): the pc and branch-resolution
paths → `imem_addr_o`, and since 2026-10-17 the data address adder →
`dmem_addr_o`. The board-level table is the one that times them.

Lessons from individual rows:

- **Misalignment trap (three runs):** reading misalignment off `alu_result[1:0]`
  and dropping the target term from `freeze` gave −0.912 ns and 21 levels: with
  `freeze` a plain select, Vivado folded `freeze ? pc : pc + 4` into the pc+4
  carry chain, in series with SLT's compare chain. Fixed with a dedicated
  `ex_rs1[1:0] + imm[1:0]`, exact because a sum's low bits depend only on its
  operands' low bits.
- **Registered forwarding selects:** +132 LUT is **not explained** (it is in
  synthesis itself; the mix shifted to smaller LUTs). Cause not established.
- **IF fix:** +5 FF because `pc[1]` no longer constant-folds; cause not
  established. Deltas under ~0.2 MHz are placement noise.
- **Rows marked "not synthesized"** are identical to the row above by design
  (RVFI and `FORMAL` code sit under `ifdef`; Vivado is deterministic).

---

## Board-level timing (Arty A7)

Separate from the trend table: different conditions. `make impl`, numbers from
`docs/reports/summary_board.txt`. In-context on `xc7a100tcsg324-1`, core clock
from the MMCM, LED/UART/button I/O false-pathed. LUT/FF are cell counts, as in
the trend table; the core's debug outputs are unconnected here, so Vivado
trims logic the OOC run keeps.

| Date | Build | LUT | FF | BRAM | Core clock | WNS (ns) | Fmax (MHz) |
|---|---|---|---|---|---|---|---|
| 2026-10-17 | First light: core + 32 KiB RAM + LED + UART (ran on the board at 50 MHz) | 1009 | 374 | 8 | 50 MHz | +5.920 | 71.0 |
| 2026-10-17 | + illegal-instruction trap, + cycle counter; CoreMark image (ran on the board at 50 MHz) | 1141 | 434 | 8 | 50 MHz | +4.917 | 66.3 |
| 2026-10-17 | Data memory accessed from EX; core clock to 100 MHz; CoreMark image (ran on the board at 100 MHz) | 1085 | 398 | 8 | 100 MHz | +1.550 | 118.3 |

At 50 MHz the critical path was the one the OOC flow could not time: a block
RAM's output (load data) through alignment, the forwarding mux and the branch
comparator to the RAM's fetch address, 14.2 ns, 11 levels, 68% routing (13.4
ns at first light). Accessing data memory from EX removed it; at 100 MHz the
worst path is forwarding select → branch comparator → redirect → pc mux →
fetch address, 7.8 ns, 7 levels, 74% routing. The note below on the 50 MHz
build's hold slack is history; that is a measured slice of its own. Hold slack is
+0.064 ns (MEM/WB rd address → regfile LUTRAM write address): positive, thin.

---

## Benchmark trend (CoreMark)

Append-only, like the synthesis trend. A row per CoreMark run on the board:
`make impl FW_IMAGE=sw/build/coremark.hex`, `make prog`, then the UART log
saved as `docs/reports/coremark_board.txt` and the simulation's
`tb/cocotb/sim_build/coremark_sim.txt` (from `make sim`) as
`docs/reports/coremark_sim.txt`, both committed with the change that
produced them. CoreMark/MHz is from the board; IPC is counted through RVFI in
RTL simulation of the same SoC, one iteration. `-O2 -march=rv32i
-mabi=ilp32`, GCC 16.1.0, 2K performance run.

| Date | Build | Core clock | Iterations | Cycles | CoreMark/MHz | IPC (sim) |
|---|---|---|---|---|---|---|
| 2026-10-17 | First CoreMark: core + illegal trap, SoC + cycle counter | 50 MHz | 1000 | 1,038,847,073 | 0.962 | 0.691 |
| 2026-10-17 | Data memory accessed from EX; 100 MHz | 100 MHz | 2000 | 2,077,692,270 | 0.962 | 0.691 |

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
| ↳ XSim | 2025.2 | Vivado's simulator, with its bundled UVM 1.2 and DPI-C (`xsc`); used by `make uvm` |
| **OSS CAD Suite** | nightly **2026-10-07** | `~/.local/opt/oss-cad-suite` (2.5 GB), `bin/` **appended** to PATH in `~/.bashrc`. The bundle's date is its version — pin CI to the same one |
| ↳ Yosys | 0.69+208 (`7b1913f4c`) | from the suite. Also the ASIC flow's synthesis step (§6.4) |
| ↳ SymbiYosys (`sby`) | 0.69 | from the suite, with `yosys-smtbmc` |
| ↳ solvers | Yices 2.7.0, Boolector 3.2.4, Bitwuzla 0.9.1, Z3 4.15.5 | from the suite |
| **LibreLane + Sky130** | — | **not installed** — needed closing Phase E (CLAUDE.md §6.4 run #1) |
| **riscv-formal** | `c992aa6` (2026-07-16) | git submodule `tb/formal/riscv-formal`; never written to — `scripts/riscv-formal.sh` builds a symlink tree in `tb/formal/build/rvf/` instead |
| **riscv-tests** | `bcffa2b` (2026-09-25) | git submodule `sw/riscv-tests`; its own nested `env` submodule is deliberately not initialised — we use our env |

`~/.local/bin` is first on PATH, so the source-built Verilator shadows the
Debian 5.032 package automatically. OSS CAD Suite's `bin/` is **last**, so it
supplies only what nothing else does — `which verilator python3` must still
print `~/.local/bin/verilator` and `/usr/bin/python3`.

**Yosys reads the core** (checked 2026-10-07, with and without `-DRISCV_FORMAL`):
all modules elaborate, none black-boxed. That is parse-and-elaborate only: a
clean elaboration still hid a Yosys mis-parse of `~XLEN'(2'b11)` that
riscv-formal found on its first run (see Decisions).

### Environment gotchas

- **`sudo` cannot prompt for a password through Claude Code** (no TTY). Anything
  needing root must be run in a separate WSL terminal.
- **Vivado needs `libncurses.so.5`, which Ubuntu 26.04 does not package.** Batch
  runs **hang at 0% CPU with no output** instead of failing. Fixed with compat
  symlinks in `~/.local/lib/vivado-compat`, which `vivado-env` puts on
  `LD_LIBRARY_PATH` (vivado-setup.md §3).
- **Vivado 2026.1 forced `LC_ALL=en_US.UTF-8`** and crashed on launch; worked
  around via `~/.locale` and `LOCPATH`. 2025.2 does not need it.
- Debian's Verilator is 5.032, below cocotb 2.x's 5.036 floor, so Verilator is
  built from source locally and in CI.
- **OSS CAD Suite ships its own Verilator and Python.** `bin/` is therefore
  appended to PATH, never prepended or `source`d, or `make sim` would silently
  change simulators.

---

## Build targets

| Target | Does | State |
|---|---|---|
| `make lint` | Verilator lint of `rtl/` | working |
| `make sim` | cocotb regression | working |
| `make sw` | build `sw/**/*.c` → `.elf` / `.hex` | **broken**: its glob takes riscv-tests' C sources; superseded by `make fw` |
| `make spike` | run `.elf` on spike | untested, depends on `make sw` |
| `make fw` | first-light firmware → `sw/build/hello.hex` (board), `hello_sim.hex` (sim) | working; local riscv32 or CI's riscv64 gcc |
| `make bench` | CoreMark (submodule `sw/coremark`, port `sw/coremark-port/`, links libgcc) → `sw/build/coremark.hex` (board, `COREMARK_ITERATIONS`=1000), `coremark_sim.hex` (1 iteration) | working, locally and in CI (the riscv64 package's rv32i/ilp32 libgcc) |
| `make impl` | board-level synth + route + bitstream (`syn/impl_arty.tcl`), reports `docs/reports/*_board.*`; refuses a missing RAM image, writes no bitstream if timing fails; `FW_IMAGE=` picks the RAM image (default first light); `ILA=1` adds the ILA and its `.ltx`, reports to `syn/build/board/ila_reports/` so `docs/reports/` stays ILA-free | working |
| `make synth` | OOC synth + impl of the core, reports to `docs/reports/` | working |
| `make prog` | Arty attached to WSL (usbipd): programs it with `openFPGALoader -b arty_a7_100t`; otherwise prints the Hardware Manager steps and the Windows path | working, both routes tried on the board |
| `make ila` | after `make impl ILA=1`, with the Arty attached to WSL: programs it and captures the pipeline registers (`syn/ila_capture.tcl`, Vivado Hardware Manager in batch) to `syn/build/board/ila_capture.{csv,vcd}`, then checks the capture (`scripts/ila_check.py`) | working |
| `make gui` | opens the last `make impl`'s routed design in the Vivado GUI (`syn/gui_view.tcl`): device view colored by module, worst path + its schematic, timing, utilization, power tabs. `VIEW=rtl`: elaborated RTL schematic. `VIEW=ila`: programs an ILA build, triggers on `ILA_TRIGGER` (default `core_state_transition`; must be a function the code calls, GCC inlines some) and shows waveforms | working |
| `make floorplan` | exports placement + routing from the routed checkpoint (`syn/floorplan_export.tcl`) and draws `docs/img/floorplan_board{,_core}.svg` (`scripts/floorplan.py`); refuses an ILA build | working |
| `make formal` | SymbiYosys over every `tb/formal/*.sby`, all tasks, then `scripts/riscv-formal.sh` (checks + covers, verdicts read from status files); appends OSS CAD Suite's `bin/` to PATH itself; `FORMAL_JOBS=n` | working |
| `make model-test` | C golden model on rv32ui (host cc + RISC-V gcc) | working |
| `make uvm` | UVM regression in XSim (`tb/uvm/run.sh`): `SEED`, `PROGRAMS` (300), `COV_MIN` (95); fails on any UVM error or coverage below `COV_MIN` | working; local only (Vivado), like `make synth` |
| `make asic` | — | stub that names its phase |

---

## CI

`.github/workflows/ci.yml`, two parallel jobs. **`verilate`** builds Verilator
5.050 from source (cached on `verilator-Linux-v5.050`), installs cocotb from
`tb/cocotb/requirements.txt`, runs lint and sim. It checks out submodules for
`sw/riscv-tests` and assembles it with Ubuntu's `gcc-riscv64-unknown-elf`
(`-march=rv32i -mabi=ilp32` pick the target; no riscv32 package is needed).
**`formal`** downloads OSS CAD Suite at `OSS_CAD_SUITE_DATE` (2026-10-07; must
move together with the local install) and runs `make formal`. Not cached.

**GitHub evicts a cache unused for 7 days**, so the first push after a break
rebuilds Verilator (~8 min); that is not a broken cache key. Bumping
`VERILATOR_VERSION` also forces a rebuild.

**Watch: `ubuntu-latest` becomes Ubuntu 26 from 2026-10-19.** The apt riscv64
toolchain changes, and the cache key names only `runner.os`, so a Verilator
built on 24.04 would be restored onto 26.04. If the first run after the switch
fails, suspect this before the RTL; fix by pinning `runs-on: ubuntu-24.04` or
adding the image version to the key.

**Not in CI:** synthesis (Vivado is too large for a hosted runner).

---

## Decisions that still matter

Only what you need to know to move forward. Rationale for the rest is in git
history, [formal-properties.md](formal-properties.md) and
[rvfi-plan.md](rvfi-plan.md).

- **Vivado is pinned to 2025.2.** 2026.1 made the free tier Windows-only; a
  Linux seat costs ~$1,200-$1,800/yr and the trial expires mid-Phase-D. Install
  is under `~/Xilinx`. **Never source `settings64.sh` in `.bashrc`** (it breaks
  `git`/`curl`); use the opt-in `vivado-env` function.
- **Target part `xc7a100tcsg324-1`** (Arty A7-100T), confirmed 2026-09-05.
- **Synchronous, active-high reset; `_i`/`_o` on every port, clock included.**
  The clock *object* stays named `clk` because `syn/synth_ooc.tcl` and every
  committed report find it that way.
- **Hosted CI runs lint + sim + formal; synthesis stays local**, with reports
  committed to `docs/reports/`. Cost, not principle: Vivado is ~54 GB.
- **cocotb is pinned to 2.1.0.** 2.0.1 segfaults reading an output port once a
  register file (an array) exists.
- **Formal tools come from OSS CAD Suite, date-pinned** (2026-10-07; CI uses the
  same date). It is appended to PATH, never prepended or sourced.
- **Properties live in the RTL under `ifdef FORMAL`; environments and
  assumptions live in `tb/formal/`.** Yosys turns a hierarchical reference from
  a harness into a free undriven wire, so the assertion silently vanishes.
  "Previous cycle" values are explicit `f_past_*` flops, not `$past()`.
- **X-propagation uses Yosys `xprop`, not a two-copy miter** (the miter
  stalled every solver at step 8). In that flow, never `opt` before `xprop`
  and make free-init flops `$anyinit` after it: `opt` folds a flop with no
  init to a constant, which hid a planted unreset flop (`tb/formal/xprop.sby`).
- **riscv-formal runs from a symlink tree** (`scripts/riscv-formal.sh`), never
  writing into the submodule. Its generated `.sby` files say `expect pass,fail`,
  so `sby` exits 0 on a FAILED check; the script reads every `status` file and
  requires one PASS per check. `covers.cfg` is `checks.cfg` with `mode cover`.
  `insn` checks alone are not enough: `reg`, `pc_fwd`, `pc_bwd`, `unique` and
  `causal` run too, because a pipeline that forwards the wrong value reports it
  faithfully.
- **No size casts on expressions Yosys sees.** Yosys 0.69 reads `~XLEN'(2'b11)`
  as a cast to width `~XLEN`; Verilator and Vivado read it as intended. Use a
  concatenation, or parenthesise and let `make formal` judge.
- **Misaligned accesses and taken targets trap, and a trap halts.** riscv-formal
  requires it (`spec_trap == trap`); assuming misalignment away in the harness
  was rejected as hiding real behaviour.
- **Reset gates the two commit points** (`dmem_we_o`/`dmem_wstrb_o` and
  `wb_rd_we_o`, ANDed with `!rst_i`): pipeline registers still hold power-up
  contents during reset. Invisible in simulation and on the FPGA, real on an
  ASIC.
- **FENCE is a NOP.** Revisit when the Stage 2 DMA first shares memory.
- **The ASIC flow is LibreLane, not OpenLane** (the successor to OpenLane 2).
  Open: whether LibreLane has built-in scan insertion (§6.5); check in Phase H.

---

## Next up

> **Resume here (2026-10-17, Phases B and C done; the board runs at 100 MHz).**
> Data memory is accessed from EX, which took the load-data path off the
> critical path: 100 MHz closes (WNS +1.550 ns). CoreMark 0.962/MHz, about 96
> at 100 MHz, IPC 0.691 (`make bench`, `make impl
> FW_IMAGE=sw/build/coremark.hex`). ILA: `make impl ILA=1`, `make ila`.
> **Next:** Phase D's last box is the photo (the first-light one is
> low-resolution); then the PuTTY demo below; then Phase E (TMR).

### User requests to carry forward

- **Before Phase E, after Phase D closes:** run a few programs on the Arty
  and show their output in PuTTY on Windows (COM port, 115200 8N1), for
  screenshots in the README. Detach usbipd first so Windows has the COM port.
- **Vivado screenshot sets, a folder per stage under `docs/img/vivado/`,
  plus `make floorplan` (the zoomable SVGs in `docs/img/`):** device view colored by module, worst path (device + schematic), RTL
  schematic, timing summary, utilization by hierarchy, power (label it a
  vectorless estimate), ILA waveforms. `make gui`, `make gui VIEW=rtl`,
  `make gui VIEW=ila`. The Phase D set is done (2026-10-17, single core; in the README's "On the chip"). **Remind
  the user to take a new set after Phase E** (TMR: three copies visible,
  before/after comparison) **and at Stage 2 milestones** (systolic array,
  DMA + interconnect, integration). Shots must come from the build whose
  reports are committed: rebuild without ILA before the non-ILA shots.
  `make floorplan` overwrites `docs/img/floorplan_board*.svg`: move the
  previous pair into that stage's folder first, for the before/after.

- **The Doom finale, at the very end of the project** (after Phase H, once
  everything else is done): build what the SoC lacks to run Doom on the
  Arty (DDR + cache, WAD from flash, VGA framebuffer, M extension). Scope
  and list in buildplan.md §7.

### 1. Timing: IF/ID flush via the valid bit

Not needed for 100 MHz (met with +1.550 ns), but still the next lever: the
board's worst path is the branch comparator → redirect → pc mux → fetch
address, and the redirect also drives the IF/ID flush (fo ~95). The valid
bit exists, but only under `RISCV_FORMAL`; moving `if_id_valid` into the core
proper and gating decode with it would let a redirect clear one bit instead
of 64. Its own measured slice.

### 2. Board-level top: first light (done 2026-10-17)

Scheduled ahead of Phase C as an early slice of Phase D. Done when all
three are seen on the board:

1. **LEDs blink**: a program in BRAM writes to a memory-mapped LED register
2. **Text prints**: a UART transmitter (`rtl/periph/`) prints "hello" to a
   serial terminal over the board's USB-UART
3. **A simple program runs**: a small compiled C program (e.g. a counter or
   a sum printed over UART), not just hand-written assembly

Pieces: `constr/arty_a7.xdc` pin constraints (copied from Digilent's master XDC),
a top with BRAM instruction/data memory, clocking (likely an MMCM to 50 MHz for
first light, given the thin OOC margin), a simple address decode for the
LED and UART registers, `make impl`, then `make prog`
(still blocked on WSL2 USB passthrough, §6 of vivado-setup.md). Only then does
Fmax become a board number, and it gets its own table. It is also the first run
that times `pc + 4` → `imem_addr_o` → BRAM address, which the out-of-context
flow leaves unconstrained; expect it, plus the branch-target mux added in §1,
to be a candidate critical path — it now carries the branch comparator and
target adder too.

**Programming the board: both options set up and working (2026-10-17),
user's choice per session.** Setup steps: vivado-setup.md §6. Option 2 first, for first light and for learning the
GUI: Vivado Lab Edition 2025.2 (Hardware Manager only, cable drivers ticked)
on Windows loads the `.bit` built in WSL; the UART goes to a Windows
terminal. **Option 1 is to be set up as well, after first light**, because
it is faster for everyday runs: `usbipd-win` + `openFPGALoader` in WSL.
Then `make prog` should program the board itself when the Arty is attached
to WSL, and print the Windows steps when it is not. Note: `usbipd attach`
takes the USB device away from Windows (Hardware Manager and the COM port
both lose it) until `usbipd detach`, so switching method means switching
the attachment. Background: WSL2 cannot
see USB devices by default, so neither Vivado's Hardware Manager nor
`openFPGALoader` *running inside WSL* will find the Arty's JTAG on its own.
vivado-setup.md §6 reads as if `openFPGALoader` avoids this; it does not. It
avoids Vivado's Hardware Manager, not the USB problem. Two options:

1. **`usbipd-win` + `openFPGALoader` in WSL.** `usbipd-win` (installed on
   Windows) attaches the Digilent USB device into WSL; `openFPGALoader -b arty_a7_100t` (plain `arty` is the 35T)
   then programs the `.bit` from WSL. Fully scriptable, so `make prog` does
   the whole job. Cost: the device must be re-attached (`usbipd attach`) after
   every reboot or replug.
2. **Program from the Windows side.** Build the `.bit` in WSL with `make impl`,
   then load it with Vivado Hardware Manager or `openFPGALoader` on Windows,
   pointed at the file through `\\wsl$\...`. Fewest moving parts, but
   `make prog` would no longer program the board itself; it could only
   print instructions.

The serial console (UART text) has the same issue: the Arty's USB-UART
appears as a COM port on Windows, and reaches WSL only through `usbipd-win`.
A Windows terminal (PuTTY, Tera Term) on the COM port avoids that.

**Learning the Vivado GUI alongside the scripts.** The build stays scripted
(`make impl` / `make prog`, Tcl in batch mode, never GUI-only, per CLAUDE.md
§2), but the user wants to learn the Vivado GUI too. At bring-up, walk through
it on the same design: open the checkpoints (`.dcp`) `make impl` writes to
look at the device view, the placed design, the critical path and the timing
and utilization reports, and use Hardware Manager (at least once, even if
option 1 is chosen above) to program the board and later view ILA captures.
The GUI is for looking and learning; the scripts produce the committed results.

---

## How to maintain this file

This file is loaded into every request, so every line costs tokens on every
turn. Keep it a snapshot of *current* reality, not a diary or a design log;
stale claims here are worse than no file. Update it at the end of any session
that changed meaningful state.

- Re-run `make lint`, `make sim` (and `make formal` after RTL or property
  changes) and record what actually happened, not what should have
- **Run `make synth` and append a row to the synthesis trend table** after any
  RTL change. Copy the numbers from `docs/reports/summary_ooc.txt`; commit the
  regenerated reports in the same commit as the RTL that produced them
- Update the toolchain table when anything is installed or upgraded
- **Do not list everything that is implemented or not started.** The RTL, its
  comments, the tests and the git history are the record. "Implemented" holds
  only facts a future session would get wrong without being told; "Not started"
  stays a one-liner
- **Do not log every decision.** Record only a decision you must know to move
  forward (a pin, a constraint, a trap that cost real time, a rule the code does
  not make obvious), in a line or two. Put long rationale in
  `docs/formal-properties.md`, `docs/rvfi-plan.md` or the commit message, and
  delete a decision once the code makes it obvious
- Trim as you go: when a section grows, cut it back in the same session

---

*Last updated: 2026-10-17 — 100 MHz on the board: data memory accessed from
EX (load data registered into MEM/WB), board WNS +1.550 ns at 100 MHz, OOC
122.7 MHz; CoreMark 0.962/MHz (about 96) validated at 100 MHz, IPC
unchanged. XT's harness follows stores into EX. ILA on the pipeline
registers (`make ila`). Next: the photo box, then Phase E.*
