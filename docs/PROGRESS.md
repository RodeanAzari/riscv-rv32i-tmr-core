# Progress Log

Running context for this project. Read this first at the start of a session to
know where things stand. Update it at the end of any session that changed
meaningful state.

**Repo:** https://github.com/RodeanAzari/riscv-rv32i-tmr-core (private)
**Local:** `~/riscv-rv32i-tmr-core`
**Phase:** B — formal verification, started 2026-10-08 (every §5.5 property done; a few riscv-formal items open). **First light on the Arty A7 2026-10-17** (early Phase D): text over UART, a compiled C program, LEDs counting. Phase A **done** 2026-10-08, CI run 37817380686

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

**Timing margin: +0.317 ns at 100 MHz out-of-context (103.3 MHz).** Thin, and the
paths that cross the memory ports are not timed at all. The critical path is
branch resolution fed by the MEM/WB forward of the writeback mux.

`make lint`, `make sim` and `make synth` pass locally; lint and sim pass in CI,
including the official suite, assembled there by Ubuntu's GCC 13.2 rather than
the local GCC 16.

### Working and verified

| Check | Result |
|---|---|
| `make lint` | clean, Verilator 5.050 |
| `make sim` | 174/174 passing across 9 toplevels (core, alu, regfile, decoder, mem_align, hazard, branch, uart_tx, soc), including the 40 official `riscv-tests` and the first-light firmware running on the whole SoC, UART decoded at 115200 |
| `make synth` | routes clean, 0 errors, ~40 s |
| `make formal` | x0 invariance, stall correctness (S1–S4), forwarding (F1/F2/L1), reset-commits-nothing (X1), branch-flush correctness (B1/B2), no regfile structural hazard (SH1) and no X into committed state (XP) proven by k-induction, XT by BMC to depth 10; **riscv-formal 42/42 checks and 42/42 cover runs** (37 `insn`, `reg`, `pc_fwd`, `pc_bwd`, `unique`, `causal`), ~5 min (XT's BMC is ~3 of it) — see [formal-properties.md](formal-properties.md) |
| `make impl` | board-level route + bitstream, timing met at 50 MHz (WNS +5.920 ns), ~5 min |
| **On the board** | 2026-10-17, programmed from Windows (Lab Edition 2025.2), core at 50 MHz: "hello from rv32i", "sum 1..100 = 5050", then the count printing continuously with LD4-LD7 counting in binary. All three first-light goals seen; photo in [img/fpgafirstlight.webp](img/fpgafirstlight.webp) (Phase D's photo box; sideways and low-resolution, retake for the README) |
| CI on push | green (lint + sim + formal) at `1b14a14`, run 38999736331; first-light work not yet pushed |

### Implemented, and what to know before touching it

All RTL lives in `rtl/core/` (`riscv_core`, `_decoder`, `_branch`, `_hazard`,
`_mem_align`, `_alu`, `_regfile`); the code and its comments are the detail.
Only the facts that are not obvious from reading it:

- **Both memories are external ports, synchronous read, BRAM-timed.** The core
  presents `pc_next` to IMEM so the BRAM and the pc latch the same address on
  the same edge. Load data is not re-registered in MEM/WB.
- **Branches and jumps resolve in EX**, static not-taken: taken costs two
  cycles, not taken none. A jump's link address replaces the ALU result going
  into EX/MEM. Forwarding selects are decided in ID and registered into ID/EX.
- **Every exception halts the core** (ECALL, EBREAK, misaligned access, taken
  misaligned target); `halt_o` is sticky until reset. FENCE is a NOP.
- **Encodings outside RV32I decode inert** (CSRs, MRET, WFI, illegal words): no
  write, no memory access, no redirect, no halt. Half-working would surface
  later as a riscv-formal mismatch that reads like a forwarding bug.
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
- **Firmware** (`sw/firstlight/`, `make fw`): no libgcc, so no `*`, `/`, `%`
  in C (RV32I has no M). `hello_sim.hex` has a 20-iteration delay for sim.
- **Testbench:** `feed()` assumes no stall, so anything with a load-use pair
  goes through `run()`. `test_core` checks every retirement against the golden
  model (`tb/cocotb/rv32i_model.py`) through RVFI; `SEED=n` reruns a seed.
  `test_riscv_tests.py` runs upstream rv32ui with our own env
  (`sw/riscv-tests-env/`); 2 of 42 excluded: `fence_i` (Zifencei) and `ma_data`
  (expects misaligned support; this core traps).

### Not started

UVM, TMR, the rest of hardware bring-up (Dhrystone/IPC, ILA), all of Stage 2.

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

Device totals for the percentages: 63,400 LUT / 126,800 FF / 135 BRAM /
240 DSP.

### Reading these numbers

**Fmax here is not a board number.** Out-of-context leaves `HD.CLK_SRC` unset,
so Vivado cannot estimate clock delay or skew. Read it as the core's logic
limit. A real board number arrives with the Arty A7 top and gets its own table;
measurement conditions travel with the measurement.

**The critical path is the same family every time:** `mem_wb` writeback select
or load lane select → writeback mux → forwarding mux → branch comparator carry
chain → `redirect` → IF/ID flush and ID/EX bubble clear, 9-11 levels, about 75%
routing. Two levers remain: the IF/ID flush fanout (needs a valid bit rather
than a bit clear; see Next up), and the load data on the MEM/WB forward, which
on the board starts at a BRAM's ~2 ns clock-to-out.

**The out-of-context slack is optimistic.** Three paths that matter on the board
cross the core's ports and are untimed here (no output delays are set):
`pc + 4` / stall mux → `imem_addr_o`; the stall comparator and the whole
branch-resolution path → `imem_addr_o`; and `dmem_rdata_i` → load alignment →
writeback mux → forwarding mux → ALU. The board-level run will say whether
100 MHz survives.

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

The critical path is the one the OOC flow could not time: a block RAM's output
through the core to the data RAM's address, 13.4 ns, 12 levels, 64% routing.
100 MHz needs ~4 ns off it; that is a measured slice of its own. Hold slack is
+0.064 ns (MEM/WB rd address → regfile LUTRAM write address): positive, thin.

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
| `make impl` | board-level synth + route + bitstream (`syn/impl_arty.tcl`), reports `docs/reports/*_board.*`; refuses a missing RAM image, writes no bitstream if timing fails | working |
| `make synth` | OOC synth + impl of the core, reports to `docs/reports/` | working |
| `make prog` | Arty attached to WSL (usbipd): programs it with `openFPGALoader -b arty_a7_100t`; otherwise prints the Hardware Manager steps and the Windows path | working, both routes tried on the board |
| `make formal` | SymbiYosys over every `tb/formal/*.sby`, all tasks, then `scripts/riscv-formal.sh` (checks + covers, verdicts read from status files); appends OSS CAD Suite's `bin/` to PATH itself; `FORMAL_JOBS=n` | working |
| `make uvm` / `asic` | — | stubs that name their phase and what they wait on |

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

> **Resume here (2026-10-17, first light done).** The core runs compiled C
> on the Arty at 50 MHz: greeting, sum and an endless count over the UART,
> LEDs counting. Programmed from Windows with Lab Edition 2025.2, terminal
> PuTTY at 115200 8N1. Both programming routes work (2026-10-17): Windows
> Hardware Manager, and WSL via `usbipd attach` + `make prog`
> (openFPGALoader), UART on `/dev/ttyUSB1`. **Next**, per the plan: Phase C
> (UVM), with Phase B's remaining items (§2) and Phase D's other
> boxes (Dhrystone/IPC, ILA, 100 MHz) after.
>
> **Plan agreed 2026-10-10:** finish the last property, then go straight to
> a **first-light board bring-up (§3 below) before starting Phase C**. Goal:
> see it run on the Arty A7: LEDs blink, text prints over UART, a simple
> program runs. This is an early slice of Phase D, not a phase skip. Phase C
> (UVM) follows, and Phase D's remaining boxes (Dhrystone/IPC, ILA, photo)
> come after that as planned.

### 1. Timing: IF/ID flush via the valid bit

The current critical path ends in the IF/ID flush (fo 95). The valid bit now
exists, but only under `RISCV_FORMAL`; moving `if_id_valid` into the core
proper and gating decode with it would let a redirect clear one bit instead of
64. Its own measured slice.

### 2. Formal, continued (Phase B)

riscv-formal passes: 37 instruction checks plus `reg`, `pc_fwd`, `pc_bwd`,
`unique`, `causal`, each non-vacuous (covers or planted faults). Open, in
rough order:

- §5.5's hand-written properties are all done, in
  [formal-properties.md](formal-properties.md): stall correctness (S1–S4),
  forwarding (F1/F2/L1, with invariant R1), reset commits nothing (X1),
  branch-flush correctness (B1/B2), no regfile structural hazard (SH1), and
  no X into committed state (XP by induction, XT bounded to depth 10).
- Show `pc_bwd` and `causal` failing on a planted fault.
- Decide `liveness`/`hang` (fairness, and what liveness means once halted)
  and `ill` (needs a legality decoder, or a reasoned exclusion).

### 3. Board-level top: first light (done 2026-10-17)

Scheduled ahead of Phase C (see the plan under "Resume here"). Done when all
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

*Last updated: 2026-10-17 — first light on the Arty A7: the core runs
compiled C at 50 MHz, printing over the UART and counting on the LEDs; photo
committed. Both programming routes work: Windows Hardware Manager, and WSL
via usbipd-win + `make prog` (openFPGALoader). Next: Phase C (UVM).*
