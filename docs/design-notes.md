# Design notes

What to know before touching each block: facts the code does not make
obvious, the toolchain, CI, build targets and the decisions behind them.

## Implemented, and what to know before touching it

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
- **Bootloader** (`sw/boot/`, `make boot`; the default `FW_IMAGE` since
  2026-10-18): the first 4 KiB of RAM; programs (`sw/apps/`, `make apps`,
  console library `sw/lib/`) link at 0x1000 and return to it. Protocol:
  "RVLD", length, CRC-32, image (`scripts/load.py`). The last good image's
  length and CRC sit at 0x0FF4-0x0FFF for `r` (rerun). **Opening the serial
  port resets the Arty** (FTDI DTR reaches its reset), so a terminal or the
  loader always lands in the bootloader; load.py waits for the banner before
  sending, because the receiver buffers one byte and the bootloader is not
  listening while it prints.
- **Programs keep a pristine copy of `.data`** in their image (`sw/app/link.ld`)
  and crt0 copies it out, so a program never writes its own image: `r`'s CRC
  check stays valid and a rerun starts from fresh initial values. Found when
  the demo's one initialised global made every rerun fail the CRC.
- **The receiver buffers one byte.** Keys arriving while a program is busy
  printing are lost (a pasted line, or a test sending before the prompt has
  finished; test_demo waits for the whole prompt). A FIFO would fix it.
- **Demo reel** (`sw/demo/`, built `-Os`: at -O2 it does not fit with its
  10 KiB scratch buffer). Simulation runs its image preloaded
  (`scripts/mkimage.py`, `boot_demo_sim.hex`) with the UART at CLK/16.
- **TMR** (`rtl/tmr/`, `soc.sv` `TMR = 1`): the core's `VOTED` parameter makes
  it load the voted next pc, halt flags and register-file write (`vote_*_i`)
  instead of its own; with 0 (every other use) they are ignored. The voter
  sees each copy's 143-bit bundle of what it would commit, with store data,
  write data and the data address masked unless used (`dmem_re_o` exists
  for this): unmasked, a copy reading a flipped but irrelevant register
  counted as a mismatch. The core sits at `g_cpu.u_core` in the SoC either
  way (generate block); floorplan and GUI scripts colour a TMR build by
  copy. Vivado reads the copies' names (`g_other[1]`) as globs in a
  `get_cells` filter: match them as plain strings.
- **The live injector** (`riscv_core_tmr` `inject_pc_i`, soc.sv's TMR
  register, registered a cycle) XORs into copy B's `vote_pc_i`, so it is a
  real one-cycle fault in B's pc flop with no change to the core. **A flip
  two cycles after the store lands while a taken branch is in EX is masked**
  (the redirect replaces pc + 4): with the store right before the sieve's
  loop branch, 1,887 flips gave 1 detection. Demo 7 follows the store with
  two nops. One flip can be two disagreements (fetch address, then a branch
  target from the wrong pc), so the demo counts flips the counter moved for.
  `soc_tmr:test_demo` runs only `test_tmr` and, injecting, has no assertions.
- **Programs get 1 KiB of stack** (`sw/app/link.ld`, was 2 KiB): the demo
  reel's deepest chain (Hanoi, 8 levels, then printf) is about 660 bytes by
  `-fstack-usage`, GCC 13 and 16 alike. With demo 7 (repeating, 2026-10-18), 1160 bytes are
  left under GCC 16 and **1060 under CI's GCC 13**, whose code is ~100 bytes
  larger (its first push failed here). Ubuntu 24.04's package unpacks
  without root (`apt` .debs, `dpkg -x`) to check a size before pushing.
  More demo code means shrinking the scratch buffer.
- **The fault campaign's build has no assertions** (`-DFORMAL --assert` off
  for `test_tmr_faults`): an injected fault breaks the very invariants the
  in-RTL properties check. Mismatch is sampled just before each edge: the pc
  vote can correct a flip at the next edge, leaving no mismatch to see after
  it. The register file is cleared per trial (it has no reset).
- **DMA register slave choices not in DMA-Engine's spec:** a write without all four strobes changes nothing and answers SLVERR (rule 1, 32-bit only; the core cannot see SLVERR, so drivers must use `sw`); unmapped offsets read 0, answer OKAY (as the model). RING_BASE_HI, RING_SIZE, TAIL, IRQ_MASK store all 32 bits because the model reads them back. In a write's commit cycle an engine set beats a W1C clear, and CTRL.RESET beats every engine report. **DMA-Engine's package sits outside `rtl/`**: every source list (both Makefiles, `synth_ooc.tcl`, `impl_arty.tcl`, `gui_view.tcl`, `make asic`'s `RTL`) prepends `sw/dma-engine/rtl/dmaeng_pkg.sv`; its unused constants are waived for that file only (`tb/lint/waivers.vlt`, also passed to the cocotb build). **`make asic` with it is untested** (LibreLane's own Verilator lint may object); check before run #2.
- **M unit (`riscv_muldiv`):** the core sees a handshake, not a latency: `valid_i` (an M instruction in EX, operands valid; sampled only when idle, operands captured then, so forwarding may move on), `done_o` held with the result until `ack_i` (the instruction leaves EX; a MEM_WAIT hold can delay it). No kill input: a branch resolves in EX and squashes only younger instructions, so nothing in EX is ever squashed (recheck when integrating). Signed divide by zero is the only corner case needing logic (quotient stays all ones); INT_MIN / −1 falls out of restoring division on magnitudes. **Formal runs at XLEN = 8 with bitwuzla**: yices stalled for minutes on the first multiply result; the arithmetic properties sit under `MULDIV_ARITH`, not `FORMAL`, so the core's proofs never see a 32-bit `/`. The latency and handshake properties are under plain `FORMAL` and run in every cocotb build. Product sum leaves the unit unregistered (6.5 ns register to register, measured).
- **DMA engine limits, by design, documented in `test_dmaeng.py`:** a bus error part-way through a copy leaves the destination partly written (the model writes all or nothing); an overlapping copy is a memmove only within one 64-byte chunk. Out-of-range addresses (HI words, past 2^32) are caught before any bus access, so they match the model exactly. During a CTRL.RESET drain STATUS.BUSY already reads 0. `DATA_W` is a parameter, but only 32 elaborates (`$error` otherwise). Descriptor word offsets are typed in `dmaeng_desc.sv` (the package lacks them; the header has them and the test builds descriptors from the header): worth asking DMA-Engine's generator for `DESC_OFF_*` in the package.
- **MEM_WAIT (2026-11-04):** `hold` is a whole-core clock enable: every pipeline register, the pc, halt flags, RVFI shadows and the properties' "previous cycle" flops keep their value, and stores, loads, register writes and retirements are gated, so a held cycle is an edge that never happened (forwarding, flushes and traps need no change). Fetch presents `pc` while held. Contract: a load's data is on `dmem_rdata_i` in the cycle ready is high again; a BRAM wired straight to the port meets it only if ready never drops with a BRAM load in MEM, so the bridge lowers ready only for its own access. Verified: `riscv_core_wait` / `riscv_core_tmr_wait` (cocotb, 30% random holds): random programs and rv32ui 40/40 against the model, plus `test_hold_commits_nothing` (49 holds of 12 cycles, nothing commits or moves); `test_ready_ignored_without_mem_wait` on the plain builds. 8 planted hold bugs: 7 caught, 1 equivalent (halted_q setting during a hold is invisible: pc is held, and a redirect beats freeze). **TMR + MEM_WAIT misses 100 MHz OOC by 46 ps** on the voter's mismatch compare (copy → compare → `mismatch_q`, the TMR critical path since Phase E, 22-23 levels), not on the hold; its baseline in the same run had +0.049 ns. Board number when the SoC builds with it. Formal with MEM_WAIT = 1 not yet run.
- **Formal with MEM_WAIT** (`core.sby`): `prove_wait` (k-induction, depth 20, ~3.5 min) proves every property plus H1 ("a held cycle changes nothing": pipeline registers, pc, halt, retirement count unchanged; nothing commits) with holds anywhere but one cycle at a time (`core_formal.sv` HOLD1); with H1 that covers any hold length. Without HOLD1, induction cannot close (a window can be all holds). `bmc_wait`: holds fully free, BMC depth 14 (~1.6 min; each step doubles: 0-15 passed, 16 ran > 10 min). `cover_wait`: a hold meets a stall, a redirect, a trap, a pending writeback. **riscv-formal still runs with ready tied high** (gap; the RVFI checks under holds come from cocotb).
- **TMR mismatch counter (2026-11-05):** counts from the three bundles registered, then compared and registered (`riscv_core_tmr.sv`): copy → compare → flop was the TMR critical path since Phase E and failed the board at 100 MHz once the crossbar joined (−0.260 ns). Board TMR now +0.123 ns for +429 FF. The count lags `mismatch_o` by two cycles; the vote, `mismatch_o` and `disagree_o` are unchanged, and demo 7 judges detection at the next flip.
- **Engine timing:** the chunk size (min of four) is registered alone; beat counts derive from it. Registering both in one cycle missed 100 MHz (−0.414 ns, 16 levels). The worst path is still that min chain (9.4 ns, 15 levels): pipelining it is the next lever.
- **UART RX reads have no side effect; a write acknowledges.** The core's
  data port has no read enable, so the SoC cannot tell a load from an
  address in passing. `UART ST` bits: 0 TX ready, 1 RX byte, 2 overrun, 3
  framing error.
- **Linker scripts align `.bss`.** crt0 zeroes it a word at a time, and a
  misaligned store halts this core: the bootloader's first build did exactly
  that (its code ended on an odd byte).
- **Testbench:** `feed()` assumes no stall, so anything with a load-use pair
  goes through `run()`. `test_core` checks every retirement against the golden
  model (`tb/cocotb/rv32i_model.py`) through RVFI; `SEED=n` reruns a seed.
  `test_riscv_tests.py` runs upstream rv32ui with our own env
  (`sw/riscv-tests-env/`); 2 of 42 excluded: `fence_i` (Zifencei) and `ma_data`
  (expects misaligned support; this core traps).


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
| **LibreLane + Sky130** | 3.0.16 (tag; Yosys 0.62 inside) | `~/librelane`, run inside `nix-shell ~/librelane/shell.nix` (Nix 2.35.3, FOSSi binary cache in `/etc/nix/nix.custom.conf`); sky130 PDK `8afc834` fetched by ciel to `~/.ciel` (2.2 GB). `librelane --smoke-test` passed 2026-10-18. Nix's own tools: `/nix/store`, 5.2 GB |
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
| `make boot` | the serial bootloader → `sw/build/boot.hex`, the default bitstream image | working |
| `make apps` | programs in `sw/apps/` and the demo reel (`sw/demo/`) → `sw/build/apps/*.bin`, for `scripts/load.py <bin> [--term]` (`--term` stays as a terminal; Ctrl-] quits); also `boot_demo_sim.hex` for test_demo | working |
| `make fw` | first-light firmware → `sw/build/hello.hex` (board), `hello_sim.hex` (sim) | working; local riscv32 or CI's riscv64 gcc |
| `make bench` | CoreMark (submodule `sw/coremark`, port `sw/coremark-port/`, links libgcc) → `sw/build/coremark.hex` (board, `COREMARK_ITERATIONS`=1000), `coremark_sim.hex` (1 iteration) | working, locally and in CI (the riscv64 package's rv32i/ilp32 libgcc) |
| `make impl` | board-level synth + route + bitstream (`syn/impl_arty.tcl`), reports `docs/reports/*_board.*`; refuses a missing RAM image, writes no bitstream if timing fails; `FW_IMAGE=` picks the RAM image (default the bootloader); `ILA=1` adds the ILA and its `.ltx`, reports to `syn/build/board/ila_reports/` so `docs/reports/` stays ILA-free; `TMR=1` builds three voted cores, reports `*_board_tmr.*` | working |
| `make synth-dma` | OOC synth + route of `DMA_TOP` (default `dmaeng_regs`), reports `docs/reports/*_ooc_<top>.*` | working |
| `make synth-muldiv` | OOC synth + route of the M unit alone (`rtl/core/riscv_muldiv.sv`), reports `*_ooc_riscv_muldiv.*` | working |
| `make synth-wait` | OOC synth + route of the core and the TMR core with MEM_WAIT = 1, reports `*_ooc_wait.*`, `*_ooc_tmr_wait.*` | working |
| `make synth` | OOC synth + impl of the core, then of the TMR core (`*_ooc_tmr.*`, with the three-copy check), reports to `docs/reports/` | working |
| `make prog` | Arty attached to WSL (usbipd): programs it with `openFPGALoader -b arty_a7_100t`; otherwise prints the Hardware Manager steps and the Windows path | working, both routes tried on the board |
| `make ila` | after `make impl ILA=1`, with the Arty attached to WSL: programs it and captures the pipeline registers (`syn/ila_capture.tcl`, Vivado Hardware Manager in batch) to `syn/build/board/ila_capture.{csv,vcd}`, then checks the capture (`scripts/ila_check.py`) | working |
| `make gui` | opens the last `make impl`'s routed design in the Vivado GUI (`syn/gui_view.tcl`): device view colored by module, worst path + its schematic, timing, utilization, power tabs. `VIEW=rtl`: elaborated RTL schematic. `VIEW=array`: the 16×16 array's routed checkpoint (`make synth-array`), coloured by row; `VIEW=pair`: one PE pair as elaborated RTL. `VIEW=ila`: programs an ILA build, triggers on `ILA_TRIGGER` (default `core_state_transition`; must be a function the code calls, GCC inlines some) and shows waveforms | working |
| `make floorplan` | exports placement + routing from the routed checkpoint (`syn/floorplan_export.tcl`) and draws `docs/img/floorplan_board{,_core}.svg` (`scripts/floorplan.py`); refuses an ILA build | working |
| `make faults` | the documented TMR fault campaign, `FAULTS` (10000) trials, `SEED`; summary to `docs/reports/tmr_faults.txt`. The regression runs 1000 | working |
| `make formal` | SymbiYosys over every `tb/formal/*.sby`, all tasks, then `scripts/riscv-formal.sh` (checks + covers, verdicts read from status files); appends OSS CAD Suite's `bin/` to PATH itself; `FORMAL_JOBS=n` | working |
| `make model-test` | golden models alone: C on rv32ui and rv32um (`-m`), C and Python M against `sw/model/m_vectors.txt` (host cc + RISC-V gcc) | working |
| `make m-vectors` | regenerate `sw/model/m_vectors.txt` from spike `--isa=rv32im` (10,592 vectors: edge pairs + seeded random) | working |
| `make uvm` | UVM regression in XSim (`tb/uvm/run.sh`): `SEED`, `PROGRAMS` (300), `COV_MIN` (95); fails on any UVM error or coverage below `COV_MIN` | working; local only (Vivado), like `make synth` |
| `make asic` | LibreLane run in its nix-shell (`LIBRELANE_DIR`, default `~/librelane`), `syn/asic_config.yaml`, every .sv under rtl/ passed as `VERILOG_FILES`; run in `syn/build/asic/runs/asic/` (~15 min); then `scripts/asic_summary.py` writes `docs/reports/summary_asic.txt`, `sta_asic.rpt`, `manufacturability_asic.rpt` and `docs/img/asic_layout.png`. Nix's shell: `nix-shell ~/librelane/shell.nix`; open the run with `librelane --last-run --flow openinklayout` (or `openinopenroad`) from `syn/build/asic` | working |

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

**Both jobs are pinned to `runs-on: ubuntu-24.04`** (2026-10-18), ahead of
`ubuntu-latest` becoming 26.04 on 2026-10-19. Checked with the .debs unpacked
locally: **26.04's `gcc-riscv64-unknown-elf` 15.3 ships no `stdint.h`** (it
recommends `picolibc-riscv64-unknown-elf`, which `--no-install-recommends`
leaves out), so every C build would fail there, and its assembler (binutils
2.45.50) rejected `-march=rv32i` in that check. Moving to 26.04 later means
fixing both, and the Verilator cache key (`runner.os` only) must then name the
image too, or a 24.04 build is restored onto 26.04.

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
- **The core gets a data-port wait (decided with the user 2026-11-04):**
  `dmem_ready_i` behind a parameter defaulting off, so every Stage 1 result
  stays valid; RAM stays single-cycle, peripherals go through a real AXI4-Lite
  bridge and interconnect at any latency. Chosen over a fixed-latency bridge
  because Phase H's clk_array CDC and the Doom finale's DDR + cache both need
  a core that can wait. Costs: formal, UVM and TMR rerun with stalls; the
  freeze's fanout measured against the TMR board's +0.095 ns.
- **The ASIC flow is LibreLane, not OpenLane** (the successor to OpenLane 2).
  Open: whether LibreLane has built-in scan insertion (§6.5); check in Phase H.
- **Array clock domain (Phase H box 2; decided 2026-11-07, not yet built).**
  **Only `systolic_array` moves to `clk_array`**; the sequencer, buffers and
  registers stay on the core clock. Why: P5 overclocks `clk_array` to provoke
  setup errors *in the array* and sweeps it by DRP with "stop the array → hold
  `clk_array` in reset → reprogram → LOCKED → flush the CDC FIFOs → release";
  P7 swaps the array by DFX. Moving the whole engine would put the sequencer's
  control under overclocking (hangs, not arithmetic errors) and split the
  buffers across clocks. Rejected for that. Plan, in slices, each measured:
  1. **CDC primitives first**, in `rtl/cdc/` (none exist yet): async FIFO
     (gray pointers, 2-flop synchronizers, `ASYNC_REG`), a pulse/handshake
     synchronizer, a reset synchronizer (async assert, sync release in the
     destination domain). cocotb with two unrelated clocks (ratios above and
     below 1, random phase); formal with `multiclock on` (no loss, no
     duplication, order, full/empty never lie). Bug injection: binary instead
     of gray pointer, one sync flop, reset released asynchronously.
  2. **Golden model first** (`sw/model/accel_model.py`): with CDC, CYCLES is no
     longer a fixed formula in core cycles; model a lower bound (the formula)
     and what a slower `clk_array` costs; results stay bit-exact.
  3. **The stream**: the sequencer pushes **exactly the input it drives today,
     one entry per core cycle while busy, bubbles included** ({valid, swap,
     w_shift, a, w}, ~259 bits at 16×16) into an async FIFO; the array side
     pops one entry per `clk_array` cycle and feeds a bubble when empty. Extra
     bubbles only lengthen gaps, so the swap/shift spacing the array needs
     (shadows still for ROWS + COLS/2 − 2 array cycles after a swap) holds
     whatever the clock ratio, because the spacing is carried as entries, not
     time. The sequencer stalls whole when the FIFO is (almost) full: the
     BRAM read in flight lands in the slack. **Results**: valid rows (512 bits)
     into a second async FIFO; the array cannot be stalled, so the sequencer
     holds **credits** (rows sent − rows received ≤ depth) and never sends a
     row the output FIFO could not take. C accumulation becomes pop-driven
     (read C on pop, add and write next cycle, 1 row/cycle). The weight-
     transform hook (box 3) sits on the array side of the input FIFO.
  4. **Parameter** `ARRAY_CDC`, default 0: the direct path, cycle-exact, so
     every Phase G result and the CYCLES-equals-model tests stay valid (the
     MEM_WAIT / M_EXT pattern). The soc-v2.0 board build sets it, with
     `clk_array` from its own MMCM output (100 MHz by default),
     `set_clock_groups -asynchronous`, and `report_cdc` clean.
  5. Then box 4 (DRP registers) and the 80-vs-100 MHz regression and board run.
  Above core clock the array gains nothing (fed one row per core cycle);
  that is fine for P5, whose point is the errors, not the speed.


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

