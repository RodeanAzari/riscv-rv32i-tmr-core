# Progress Log

Running context for this project. Read this first at the start of a session to
know where things stand. Update it at the end of any session that changed
meaningful state.

**Repo:** https://github.com/RodeanAzari/riscv-rv32i-tmr-core (private)
**Local:** `~/riscv-rv32i-tmr-core`
**Phase:** B (formal) **done** 2026-10-17: every §5.5 property by k-induction, riscv-formal 46/46 with each check reached or shown to fail. C (UVM) **done** 2026-10-17: 205/205 coverage bins, every retirement checked against a C golden model. D (hardware) **done** 2026-10-18: 100 MHz on the Arty A7, CoreMark 0.962 CoreMark/MHz, IPC 0.691, serial bootloader and six interactive demos. E (TMR) **done** 2026-10-18: three voted copies with feedback, voter proven, 10,000-fault campaign with 0 failures, 100 MHz on the board, live fault injector on the board (250,971 flips over 133 runs, same answer, same cycles); LibreLane run #1 closes at 35 ns at all 9 Sky130 corners, DRC/LVS clean (31.7 MHz worst case). **Stage 1 complete.** Phase A **done** 2026-10-08, CI run 37817380686

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
| `make sim` | 308/308 passing across 19 entries (core, TMR core ×2, alu, regfile, decoder, mem_align, hazard, branch, uart_tx, uart_rx, soc ×4, TMR soc ×4), including the 40 official `riscv-tests`, the first-light firmware, one CoreMark iteration on the whole SoC (CRCs checked, IPC counted through RVFI, ~50 s) the bootloader receiving a program over the RX pin (~100 s), the six demos each checked against a Python model (~20 min, 9 of it one software-float Mandelbrot frame, which CI skips), the fault-injection demo, stopped after 3 passes (on TMR: 5,661 flips, all detected, answer and cycles unchanged every pass), and on the TMR core: the core's 105 tests, a 1000-fault campaign (0 failures required, pipeline faults must recover), first light, CoreMark and the bootloader with zero mismatches; UART decoded at 115200 |
| `make synth` | routes clean, 0 errors, ~40 s |
| `make formal` | the TMR voter (V1-V4, every input) and x0 invariance, stall correctness (S1–S4), forwarding (F1/F2/L1), reset-commits-nothing (X1), branch-flush correctness (B1/B2), no regfile structural hazard (SH1) and no X into committed state (XP) proven by k-induction, XT by BMC to depth 10; **riscv-formal 46/46 checks and 46/46 cover runs** (37 `insn`, `reg`, `pc_fwd`, `pc_bwd`, `unique`, `causal`, `causal_mem`, `liveness`, `hang`, `ill`), ~6 min (XT's BMC is ~5 of it) — see [formal-properties.md](formal-properties.md) |
| `make impl` | board-level route + bitstream, timing met at 100 MHz (WNS +0.948 ns with the UART receiver), ~2 min |
| `make model-test` | the C golden model alone: rv32ui **40/40**; a planted SRA bug fails exactly `sra` |
| `make uvm` | XSim, 300 random programs, ~45 s: **205/205 coverage bins (100%)** on seeds 1, 2, 3, ~45,000 retirements each compared with the model, 0 mismatches. Planted RTL faults caught: forwarding priority (in the hazard unit), LBU sign-extending, no rs2 load-use stall |
| **On the board** | 2026-10-17, programmed from Windows (Lab Edition 2025.2), core at 50 MHz: "hello from rv32i", "sum 1..100 = 5050", then the count printing continuously with LD4-LD7 counting in binary. All three first-light goals seen; photo in [img/fpgafirstlight.jpg](img/fpgafirstlight.jpg), which with the demo video in the README closes Phase D's photo box (the user's choice: it shows the board and the screens at first light) |
| **CoreMark on the board** | 2026-10-17, 2000 iterations at **100 MHz** (`make prog` from WSL): **0.962 CoreMark/MHz, about 96 CoreMark**, "Correct operation validated", 2,077,692,270 cycles ([coremark_board.txt](reports/coremark_board.txt)); the 50 MHz run before the clock change gave the same cycles per iteration. **IPC 0.691** (CPI 1.447) over the timed region, counted in RTL simulation of the same SoC ([coremark_sim.txt](reports/coremark_sim.txt)); simulated cycles per iteration match the board's to 0.0013%. RV32I without M: every multiply and divide is a libgcc call |
| **ILA on the board** | 2026-10-17, `make impl ILA=1` then `make ila` from WSL (Hardware Manager in batch through `hw_server`): 13 probes, 328 bits (pc and instruction of all four pipeline registers, EX/MEM ALU result, writeback, halt), depth 1024, core clock. First-light program: every EX→MEM→WB shift consistent, 227 stall cycles and 114 flush bubbles in the window ([ila_summary.txt](reports/ila_summary.txt), [ila_capture.csv](reports/ila_capture.csv)). ILA build (at 50 MHz, before the clock change): +2233 LUT, +3772 FF, +10 BRAM, WNS +4.162 ns ([summary_board_ila.txt](reports/summary_board_ila.txt)). CoreMark at 100 MHz with the ILA (WNS +1.066 ns), triggered on `core_state_transition`: stage shifts consistent, 881 retirements in 1023 cycles ([ila_coremark_summary.txt](reports/ila_coremark_summary.txt), [ila_coremark.csv](reports/ila_coremark.csv)) |
| **Bootloader on the board** | 2026-10-18: `scripts/load.py sw/build/apps/echo.bin` loads 1760 bytes over the UART in about 0.2 s; the program echoes keys, returns to the bootloader on q, and `r` reruns it without resending. Changing the program needs no Vivado rebuild |
| **Demo reel on the board** | 2026-10-18, `sw/demo/` loaded over serial ([demo_board.txt](reports/demo_board.txt)): microbenchmarks measure exactly 1 cycle per ALU op, +1 per load-use, +2 per taken branch or jump, 0 for not taken; Mandelbrot frame 12,849,963 cycles fixed point vs 49,110,978 software float (3.8x; simulation gives the same counts, and both pictures match a bit-exact model, IEEE single included); 750 digits of pi in 4.95 s; Life 81,581 cycles a generation; sieve to 163840 in 16.0 ms |
| **TMR** (Phase E) | 2026-10-18: `rtl/tmr/riscv_core_tmr.sv`, three copies with `DONT_TOUCH`/`KEEP_HIERARCHY` (three survive: 1601 cells each, `summary_ooc_tmr.txt`), voted feedback into each copy's pc, halt flags and register file. The voter is proven (`tmr_voter.sby`). The core's 105 tests and the SoC's first light, CoreMark and bootloader tests pass on it with zero mismatches. **Fault campaign, 10,000 single-bit flips** ([tmr_faults.txt](reports/tmr_faults.txt)): 0 failures; 1,275 detected, all corrected and all three copies identical again; median disagreement 1 cycle, max 30; 5,777 register-file flips latent in registers the programs never use. Board: 100 MHz met, WNS +0.095 ns, 3.1x LUT, Fmax −8.7%. **Live injector on the board** (2026-10-18, [tmr_inject_board.txt](reports/tmr_inject_board.txt)): demo 7 repeats a sieve to 163840 until a key, flipping a random bit of copy B's pc 1,887 times a pass: 133 passes, each 14,999 primes and 3,354,864 cycles, exactly as the clean run; all 250,971 flips detected; the same counts in simulation (`soc_tmr:test_demo`). Totals on screen, disagreements / 4096 on the LEDs. The plain demos still exact on the TMR bitstream |
| **GEMM golden model** (Phase F) | 2026-10-18, before any RTL: `sw/model/gemm_model.py`, `make gemm-model` (run first by `make sim`): INT8 GEMM with INT32 wraparound, a cycle-level weight-stationary array (feeder pads zeros; row m leaves column c's bottom at cycle m + ROWS − 1 + c), and requantization. 1,449 checks: PE exhaustive (65,536 pairs × 4 psums), gemm against plain Python ints, the array against gemm on 1,320 shapes at 4×4, 8×8, 16×16, 4×8, 8×4, saturation boundaries, INT32 wraparound at K = 131,073, requantization against exact fractions (ties, extremes). Four planted model bugs each caught. ~22 s |
| **Systolic PE** (Phase F) | 2026-10-18: `rtl/accel/systolic_pe.sv`, INT8 × INT8 + INT32 psum, activation registered right, psum registered down; weights double-buffered (a shadow register shifts down the column while the current tile computes, `w_swap_i` makes it active the next cycle). `systolic_pe:test_systolic_pe`: all 65,536 (activation, weight) pairs back to back against `gemm_model.pe`, psums at 0, ±1, both INT32 limits and random, weight swaps with no idle cycle; reset test. Two planted bugs caught (using the shadow weight early; zero- instead of sign-extending the product). In `make lint` as its own top. ~6 s |
| **Systolic array** (Phase F) | 2026-10-18: `rtl/accel/systolic_array.sv`, ROWS × COLS PEs (default 4×4): input skew (row r delayed r cycles) and output deskew (column c delayed COLS − 1 − c), so a row of A goes in as one vector and its results come out as one vector LATENCY = ROWS + COLS − 1 edges later, with `valid_o`. The weight swap rides with the data (PE `w_swap_o`), so each PE switches right after the tile's last row passes it; the shadows must hold until it reaches the last PE (ROWS + COLS − 2 cycles). Edge padding and summing tiles along K are the feeder's and output buffer's (Phase G/H); the test plays both. `test_systolic_array` at **4×4, 16×16 and 4×8**: 2,000 / 1,000 / 2,000 random GEMMs (shapes up to 3× the array, multiples and not), 9 edge shapes (1×1×1, one past and one short of a tile, …), 5 saturation jobs (every product ±16,384 or −16,256, alternating extremes); every element matches `gemm_model.gemm`, every row arrives exactly LATENCY edges after it entered. Four planted bugs caught (input skew, output deskew, broadcast swap, swap dropped below row 0). ~5 s / 39 s / 14 s. Not yet run in the full `make sim` regression (the 308/308 count above predates Phase F) |
| CI on push | green (lint + sim + formal, 308/308 in one regression, on `ubuntu-24.04`) at `33e251a`, run 39162134462 (main fast-forwarded to it 2026-10-18) |

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
| 2026-10-18 | TMR feedback ports (VOTED = 0 here), `dmem_re_o`, halt flags in next-state form | 966 | 467 | 55 | +1.697 | 120.4 | −2.3 |

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
| 2026-10-18 | + UART receiver (RX register, status bits, pin A9); bootloader image (ran on the board at 100 MHz) | 1123 | 435 | 8 | 100 MHz | +0.948 | 110.5 |
| 2026-10-18 | Core with TMR feedback ports (unused), `dmem_re_o`; the single-core baseline for TMR | 1123 | 435 | 8 | 100 MHz | +0.955 | 110.6 |
| 2026-10-18 | **TMR**: three voted copies, mismatch counter (`make impl TMR=1`, `*_board_tmr.*`) | 3370 | 1589 | 8 | 100 MHz | +0.062 | 100.6 |
| 2026-10-18 | TMR + live fault injector (write to 0x1000_0014 flips copy B's pc); ran on the board at 100 MHz | 3446 | 1621 | 8 | 100 MHz | +0.095 | 101.0 |

At 50 MHz the critical path was the one the OOC flow could not time: a block
RAM's output (load data) through alignment, the forwarding mux and the branch
comparator to the RAM's fetch address, 14.2 ns, 11 levels, 68% routing (13.4
ns at first light). Accessing data memory from EX removed it; at 100 MHz the
worst path is forwarding select → branch comparator → redirect → pc mux →
fetch address, 7.8 ns, 7 levels, 74% routing. The note below on the 50 MHz
build's hold slack is history; that is a measured slice of its own. Hold slack is
+0.064 ns (MEM/WB rd address → regfile LUTRAM write address): positive, thin.

---

## TMR cost (Phase E)

Same RTL, same conditions, single core against three voted copies.
`make synth` (OOC, 10.000 ns) builds both; `make impl` and `make impl TMR=1`
the board. Reports: `summary_ooc{,_tmr}.txt`, `summary_board{,_tmr}.txt`;
the three copies' cell counts are in `summary_ooc_tmr.txt` and
`utilization_ooc_tmr_hier.rpt`.

| Date | Conditions | Single LUT / FF | TMR LUT / FF | LUT × | FF × | Single Fmax | TMR Fmax | Fmax penalty |
|---|---|---|---|---|---|---|---|---|
| 2026-10-18 | out of context, core alone | 966 / 467 | 3658 / 1450 | 3.79 | 3.10 | 120.4 MHz | 101.3 MHz | −15.9% |
| 2026-10-18 | board, whole SoC, 100 MHz | 1123 / 435 | 3370 / 1589 | 3.00 | 3.65 | 110.6 MHz | 100.6 MHz | −9.0% |
| 2026-10-18 | out of context, core alone, + injector port | 966 / 467 | 3690 / 1450 | 3.82 | 3.10 | 120.4 MHz | 101.4 MHz | −15.8% |
| 2026-10-18 | board, whole SoC, 100 MHz, + injector | 1123 / 435 | 3446 / 1621 | 3.07 | 3.73 | 110.6 MHz | 101.0 MHz | −8.7% |

LUT and FF here are cell counts, as in the trend tables. By the hierarchical
report (slice LUTs, `utilization_ooc_tmr_hier.rpt`), the three copies are
892 each and the voter 600 (891 and 599 before the injector): a 2-of-3 vote and a compare over each copy's
143-bit bundle of next state. The TMR
critical path is copy → mismatch compare → its register: the compare tree
is deep. Counting from mismatch_o directly made the counter's enable the
critical path (OOC −0.386 ns); registering it first gave +0.126.

## ASIC (LibreLane + Sky130, CLAUDE.md §6.4)

Separate from every FPGA table (§10: different targets, never one table).
`make asic`: LibreLane 3.0.16 classic flow on `riscv_core` alone (non-TMR,
VOTED = 0), sky130A `sky130_fd_sc_hd`, block-level (memory ports are pins,
no pads, no SRAM; register file as 1024 flops), FP_CORE_UTIL 40, I/O delay
20% of the period, slang frontend (`syn/asic_config.yaml`). Signoff over 9
corners; "worst" is the worst of them, here always max_ss_100C_1v60. Numbers
from `docs/reports/summary_asic.txt` (generated by `scripts/asic_summary.py`).
Append-only.

| Date | Run | Clock | Die µm² | Std-cell µm² (util) | Cells (seq) | Setup WS worst | Reg-to-reg WS worst | Fmax worst, I/O incl. / reg-to-reg | Fmax typical | Power (tt) | DRC / LVS | Max slew viol. |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-18 | #1, PnR optimized at tt only (LibreLane default) | 25 ns | 227,997 | — | — | −4.705 ns | +3.283 ns | 33.7 / 46.0 MHz | 58.0 MHz | 6.42 mW | clean / clean | 2805 |
| 2026-10-18 | #1, PnR at tt + max_ss + min_ff | 25 ns | 227,997 | 123,272 (58.2%) | 13,168 (1,496) | −4.679 ns | +3.240 ns | 33.7 / 46.0 MHz | 58.0 MHz | 6.42 mW | clean / clean | 2689 |
| 2026-10-18 | #1, 35 ns, PnR at tt + max_ss + min_ff | 35 ns | 227,997 | 123,291 (58.2%) | 13,180 (1,496) | −0.973 ns | +9.199 ns | 27.8 / 38.8 MHz | 47.0 MHz | 4.59 mW | clean / clean | 2778 |
| 2026-10-18 | #1, 25 ns, clock delay cells excluded, GRT_ADJUSTMENT 0.26 | 25 ns | 227,997 | 119,277 (56.3%) | 13,853 (1,496) | −4.498 ns | +3.339 ns | 33.9 / 46.2 MHz | 59.1 MHz | 6.44 mW | clean / clean | 3091 |
| 2026-10-18 | **#1, 35 ns, clock delay cells excluded (committed reports, closes)** | 35 ns | 227,997 | 119,277 (56.3%) | 13,853 (1,496) | **+3.502 ns** | +13.339 ns | 31.7 / 46.2 MHz | 50.6 MHz | 4.60 mW | clean / clean | 3091 |

**Run #1 closes at 35 ns** with the clock delay cells excluded: 0 setup
and 0 hold violations at all 9 signoff corners, worst setup slack +3.502 ns
(max_ss, `imem_addr_o`), DRC/LVS/antenna clean. Worst-case Fmax 31.7 MHz
counting the 20% I/O budget, 46.2 MHz register-to-register; the placed and
routed netlist is the same as the 25 ns exclusion run (same cells, area and
wirelength), only the constraint differs. Open, not blocking: 3,091 max-slew
violations (0.75 ns limit, mostly at ss on weak `buf_1` fanout buffers) and
the fetch-address path, which a 25 ns target at ss would need fixed in RTL.
The rows above are the way there.

**The 25 ns runs did not close timing at the slow corner.** All 90 setup
violations are register-to-output: the fetch-address path (forwarding select
→ comparator → redirect → pc mux → `imem_addr_o`), the same critical path as
on the FPGA, here owing 20% of the period to the memory outside the block
and launched 2.3 ns late by the clock tree. Register-to-register meets at
every corner. Typical meets with +7.75 ns. Optimizing the slow corner during
PnR changed almost nothing (`RSZ-0062 unable to repair all setup
violations`). The max-slew violations (0.75 ns limit) are mostly at ss, on
fanout trees the resizer built from delay cells (`clkdlybuf4s*`,
`dlymetal*`), including the forwarding select on the critical path: 2,683
delay cells in the netlist, 1,253 of them hold buffers. Pre-layout estimate
(synthesised netlist): setup −1.464 ns, reg-to-reg +3.249 ns at nom_ss.
**35 ns did not close it either, and every path got slower** (reg-to-reg
needs 25.8 ns at ss, against 21.8 ns at 25 ns): with more slack the
resizer buffers fanout with `clkdlybuf4s25_1`, a clock *delay* cell, 1.2 to
2.4 ns per stage at ss. The worst path (fwd select → … → `imem_addr_o[28]`)
passes seven of them, about 11 ns of its 29 ns. 1,431 of them in the
netlist: 820 fanout, 546 output-port and 65 input-port buffers. Hold repair
uses a different cell (`dlygate4sd3_1`, 1,253). 15 setup violations, all
`imem_addr_o`.

**Excluding `clkdlybuf4s*` at 25 ns barely helped** (−4.50 ns, from
−4.68): at 25 ns the resizer had kept them off the worst path, so the path
is plain logic, 21.9 ns at ss (fwd select → 32-bit compare, an `or4`
chain → redirect → fanout to the 32 address bits) after 2.4 ns of clock
latency, against 19.75 ns required (25 − 5 output delay − 0.25
uncertainty). Closing 25 ns at ss needs an RTL change on the fetch-address
path. The first try of this run failed global routing on one met2 edge of
145k (GRT-0116); `GRT_ADJUSTMENT` 0.26, as OpenROAD suggested, fixed it
with DRC still clean.

Layout screenshots from KLayout (met4/met5 power grid hidden), in
`docs/img/asic/run1/`: `layout.png`, the whole block, and `layout-zoom.png`,
single standard cells with li1/met1 wiring and their names. LibreLane's own
render is not kept (the top metal covers it).

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
| `make synth` | OOC synth + impl of the core, then of the TMR core (`*_ooc_tmr.*`, with the three-copy check), reports to `docs/reports/` | working |
| `make prog` | Arty attached to WSL (usbipd): programs it with `openFPGALoader -b arty_a7_100t`; otherwise prints the Hardware Manager steps and the Windows path | working, both routes tried on the board |
| `make ila` | after `make impl ILA=1`, with the Arty attached to WSL: programs it and captures the pipeline registers (`syn/ila_capture.tcl`, Vivado Hardware Manager in batch) to `syn/build/board/ila_capture.{csv,vcd}`, then checks the capture (`scripts/ila_check.py`) | working |
| `make gui` | opens the last `make impl`'s routed design in the Vivado GUI (`syn/gui_view.tcl`): device view colored by module, worst path + its schematic, timing, utilization, power tabs. `VIEW=rtl`: elaborated RTL schematic. `VIEW=ila`: programs an ILA build, triggers on `ILA_TRIGGER` (default `core_state_transition`; must be a function the code calls, GCC inlines some) and shows waveforms | working |
| `make floorplan` | exports placement + routing from the routed checkpoint (`syn/floorplan_export.tcl`) and draws `docs/img/floorplan_board{,_core}.svg` (`scripts/floorplan.py`); refuses an ILA build | working |
| `make faults` | the documented TMR fault campaign, `FAULTS` (10000) trials, `SEED`; summary to `docs/reports/tmr_faults.txt`. The regression runs 1000 | working |
| `make formal` | SymbiYosys over every `tb/formal/*.sby`, all tasks, then `scripts/riscv-formal.sh` (checks + covers, verdicts read from status files); appends OSS CAD Suite's `bin/` to PATH itself; `FORMAL_JOBS=n` | working |
| `make model-test` | C golden model on rv32ui (host cc + RISC-V gcc) | working |
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
- **The ASIC flow is LibreLane, not OpenLane** (the successor to OpenLane 2).
  Open: whether LibreLane has built-in scan insertion (§6.5); check in Phase H.

---

## Next up

> **Resume here (2026-10-18, Stage 1 complete).** Phase E is done: TMR built
> and measured (`rtl/tmr/`, `make synth`, `make impl TMR=1`, `make faults`,
> live injector on the board), LibreLane run #1 closed at 35 ns at all 9
> corners (`make asic`), README updated with every Stage 1 result (the ASIC
> layout shots are not retaken, by the user's choice). The TMR Vivado
> set is in `docs/img/vivado/phase-e/`, beside Phase D's in the README.
> **Phase F started 2026-10-18 on branch `systolic`:** the golden model is
> done (`make gemm-model`). Decided with the user: requantization is a
> per-output-column fixed-point scale (y = acc × mult / 2^(31 + shift), mult
> in [0, 2^31), shift 0–31, round half away from zero, saturate to INT8,
> symmetric); matrices not a multiple of the array are handled by the feeder
> padding zeros (full tiles always, results outside C not written). Open for
> the RTL: a 32×32 requant multiplier per column costs ~4 DSP48E1 each, on
> top of the array's 128 (packed); decide sharing vs. width when the array
> exists. The single PE is done and verified exhaustively
> (`rtl/accel/systolic_pe.sv`). The array is done and verified at 4×4, 16×16 and
> 4×8 (`rtl/accel/systolic_array.sv`). **Next:** synthesis of the array
> (`make synth`-style OOC run) for the DSP count: 16×16 is 256 multiplies on
> 240 DSP48E1; if Vivado does not pack or the array does not fit, try a
> two-column PE that packs two weights per DSP, else drop to 8×8 (buildplan
> 6.1). Then the full `make sim` regression and its new test count.

### User requests to carry forward

- **Done 2026-10-18: the six interactive demos** (`sw/demo/`), with the
  user's video of them in PuTTY in the README. Originally: a boot
  banner/system info, Mandelbrot (fixed point vs software float, cycles
  each), digits of pi, Conway's Life (animated, LEDs show the generation),
  Tower of Hanoi, a prime sieve. User asked for interactive versions (the
  UART receiver and bootloader were built first for this, 2026-10-18).
  PuTTY on Windows needs usbipd detached; opening any terminal resets the
  board into the bootloader, so press r there to rerun the loaded program.
- **Vivado screenshot sets, a folder per stage under `docs/img/vivado/`,
  plus `make floorplan` (the zoomable SVGs in `docs/img/`):** device view colored by module, worst path (device + schematic), RTL
  schematic, timing summary, utilization by hierarchy, power (label it a
  vectorless estimate), ILA waveforms. `make gui`, `make gui VIEW=rtl`,
  `make gui VIEW=ila`. Done: Phase D (2026-10-17, single core) and Phase E
  (2026-10-18, TMR, with the voter schematic), side by side in the README's
  "In Vivado". **Every set is kept, never replaced** (the user's rule,
  2026-10-18): a new folder per stage, and the README adds a column or
  section rather than swapping images. **Remind the user to take a new set
  at Stage 2 milestones** (systolic array,
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

*Last updated: 2026-10-18 — Phase E: live fault injector on the board (demo 7). Before that: TMR built, voter proven, 10,000-fault campaign 0 failures, 100 MHz on the board. Before that: Phase D done (demo video in the README); six interactive demos (sw/demo/) checked in simulation and run on the board; UART receiver and serial bootloader, on the board at 100 MHz (WNS +0.948 ns); programs load over serial with no rebuild. Before that, 2026-10-17 — 100 MHz on the board: data memory accessed from
EX (load data registered into MEM/WB), board WNS +1.550 ns at 100 MHz, OOC
122.7 MHz; CoreMark 0.962/MHz (about 96) validated at 100 MHz, IPC
unchanged. XT's harness follows stores into EX. ILA on the pipeline
registers (`make ila`). Next: the photo box, then Phase E.*
