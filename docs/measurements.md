# Measurements

Every measured number in the project, with its conditions. **The trend tables below are
append-only**: never rewrite a past row; if a number turns out wrong, add a row
saying so. Every number is transcribed from `docs/reports/`, never typed.

## Verification detail (what each check covers)

| Check | Result |
|---|---|
| `make lint` | clean, Verilator 5.050 |
| `make sim` | 440 passing, 2 skipped by design (`test_ready_ignored_without_mem_wait` on the two `_wait` builds) across 36 entries (core ×2 and TMR core ×3 builds, alu, regfile, decoder, mem_align, hazard, branch, uart_tx, uart_rx, systolic PE, PE pair, array ×3 sizes, DMA registers, DMA engine, crossbar, accelerator ×3 sizes, soc ×6, TMR soc ×6), after the GEMM, DMA and accelerator models' self-checks (2026-11-05, ~45 min locally), including the 40 official `riscv-tests`, the first-light firmware, one CoreMark iteration on the whole SoC (CRCs checked, IPC counted through RVFI, ~50 s) the bootloader receiving a program over the RX pin (~100 s), the six demos each checked against a Python model (~20 min, 9 of it one software-float Mandelbrot frame, which CI skips), the fault-injection demo, stopped after 3 passes (on TMR: 5,661 flips, all detected, answer and cycles unchanged every pass), and on the TMR core: the core's 105 tests, a 1000-fault campaign (0 failures required, pipeline faults must recover), first light, CoreMark and the bootloader with zero mismatches; UART decoded at 115200 |
| `make synth` | routes clean, 0 errors, ~40 s |
| `make formal` | the TMR voter (V1-V4, every input) and x0 invariance, stall correctness (S1–S4), forwarding (F1/F2/L1), reset-commits-nothing (X1), branch-flush correctness (B1/B2), no regfile structural hazard (SH1) and no X into committed state (XP) proven by k-induction, XT by BMC to depth 10; **riscv-formal 46/46 checks and 46/46 cover runs** (37 `insn`, `reg`, `pc_fwd`, `pc_bwd`, `unique`, `causal`, `causal_mem`, `liveness`, `hang`, `ill`), ~6 min (XT's BMC is ~5 of it) — see [formal-properties.md](formal-properties.md) |
| `make impl` | board-level route + bitstream, timing met at 100 MHz (WNS +0.948 ns with the UART receiver), ~2 min |
| `make model-test` | the C golden model alone: rv32ui **40/40**; a planted SRA bug fails exactly `sra` |
| `make uvm` | XSim, 300 random programs, ~45 s: **205/205 coverage bins (100%)** on seeds 1, 2, 3, ~45,000 retirements each compared with the model, 0 mismatches. Planted RTL faults caught: forwarding priority (in the hazard unit), LBU sign-extending, no rs2 load-use stall |
| `make uvm M=1` (Phase H) | 2026-11-07: the core built with M_EXT, M instructions in the generator (corner operands set up now and then: x / 0, INT_MIN / −1), the C model with M on; coverage group 9 ([coverage-plan.md](coverage-plan.md), 33 bins), forwarding sampled on an instruction's first EX cycle only. 300 programs, ~1 min 45 s: **238/238 bins (100%)** on seeds 1, 2, 3, 45,270 / 45,935 / 46,216 retirements compared with the model, 0 mismatches. RV32I run unchanged: 205/205, 44,499 retirements (seed 1). Planted faults caught (riscv_muldiv): MULHSU with rs2 signed, a negative dividend by zero giving +1, REM signed by the divisor |
| **On the board** | 2026-10-17, programmed from Windows (Lab Edition 2025.2), core at 50 MHz: "hello from rv32i", "sum 1..100 = 5050", then the count printing continuously with LD4-LD7 counting in binary. All three first-light goals seen; photo in [img/fpgafirstlight.jpg](img/fpgafirstlight.jpg), which with the demo video in the README closes Phase D's photo box (the user's choice: it shows the board and the screens at first light) |
| **CoreMark on the board** | 2026-10-17, 2000 iterations at **100 MHz** (`make prog` from WSL): **0.962 CoreMark/MHz, about 96 CoreMark**, "Correct operation validated", 2,077,692,270 cycles ([coremark_board.txt](reports/coremark_board.txt)); the 50 MHz run before the clock change gave the same cycles per iteration. **IPC 0.691** (CPI 1.447) over the timed region, counted in RTL simulation of the same SoC ([coremark_sim.txt](reports/coremark_sim.txt)); simulated cycles per iteration match the board's to 0.0013%. RV32I without M: every multiply and divide is a libgcc call |
| **ILA on the board** | 2026-10-17, `make impl ILA=1` then `make ila` from WSL (Hardware Manager in batch through `hw_server`): 13 probes, 328 bits (pc and instruction of all four pipeline registers, EX/MEM ALU result, writeback, halt), depth 1024, core clock. First-light program: every EX→MEM→WB shift consistent, 227 stall cycles and 114 flush bubbles in the window ([ila_summary.txt](reports/ila_summary.txt), [ila_capture.csv](reports/ila_capture.csv)). ILA build (at 50 MHz, before the clock change): +2233 LUT, +3772 FF, +10 BRAM, WNS +4.162 ns ([summary_board_ila.txt](reports/summary_board_ila.txt)). CoreMark at 100 MHz with the ILA (WNS +1.066 ns), triggered on `core_state_transition`: stage shifts consistent, 881 retirements in 1023 cycles ([ila_coremark_summary.txt](reports/ila_coremark_summary.txt), [ila_coremark.csv](reports/ila_coremark.csv)) |
| **Bootloader on the board** | 2026-10-18: `scripts/load.py sw/build/apps/echo.bin` loads 1760 bytes over the UART in about 0.2 s; the program echoes keys, returns to the bootloader on q, and `r` reruns it without resending. Changing the program needs no Vivado rebuild |
| **Demo reel on the board** | 2026-10-18, `sw/demo/` loaded over serial ([demo_board.txt](reports/demo_board.txt)): microbenchmarks measure exactly 1 cycle per ALU op, +1 per load-use, +2 per taken branch or jump, 0 for not taken; Mandelbrot frame 12,849,963 cycles fixed point vs 49,110,978 software float (3.8x; simulation gives the same counts, and both pictures match a bit-exact model, IEEE single included); 750 digits of pi in 4.95 s; Life 81,581 cycles a generation; sieve to 163840 in 16.0 ms |
| **TMR** (Phase E) | 2026-10-18: `rtl/tmr/riscv_core_tmr.sv`, three copies with `DONT_TOUCH`/`KEEP_HIERARCHY` (three survive: 1601 cells each, `summary_ooc_tmr.txt`), voted feedback into each copy's pc, halt flags and register file. The voter is proven (`tmr_voter.sby`). The core's 105 tests and the SoC's first light, CoreMark and bootloader tests pass on it with zero mismatches. **Fault campaign, 10,000 single-bit flips** ([tmr_faults.txt](reports/tmr_faults.txt)): 0 failures; 1,275 detected, all corrected and all three copies identical again; median disagreement 1 cycle, max 30; 5,777 register-file flips latent in registers the programs never use. Board: 100 MHz met, WNS +0.095 ns, 3.1x LUT, Fmax −8.7%. **Live injector on the board** (2026-10-18, [tmr_inject_board.txt](reports/tmr_inject_board.txt)): demo 7 repeats a sieve to 163840 until a key, flipping a random bit of copy B's pc 1,887 times a pass: 133 passes, each 14,999 primes and 3,354,864 cycles, exactly as the clean run; all 250,971 flips detected; the same counts in simulation (`soc_tmr:test_demo`). Totals on screen, disagreements / 4096 on the LEDs. The plain demos still exact on the TMR bitstream |
| **TMR with M** (Phase H) | 2026-11-07: `riscv_core_tmr` takes `M_EXT` to all three copies, each with its own unit; three survive with it (2248 / 2289 / 2289 cells, 4 DSP each, `summary_ooc_tmr_m.txt`, `utilization_ooc_tmr_m_hier.rpt`). The core's tests, rv32um and `test_core_m` pass on `riscv_core_tmr_m` (127/129, skips by design). **Fault campaign, 10,000 single-bit flips, RV32IM programs** ([tmr_faults_m.txt](reports/tmr_faults_m.txt), `make faults M=1`): the M unit's 16 flop groups join the targets; 0 failures; 1,027 detected, all corrected and all three copies identical again; **1,691 flips in the M units, 251 detected, all corrected and recovered** (a copy whose unit finishes early or late falls out of step and is pulled back by the voted pc and writes); median disagreement 1 cycle, max 469 (RV32I: 30) |
| **GEMM golden model** (Phase F) | 2026-10-18, before any RTL: `sw/model/gemm_model.py`, `make gemm-model` (run first by `make sim`): INT8 GEMM with INT32 wraparound, a cycle-level weight-stationary array (feeder pads zeros; row m leaves column c's bottom at cycle m + ROWS − 1 + c), and requantization. 1,449 checks: PE exhaustive (65,536 pairs × 4 psums), gemm against plain Python ints, the array against gemm on 1,320 shapes at 4×4, 8×8, 16×16, 4×8, 8×4, saturation boundaries, INT32 wraparound at K = 131,073, requantization against exact fractions (ties, extremes). Four planted model bugs each caught. ~22 s |
| **Systolic PE** (Phase F) | 2026-10-18: `rtl/accel/systolic_pe.sv`, INT8 × INT8 + INT32 psum, activation registered right, psum registered down; weights double-buffered (a shadow register shifts down the column while the current tile computes, `w_swap_i` makes it active the next cycle). `systolic_pe:test_systolic_pe`: all 65,536 (activation, weight) pairs back to back against `gemm_model.pe`, psums at 0, ±1, both INT32 limits and random, weight swaps with no idle cycle; reset test. Two planted bugs caught (using the shadow weight early; zero- instead of sign-extending the product). In `make lint` as its own top. ~6 s |
| **Systolic array** (Phase F) | 2026-10-18: `rtl/accel/systolic_array.sv`, ROWS × COLS PEs (default 4×4): input skew (row r delayed r cycles) and output deskew (column c delayed COLS − 1 − c), so a row of A goes in as one vector and its results come out as one vector LATENCY = ROWS + COLS − 1 edges later, with `valid_o`. The weight swap rides with the data (PE `w_swap_o`), so each PE switches right after the tile's last row passes it; the shadows must hold until it reaches the last PE (ROWS + COLS − 2 cycles). Edge padding and summing tiles along K are the feeder's and output buffer's (Phase G/H); the test plays both. `test_systolic_array` at **4×4, 16×16 and 4×8**: 2,000 / 1,000 / 2,000 random GEMMs (shapes up to 3× the array, multiples and not), 9 edge shapes (1×1×1, one past and one short of a tile, …), 5 saturation jobs (every product ±16,384 or −16,256, alternating extremes); every element matches `gemm_model.gemm`, every row arrives exactly LATENCY edges after it entered. Four planted bugs caught (input skew, output deskew, broadcast swap, swap dropped below row 0). ~5 s / 39 s / 14 s. |
| **PE pair, two MACs per DSP** (Phase F) | 2026-10-18: `rtl/accel/systolic_pe_pair.sv`, columns 2p and 2p + 1 on one DSP48E1: the swap packs the two shadow weights into w0 + w1·2^16 (the DSP's A register), one multiply by the shared activation, lanes split in fabric (low 16 bits signed; upper field plus the low lane's borrow) and added to the two psums. The model's `pack_weights`/`unpack_lanes` check every (a, w0, w1), 16,777,216 of them. `test_systolic_pe_pair`: each lane through all 65,536 (activation, weight) pairs with the other lane's weight at −128, −1, 0, 1, 127 (655,360 cycles, both lanes against `gemm_model.pe`). Two planted bugs caught (borrow dropped, low lane zero-extended). The array now uses pairs (COLS must be even; LATENCY = ROWS + COLS/2 − 1, 23 at 16×16); `test_systolic_array` passes again at 4×4, 16×16, 4×8, and a planted odd-column deskew bug is caught. `systolic_pe` stays as the single-PE reference, tested, not instantiated. ~36 s |
| **DMA register slave** (Phase G) | 2026-11-04: `rtl/bus/dmaeng_regs.sv`, AXI4-Lite slave + DMA-Engine's register file (offsets and bits from its generated `dmaeng_pkg`, read from the submodule; `make dma-model` first regenerates package and header from `spec/dmaeng.yaml` and requires them byte-identical). Engine side: `run_o` (= the model's has_work), ring base/size, HEAD, `soft_rst_o`; the engine reports `head_adv_i`, `done_irq_i`, `err_i`/`err_code_i`. `test_dmaeng_regs`: every read, `irq_o`, `run_o` against the model with processing switched off; 6,000 random writes/reads/engine reports with random AW/W/B/R timing, reports in a write's commit cycle; seeds 1-4. Six planted bugs caught (W1C eats a same-cycle completion, BUSY ignores ERROR, RESET keeps IRQ_MASK, no HEAD wrap, partial strobes applied, report beats RESET). Out of context: 213 LUT, 285 FF, 170.3 MHz. ~2 s |
| **DMA engine** (Phase G) | 2026-11-04: `rtl/bus/dmaeng.sv` = `dmaeng_regs` + `dmaeng_desc` (descriptor sequencer, no bus signals, the model's `step()` order) + `dmaeng_axi` (AXI4 master transport: 32-byte descriptor fetch, word writes, copies in ≤64-byte chunks never crossing 4 KiB, **byte-granular**: funnel shift by (src − dst) mod 4, strobes at the ends; user's choice, matches the model). `test_dmaeng`, model and RTL side by side behind a stalling AXI4 slave that checks the master's protocol (`tb/cocotb/axi_mem.py`): **DMA-Engine's golden trace replays on the RTL** (923 accesses, 300 reads, 276 copies, 281 interrupt rises = MSIs); all 16 src/dst alignments × 18 lengths; page crossings, MAX_XFER and MAX_XFER + 1; every spec error; SLVERR at fetch, copy read, copy write, status write; CTRL.RESET mid-64 KiB copy (≤ one burst drains, nothing written back); 60 random batches; status-before-flags order on the bus. 8/8 on seeds 1-3, ~30 s. 12 planted bugs caught (see the commit). Out of context: 1,096 LUT, 686 FF, 105.5 MHz |
| **DMA on the SoC** (Phase G) | 2026-11-04: `soc.sv` builds the core with MEM_WAIT; region 0x2000_0000 is AXI4-Lite through `core_axil_bridge` (holds the core per access, one in flight, program order; SLVERR/DECERR set BUSERR at 0x1000_0018) to `dmaeng`; the engine's AXI4 master reaches RAM port B through `axi_ram_port` only in cycles the core issues no load/store (fixed core priority; held cycles count as free). The read-data selects move only when the core advances. `sw/lib/dma.{h,c}`: bare-metal driver on DMA-Engine's `dmaeng_regs.h` (struct offsets checked against it at compile time). `sw/apps/dmatest.c` + `soc:test_dma` / `soc_tmr:test_dma`: probe, 176 alignment copies with guard bytes, a 6-copy batch wrapping the ring, BAD_LEN stop + reset + recovery, 4 KiB timed: **183/183**; the test reads the 4 KiB copy back from RAM itself. **4 KiB: engine 4,711 cycles (0.87 B/cycle), core word loop 7,172**: the port does one beat at a time (~4.6 cycles/word). **CoreMark cycle-identical** (1,038,833 cycles, IPC 0.6912) with MEM_WAIT and the DMA on the port |
| **AXI4 crossbar** (Phase G, buildplan 6.2) | 2026-11-05: `rtl/bus/axi_xbar.sv`, N masters × M slaves, decode by base/mask (`S_BASE`/`S_MASK`, flat vectors: Yosys reads no packed-array parameter), DECERR responder, round-robin per slave per direction with a **registered grant** (no READY ever depends combinationally on a VALID), one read and one write in flight per master and per slave, W routed only from AW handshake to WLAST. `axi_to_axil.sv`: AXI4 slave → AXI4-Lite master, a burst as single transactions. `test_axi_xbar` (3×2 + DECERR, random bursts 1-16 beats, every VALID/READY random-delayed, masters overlap a write with the last one's B and try a second read early): data exact per master window, DECERR on every beat with RLAST, outstanding limit, B after WLAST, VALID/payload stability; ~1,000 reads, ~950 writes, ~640 DECERR per master; seeds 1-5. Round-robin: 1,883 grants at one slave, order 0 1 2 0 1 2 …, worst wait N − 1 = 2. 7 planted bugs caught. **Formal** (`tb/formal/axi_xbar.sby`, 2×2, 8-bit): X1 VALID held + payload stable on every output, X2 a free target with a request is granted next edge, plus a netlist check (`select -assert-none`) that no master VALID input reaches a master READY output and no READY input reaches any VALID output except through a flop, X3 outstanding ≤ 1 per master and target, X4 B only after the master's WLAST: k-induction depth 8 (seconds), covers reached. **Formal found a bug simulation missed**: after WLAST, W stayed routed until B, so a master's next write's early W beats went to the old slave (X1 broke when B closed the route; a slave taking W before B would have mixed two writes). Fixed (route closes at WLAST); `test_axi_xbar`'s masters now start writes early and catch it too. **In the SoC**: masters 0 bridge, 1 DMA; slaves 0 RAM port, 1 DMA registers (0x2000_0000-0x2000_0FFF via `axi_to_axil`); the rest of the AXI region DECERRs (BUSERR). `dmatest` 186/186 (adds: an unmapped load reads 0 and sets BUSERR); 4 KiB copy 4,888 cycles (4,711 point to point: the registered grant, ~1 cycle per burst) |
| **GEMM accelerator** (Phase G, launched by the core) | 2026-11-05: `rtl/accel/gemm_accel{,_regs,_seq}.sv`. Decided with the user: **local buffers** (A, W, C, 16 KiB each, banked 32-bit `ram_dp` so the array reads a whole line a cycle) that the DMA fills and empties, **INT32 C** (requantization stays in software), **one job = a whole GEMM** tiled in hardware (N outer, K inner, sums along K by read-modify-write of C, zeros past K and N). Registers (AXI4-Lite, 0x2000_1000): CTRL.START, STATUS (BUSY/DONE/ERROR), M/K/N (16 bits), CYCLES; a shape over any buffer is refused (ERROR, 3 cycles, nothing written). Buffers (AXI4, 0x2010_0000) through `axi_ram_port`, which waits while the job runs. Golden model first: `sw/model/accel_model.py` (`make accel-model`, 496 checks; layouts, limits each alone, **cycle count = 3 + tiles × (ROWS + 1 + M + LATENCY + 2)**, no overlap between tiles). `test_gemm_accel` at 4×4, 4×8 (2 KiB buffers) and 16×16: random shapes with garbage in every padding byte, C read back whole and byte-exact against the model (padding words 0, lines past M·NT untouched), CYCLES exact, each buffer limit exactly met and one over, saturation, bus access and START during a job; 10 planted bugs caught (two after the test was tightened: START mid-job resetting CYCLES; a planted row-mask bug that turned out equivalent was replaced). **On the SoC** (`sw/lib/gemm.{h,c}`, `sw/apps/gemmtest.c`, `soc:test_gemm`, `soc_tmr:test_gemm`): 11/11, six shapes from 1×1×1 to 24×20×24, C equal to the core's own multiply and, from RAM, to the model; every job's CYCLES equal to the model's. **Job vs whole call**: 24×20×24 is 267 cycles of job but 11,704 for the call (DMA in, job, DMA out, one descriptor a row when K or N is not a multiple of 16), and 822,328 on the core alone (shift-add multiply). Out of context: 10,134 LUT, 10,948 FF, 24 BRAM, 131 DSP (128 array + 3 for the shape check's products), 101.4 MHz; worst path the weight-shift enable's fanout (0 levels, 95% routing). `dmatest`'s DECERR probe moved to 0x2000_2000 (0x2000_1000 is now the accelerator) |
| **DMA and GEMM on the board** (Phase G) | 2026-11-05, bitstreams from `f873d7d` (`make impl`, `make impl TMR=1`, reports unchanged), programs loaded over serial: `dmatest` **186/186**, `gemmtest` **11/11**, single core and TMR alike. Every cycle count equals simulation's: 4 KiB copy 4,888 cycles (core word loop 7,172); 24×20×24 job 267, whole call 11,704, core alone 822,328 ([dmatest_board.txt](reports/dmatest_board.txt), [gemmtest_board.txt](reports/gemmtest_board.txt)) |
| **M golden models** (Phase H) | 2026-11-06, before any RTL: an M switch, off by default, in `tb/cocotb/rv32i_model.py` and `sw/model/rv32i_iss.c` (M encodings trap when off, as on the RV32I core). `make model-test`: riscv-tests rv32um 8/8 (M on), rv32ui 40/40 (M off); both models against `sw/model/m_vectors.txt`, **10,592 vectors from spike `--isa=rv32im`** (all pairs of 18 edge values + 1,000 seeded random, × 8 ops; `make m-vectors` regenerates), 10,592/10,592 each; 8/8 M encodings trap with M off. 10 planted model bugs caught |
| **M unit** (Phase H) | 2026-11-06: `rtl/core/riscv_muldiv.sv`, not yet in the core. MUL\*: operands captured (sign/zero-extended to 33 bits), four 17×17 signed partial products registered (4 DSP48E1), summed: **3 cycles in EX**. DIV\*: |a|, |b| captured, 32 restoring steps, signs applied: **34 cycles, fixed**. Handshake `valid_i` / `done_o` / `ack_i`; result held until ack. `riscv_muldiv:test_muldiv`: all 10,592 spike vectors + 3,000 random ops against the golden model, operands scrambled after capture, random ack delays, reset mid-op; latency exact; ~20 s. Formal: property 14 in [formal-properties.md](formal-properties.md). 8 planted bugs caught by both. Out of context: 497 LUT, 109 FF, 4 DSP, 149.4 MHz (register to register; see M-extension synthesis) |
| **CDC primitives** (Phase H, array clock domain slice 1) | 2026-11-07: `rtl/cdc/`: `cdc_sync` (`ASYNC_REG` chain), `cdc_async_fifo` (gray pointers, first-word fall-through, `wr_used_o` for an almost-full), `cdc_pulse` (toggle + acknowledgement, `src_busy_o`), `cdc_reset_sync` (asynchronous assert, synchronous release; the one asynchronous reset in `rtl/`). Not yet instantiated. cocotb, two unrelated clocks at six period pairs (faster, slower, equal, 10.00/10.03 ns drifting, 7/31 and 31/7 ns), random phase: FIFO (16 deep × 8 bits, and 4 deep with 3 flops) 3,000 bursty entries per pair against a scoreboard, full and empty reached at every pair, head and `wr_used_o` checked every cycle; latency exactly SYNC_STAGES edges each way; writes while full dropped; 24 mid-stream flushes; pulse 300 per pair, 132-4,997 ignored while busy; reset sync 200 releases at random phase. Formal: property 17 in [formal-properties.md](formal-properties.md), unbounded (PDR). Planted bugs: 9 by formal, 4 by simulation (one-flop synchronizer by the latency test, unsynchronised release, write while full, level pulse) |
| **Array CDC golden model** (Phase H, array clock domain slice 2) | 2026-11-07, before the stream RTL: `sw/model/accel_cdc_model.py` runs a job edge by edge on both clocks (input FIFO, array, output FIFO with credits, ideal synchronizers) and computes C from the entries it schedules. `make accel-model`: with no FIFOs it equals `accel_model.py` exactly (cycles and every byte of C, 132 shapes at 4×4, 16×16, 4×8); through the FIFOs, 2,112 runs at eight clock pairs (equal, 10.00/10.03 ns, 3.1 to 31 ns arrays, an edge-sharing phase and a random one), input FIFO 2-16 deep, output 1-32: C bit-exact against `gemm()`, padding and untouched lines kept, CYCLES never under a bound derived separately from the design; equal clocks cost exactly 2·SYNC_STAGES + 1 cycles per tile (+2 with shared edges); one row per cycle of the slower clock. Planted model bugs: 10 of 10 caught (tie sampling, one sync flop, no credit check, room ignoring the read in flight, latency, a lost swap, W order, tile end, K tiles not summed, the swap-spacing check), plus one equivalent mutant |
| **Array CDC stream** (Phase H, array clock domain slice 3) | 2026-11-08: `ARRAY_CDC` in `gemm_accel` (default 0): shifts, swap and rows of A through a 259×16 async FIFO to the array on `clk_array_i`, sums back through 512×32 under credits, resets in both domains (`rst_c` held until the array side's reset is back, READYs held meanwhile). cocotb `test_gemm_accel`, six tests, every job's CYCLES equal to `accel_cdc_model.stream_job()` at the phase the RTL saw and every byte of C equal to the model: `gemm_accel_cdc` (16×16, the SoC's FIFOs) and `gemm_accel_4x4_cdc` (FIFOs 2 in / 4 out, so the sequencer stalls in LOAD and the credits bind) at nine array clocks, 3.1 to 97 ns, edge-sharing (10 and 20 ns at phase 0) and drifting (10.03 ns), plus a START at once after a reset with a 403 ns array clock; `ARRAY_CDC` = 0 builds (16×16, 4×4, 4×8) identical to `job_cycles()` whatever `clk_array_i` does; `soc:test_gemm` passes. FIFO invariants and "never written while full" asserted in every simulation. Planted bugs: 11 of 11 caught (room without the read in flight, no credit check, credit off by one, credits never returned, bubble fed as the stale head, shift or swap not gated by the stall, STREAM or LOAD advancing while stalled, core side released with `rst_i`, READY not held); 3 were missed by the first tests (shipping depths never stall in LOAD, credits never bind; a reset bug only bites if START beats the array's first edge) and the tests were fixed |
| **Weight-transform hook** (Phase H box 3, P5's requests 0009/0010) | 2026-11-09: on clk_i before the input FIFO; `WX_EXT` (default 0, identity) loads `wx_w_i`; beat, tile, row, pad flags and a start pulse out on `wx_*` (contract in `gemm_accel_seq.sv`). Model: `weight_beats()` and `Accel.wx` (`make accel-model` 517 checks, CDC model 2,416). `test_gemm_accel` now 8 tests on 7 builds (adding `gemm_accel_4x4_wx`, `gemm_accel_4x4_cdc_wx`), all pass: every beat recorded at the ports equals `weight_beats()`, each W[k][n] once at its lane, none for a refused shape; w ^ 1 at all nine array clocks gives C = gemm(A, W ^ 1) and the identity's CYCLES; builds without `WX_EXT` ignore garbage on `wx_w_i`. Planted bugs: 5 of 5 caught |
| **Array clock on the board** (Phase H, array clock domain slice 4) | 2026-11-08: `ARRAY_CDC` through `soc` and `arty_a7_top` (default 0), `clk_array` from a second MMCM at 100 MHz, `make impl CDC=1`: 100 MHz met on both clocks, 2,964 crossing paths all bounded (`syn/impl_arty.tcl` refuses a bitstream otherwise: with the output FIFO's storage bound deleted it found 512 unbounded and refused), `report_cdc` 4 Info on the accelerator plus the board's two pre-existing input synchronizers without `ASYNC_REG` (`rst_ni`, `uart_rx_i`, CDC-2). **On the board: `gemmtest` 11/11 in five runs, each after a DTR reset**, every job's cycles the model's at phase 0 (both MMCMs deskewed to one oscillator) and the same each run ([gemmtest_board_cdc.txt](reports/gemmtest_board_cdc.txt)). Simulation: `soc_cdc:test_gemm` (array 31 ns against the SoC's 20 ns), firmware-launched jobs' CYCLES equal to the model at each job's phase; `soc:test_gemm`, `test_soc`, `test_dma` unchanged; `gemm_accel{,_4x4}_cdc` 6/6 after the reset change |
| **Array clock by DRP** (Phase H box 4) | 2026-11-08: `make aclk-check` (local, reads the Vivado install): `sw/model/mmcm_drp.py`'s DRP words equal AMD's `mmcm_pll_count_calc` for divides 1-128; `array_clk_ctl.sv` driving AMD's `MMCME2_ADV` model (Icarus): power-up registers read back as the model holds them, output measured 10.0 → 12.5 → 10.0 → 12.5 ns, relock 0.91 µs, the array held whenever RST is high or LOCKED low (checked on the primitive's own pins every edge), one DEN per access with GO held while busy, no DRC message from the primitive. `soc_cdc:test_gemm` with `tb/cocotb/mmcm_bfm.py`: 22/22, the clock 20 → 25 → 20 ns as the firmware reprogrammed it, all 13 jobs' CYCLES = model at their clock and phase, array side in reset at every array edge while unlocked (runt pulses included); `soc:test_gemm`, `soc:test_soc` pass. **Board: `gemmtest` 22/22 in five runs, 100 → 80 → 100 MHz by the core**, every job = model at an allowed phase (`scripts/gemm_board_check.py`; /10 jobs vary by one cycle between runs, the relock's phase), clock change 141 core cycles ([gemmtest_board_cdc_drp.txt](reports/gemmtest_board_cdc_drp.txt)). Planted bugs caught: odd divides without EDGE (model self-check and the diff with AMD), GO accepted while busy (DEN count), the hold ignoring LOCKED (array released during the first lock), the SoC not ORing the hold into the accelerator's reset (gemmtest "idle after the clock change"), firmware writing with RST low (the model's rule), firmware dropping CLKOUT0's enable bit from the read-modify-write mask ("enable bit not kept") |
| **Full regression, array on its own clock** (Phase H, array clock domain slice 5) | 2026-11-10: every SoC test also on the CDC build, the array at 25 ns against the core's 20 ns from `mmcm_bfm.py` (divide 10, the board's 80 vs 100 MHz): `soc_cdc:test_soc`, `test_coremark`, `test_boot`, `test_demo` (7/7), `test_dma`, `test_gemm`, and `soc_tmr_cdc:test_gemm`. `start_array_clock()` in each test checks the array side leaves reset within 20 array edges of lock at 25,000 ps. **Whole regression (`tb/cocotb` TESTS, 59 entries, run in two parts after a low-memory kill): 844 tests, 0 failures, 6 skipped by design** (`test_hold_commits_nothing` without `MEM_WAIT`, `test_m_encodings_trap_without_m` on M builds); Longest: `soc_cdc:test_demo` 4 h 20 min, `soc_tmr_cdc:test_gemm` 3 h 36 min. The hardware half: board `gemmtest` 22/22 at 80 vs 100 MHz (row above) |
| CI on push | green (lint + sim + formal on `ubuntu-24.04`) on branch `dma` at `2277923`, run 41911741373 (Phase G DMA engine, PyYAML 6.0.3 added); `systolic` last at `984cb52`; `main` last at `f1713af` (Phase E README) |

## Synthesis trend

**Append-only.** Never rewrite a past
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
| 2026-11-04 | `dmem_ready_i` port, MEM_WAIT = 0 (ignored): same cells, placement differs | 966 | 467 | 55 | +1.649 | 119.7 | −0.7 |
| 2026-11-04 | MEM_WAIT = 1 (the data-port hold), `make synth-wait`, not the default | 997 | 462 | 55 | +1.471 | 117.2 | −2.5 |
| 2026-11-07 | `M_EXT` parameter in, M_EXT = 0 (the default, RV32I): same cells and timing as before it; RV32IM in its own table | 966 | 467 | 55 | +1.649 | 119.7 | 0.0 |

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

**LUT excludes distributed RAM.** Every summary's LUT is the count of LUT
cells; LUTs configured as distributed RAM are not among them (the register
file: 44 in the core, 132 in TMR, per the utilization reports). Found
2026-11-07; the summaries now print it as LUTRAM on its own line, and
earlier rows are left as they were measured.

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
| 2026-11-04 | Single core, `dmem_ready_i` tied high (MEM_WAIT = 0): same cells, placement noise | 1123 | 435 | 8 | 100 MHz | +0.930 | 110.3 |
| 2026-11-04 | TMR, `dmem_ready_i` tied high (MEM_WAIT = 0): same cells, placement noise | 3446 | 1621 | 8 | 100 MHz | +0.112 | 101.1 |
| 2026-11-04 | + DMA engine, AXI4-Lite bridge (core MEM_WAIT = 1), DMA on RAM port B; port B selected on the core's dmem_re/we (not committed) | 2256 | 1211 | 8 | 100 MHz | +0.257 | 102.6 |
| 2026-11-04 | TMR, same (not committed): **failed**, I/O write path off the voted dmem_we, which drove ~50 port-B mux selects | 4490 | 2404 | 8 | 100 MHz | −0.047 | 99.5 |
| 2026-11-04 | + DMA, port B selected on the DMA's own enable; worst path the DMA's chunk size | 2254 | 1211 | 8 | 100 MHz | +0.343 | 103.6 |
| 2026-11-04 | TMR + DMA, same; worst path the voter's mismatch compare again | 4488 | 2404 | 8 | 100 MHz | +0.073 | 100.7 |
| 2026-11-05 | + AXI4 crossbar (2×2, registered grant, DECERR) + AXI4→Lite converter; worst path the DMA's chunk size | 2725 | 1355 | 8 | 100 MHz | +0.495 | 105.2 |
| 2026-11-05 | TMR, same (not committed): **failed** on the voter's mismatch compare (copy → compare → `mismatch_q`, 22 levels) | 5067 | 2546 | 8 | 100 MHz | −0.260 | 97.5 |
| 2026-11-05 | TMR, the three bundles registered before the mismatch compare; worst path now the data address → RAM port B | 4944 | 2975 | 8 | 100 MHz | +0.123 | 101.2 |
| 2026-11-05 | + GEMM accelerator (16×16 array, 3 × 16 KiB buffers, +24 BRAM, 131 DSP) as crossbar slaves 2 and 3; worst path inside the array (a PE pair's DSP product → lane split → psum add → deskew, 10 levels) | 13204 | 12357 | 32 | 100 MHz | +0.288 | 103.0 |
| 2026-11-05 | TMR, same; worst path the data address → RAM port B again (thinner: placement around the array) | 15445 | 13985 | 32 | 100 MHz | +0.042 | 100.4 |
| 2026-11-07 | RV32IM core (M_EXT = 1, `make impl M=1`, `summary_board_m.txt`; 135 DSP = 131 + the M unit's 4), CoreMark image | 13682 | 12475 | 32 | 100 MHz | +0.242 | 102.5 |
| 2026-11-07 | TMR, RV32IM (`make impl M=1 TMR=1`, `summary_board_tmr_m.txt`; 143 DSP = 131 + 3 × 4), CoreMark image | 16891 | 14305 | 32 | 100 MHz | +0.181 | 101.8 |
| 2026-11-08 | Array on its own clock (`ARRAY_CDC` = 1, `make impl CDC=1`, `summary_board_cdc.txt`): a second MMCM, 100 MHz, async FIFOs both ways; against the GEMM row above +86 LUT, +103 FF (+516 LUTRAM, not in LUT). Worst over both clocks +0.128 ns, the array's reset fanning out to the shadow weights (inside `clk_array`); worst hold +0.030 ns. 2,964 timed paths cross the two clocks, every one with a bound (`constr/accel_cdc.xdc`; the build refuses a bitstream otherwise) | 13290 | 12460 | 32 | 100 MHz + 100 MHz array | +0.330 | 103.4 |
| 2026-11-08 | Array clock reprogrammable (box 4, `summary_board_cdc.txt`): the array MMCM an `MMCME2_ADV` with its DRP on the core clock (VCO 800 MHz, /8), the ACLK register (`array_clk_ctl.sv`); against the row above +11 LUT, +55 FF. Worst path now inside the DMA engine (`u_axi` `dst_q` → `n_q`), a placement shift, not the new logic; worst over both clocks +0.166 ns, hold +0.018 ns; 2,964 crossing paths, all bounded; `report_cdc` unchanged | 13301 | 12515 | 32 | 100 MHz + 100 MHz array | +0.170 | 101.7 |
| 2026-11-09 | Weight-transform hook (box 3, `WX_EXT` = 0, `summary_board_cdc.txt`): its outputs open on the board top, so trimmed; against the row above −9 LUT, −6 FF (placement noise). Worst over both clocks +0.303 ns, hold +0.035 ns; 2,964 crossing paths, all bounded; `report_cdc` unchanged (4 Info on the accelerator, the two board-input CDC-2) | 13292 | 12509 | 32 | 100 MHz + 100 MHz array | +0.303 | 103.1 |
| 2026-11-10 | Default build (`ARRAY_CDC` = 0) with the weight-transform hook (box 3, `WX_EXT` = 0, `summary_board.txt`), the bitstream matbench ran on; against the Phase G build: −3 LUT, +9 FF, the hook trimmed | 13201 | 12366 | 32 | 100 MHz | +0.263 | 102.7 |
| 2026-11-10 | RV32IM (`make impl M=1`, `summary_board_m.txt`) with the weight-transform hook (`WX_EXT` = 0), bootloader image, the bitstream matbench_m runs on; against the 2026-11-07 RV32IM row +1 LUT, +6 FF | 13683 | 12481 | 32 | 100 MHz | +0.219 | 102.2 |
| 2026-11-25 | `ASYNC_REG` on the board's two input synchronizers (`rst_req_q` in `arty_a7_top`, `sync_q` in `uart_rx`), `make impl CDC=1`, `summary_board_cdc.txt`: **`report_cdc` has no warnings left**, the two CDC-2 now CDC-3 (Info), 4 CDC-3 + 2 CDC-9 in all; against the 2026-11-09 row 0 LUT, −7 FF (placement). Worst over both clocks +0.349 ns, hold +0.033 ns; 2,964 crossing paths, all bounded; 0 critical warnings. Other board builds not rerun (an attribute, no logic change) | 13292 | 12502 | 32 | 100 MHz + 100 MHz array | +0.350 | 103.6 |
| 2026-11-26 | Tiny-LLM build (`make impl M=1 LLM=1`, `summary_board_m_llm.txt`): RV32IM, **384 KiB RAM** (`RAM_WORDS` 98304), the LLM bootloader image; against the 2026-11-10 RV32IM row +295 LUT, +147 FF, +88 BRAM (120 of 135). Route alone left −0.005 ns in the DMA engine's burst arithmetic (`u_axi` `dst_q` → `n_q`, 16 levels, 9 CARRY4), so `syn/impl_arty.tcl` now runs a post-route `phys_opt_design` **only when route leaves setup slack negative** (said in the summary; builds that meet timing are unchanged); after it +0.008 ns, hold +0.016 ns, 0 critical warnings | 13978 | 12628 | 120 | 100 MHz | +0.008 | 100.1 |

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
| 2026-11-04 | out of context, core alone, MEM_WAIT = 1 (`*_ooc_wait`, `*_ooc_tmr_wait`) | 997 / 462 | 3699 / 1450 | 3.71 | 3.14 | 117.2 MHz | 99.5 MHz | −15.1% |
| 2026-11-05 | out of context, core alone, bundles registered before the mismatch compare | 966 / 467 | 3895 / 1879 | 4.03 | 4.02 | 119.7 MHz | 104.5 MHz | −12.7% |
| 2026-11-05 | same, MEM_WAIT = 1 | 997 / 462 | 3904 / 1879 | 3.92 | 4.07 | 117.2 MHz | 107.7 MHz | −8.1% |
| 2026-11-07 | out of context, core alone, `M_EXT` parameter in, M_EXT = 0: same cells and timing as before it | 966 / 467 | 3895 / 1879 | 4.03 | 4.02 | 119.7 MHz | 104.5 MHz | −12.7% |
| 2026-11-07 | out of context, core alone, M_EXT = 1 (RV32IM; `*_ooc_m`, `*_ooc_tmr_m`); 4 DSP → 12 | 1440 / 577 | 5343 / 2209 | 3.71 | 3.83 | 114.9 MHz | 106.5 MHz | −7.3% |

LUT and FF here are cell counts, as in the trend tables. By the hierarchical
report (slice LUTs, `utilization_ooc_tmr_hier.rpt`), the three copies are
892 each and the voter 600 (891 and 599 before the injector): a 2-of-3 vote and a compare over each copy's
143-bit bundle of next state. The TMR
critical path is copy → mismatch compare → its register: the compare tree
is deep. Counting from mismatch_o directly made the counter's enable the
critical path (OOC −0.386 ns); registering it first gave +0.126.

## Systolic array synthesis (Phase F)

`make synth-array ARRAY=<rows>x<cols>`: `rtl/accel/systolic_array.sv` alone,
out of context, synth + place + route, part `xc7a100tcsg324-1`, 10.000 ns
constraint, from `docs/reports/summary_ooc_array<rows>x<cols>.txt`. LUT/FF
are cell counts, as in the synthesis trend. The device has 240 DSP48E1.
Append-only.

| Date | Array | MAC mapping | LUT | FF | DSP | CARRY4 | WNS (ns) | Fmax (MHz) |
|---|---|---|---|---|---|---|---|---|
| 2026-10-18 | 16×16 | Vivado's choice: **all 256 MACs in LUT fabric**, 0 DSP | 28,545 (45.0%) | 13,095 | 0 | 4,672 | +0.436 | 104.6 |
| 2026-10-18 | 16×16 | **two MACs per DSP48E1** (`systolic_pe_pair`, `use_dsp` on the product only) | 7,681 (12.1%) | 9,966 | **128** (53.3%) | 2,632 | +0.431 | 104.5 |

**Vivado did not infer DSPs** (buildplan §9: "DSP inference failure"): the
8 × 8 multiplies went to LUTs, about 111 LUTs per MAC. It fits and meets
100 MHz, but takes 45% of the LUTs before the DMA, interconnect and core.
With `use_dsp` and one DSP per PE (synthesis only, exploratory, not
committed): 8×8 used 64 DSP and 153 LUT; 16×16 needed 256 DSP of 240 and
does not fit. So, decided with the user: **two PEs per DSP**. Neighbouring
columns share the activation, so one 25 × 18 multiply by w0 + w1·2^16 gives
both products (spacing 16: 2^17 overflows the 25-bit A port at w1 = −128,
w0 < 0); the sums stay in fabric (a 16-bit lane cannot hold them). 128 DSP,
LUTs down 73% at the same Fmax. `use_dsp` on the whole module first gave
256 DSPs: the packing adder, which runs only at a swap, took a DSP of its
own; on the product signal alone it is one DSP per pair.

## DMA synthesis (Phase G)

`make synth-dma DMA_TOP=<module>` (default `dmaeng_regs`): out of context,
synth + place + route, `xc7a100tcsg324-1`, 10.000 ns, from
`docs/reports/summary_ooc_<module>.txt`. Cell counts, as above. Append-only.

| Date | Block | LUT | FF | BRAM | DSP | CARRY4 | WNS (ns) | Fmax (MHz) |
|---|---|---|---|---|---|---|---|---|
| 2026-11-04 | `dmaeng_regs`: AXI4-Lite slave + register file | 213 | 285 | 0 | 0 | 19 | +4.129 | 170.3 |
| 2026-11-04 | `dmaeng`: + descriptor sequencer + AXI4 master (chunk size and beat counts in one cycle; not committed) | 1,097 | 696 | 0 | 0 | 117 | −0.414 | 96.0 |
| 2026-11-04 | `dmaeng`: beat counts derived from the registered chunk size | 1,096 | 686 | 0 | 0 | 117 | +0.525 | 105.5 |

The core's `make synth` and the board's `make impl` were rerun with the
package in their source lists: reports identical but for dates.

## Accelerator synthesis (Phase G)

`make synth-accel`: `rtl/accel/gemm_accel.sv` (16×16 array, 16 KiB A/W/C
buffers, sequencer, both bus ports) alone, out of context, synth + place +
route, `xc7a100tcsg324-1`, 10.000 ns, from
`docs/reports/summary_ooc_gemm_accel.txt`. Cell counts. Append-only.

| Date | Block | LUT | FF | BRAM | DSP | CARRY4 | WNS (ns) | Fmax (MHz) |
|---|---|---|---|---|---|---|---|---|
| 2026-11-05 | `gemm_accel` 16×16, 16 KiB buffers | 10,134 | 10,948 | 24 | 131 | 2,911 | +0.135 | 101.4 |
| 2026-11-08 | same, `ARRAY_CDC` = 0 after the stream (Phase H slice 3): the direct path, cycle for cycle as before | 10,133 | 10,948 | 24 | 131 | 2,911 | +0.266 | 102.7 |
| 2026-11-09 | same, with the weight-transform hook (Phase H box 3), `WX_EXT` = 0 (identity); the `wx_*` outputs are ports out of context (in the SoC they are open and trimmed) | 10,152 | 10,958 | 24 | 131 | 2,911 | +0.362 | 103.8 |

`ARRAY_CDC` = 1 has two clocks: its row is in "CDC synthesis" below.

## Accelerator against software matmul (Phase H)

`sw/apps/matbench.c` on the board ([matbench_board.txt](reports/matbench_board.txt);
Arty A7, 100 MHz, `ARRAY_CDC` = 0, three runs identical): the same INT8 GEMM
on the core alone, through the accelerator as software calls it (DMA in, job,
DMA out), and the job alone; the two results compared by hash, 7/7 equal.
Cycles of the 100 MHz core clock. **RV32I** software: an INT8 shift-add
multiply (faster than libgcc's general one).

| Shape | Software | Call | Job | Speedup (call) | Speedup (job) |
|---|---|---|---|---|---|
| 8×8×8 | 35,945 | 3,488 | 53 | 10.3× | 678× |
| 16×16×16 | 289,817 | 2,631 | 61 | 110× | 4,751× |
| 32×32×32 | 2,294,537 | 8,106 | 299 | 283× | 7,674× |
| 48×48×48 | 7,723,305 | 17,293 | 813 | 447× | 9,500× |
| 56×56×56 | 12,216,633 | 40,980 | 1,571 | 298× | 7,776× |
| 128×16×16 | 2,280,201 | 12,959 | 173 | 176× | 13,180× |
| 20×50×30 | 2,092,329 | 16,158 | 499 | 129× | 4,193× |

The call is what software sees. Off the 16 grid (56, 20×50×30) the DMA moves a
row per descriptor, so 56³ costs 2.4× 48³'s call for 1.6× its MACs. 8×8×8's
call is slower than 16×16×16's: the same per-row DMA.

**RV32IM** software (`matbench_m`, the same source built `-march=rv32im`, so
the software matmul uses `mul`): same file, second section; Arty A7, 100 MHz,
`make impl M=1` at `d2f363b` (`summary_board_m.txt`), `ARRAY_CDC` = 0,
three runs identical, 7/7 equal. A different board build from the RV32I table:
the job cycles match it exactly, the call differs by a few cycles (code layout).

| Shape | Software | Call | Job | Speedup (call) | Speedup (job) |
|---|---|---|---|---|---|
| 8×8×8 | 6,243 | 3,490 | 53 | 1.8× | 118× |
| 16×16×16 | 47,291 | 2,483 | 61 | 19.0× | 775× |
| 32×32×32 | 369,003 | 7,931 | 299 | 46.5× | 1,234× |
| 48×48×48 | 1,235,483 | 17,121 | 813 | 72.2× | 1,520× |
| 56×56×56 | 1,957,491 | 40,982 | 1,571 | 47.8× | 1,246× |
| 128×16×16 | 378,251 | 12,757 | 173 | 29.7× | 2,186× |
| 20×50×30 | 335,031 | 16,160 | 499 | 20.7× | 671× |

Against an honest software baseline the accelerator, as software calls it,
wins 1.8× to 72×; `mul` makes the software matmul 5.8-6.3× faster than
shift-add. At 8×8×8 the DMA setup nearly cancels the array.

## Accelerator PE utilization (Phase H)

Utilization = useful MACs (M·K·N) / (cycles × 256 PEs). From
[pe_utilization.txt](reports/pe_utilization.txt), generated by
`scripts/pe_utilization.py` from the Phase G board log
([gemmtest_board.txt](reports/gemmtest_board.txt), Arty A7, 100 MHz,
`ARRAY_CDC` = 0; the script stops unless every job equals `job_cycles()`)
and, for larger shapes, from `job_cycles()` itself (the model every RTL test
holds CYCLES to). **Job** = START to idle; **call** = DMA in + job + DMA out.

| Shape (M×K×N) | Source | Job cycles | Job util | Call cycles | Call util |
|---|---|---|---|---|---|
| 16×16×16 | board | 61 | 26.2% | 2,629 | 0.61% |
| 24×20×24 | board | 267 | 16.9% | 11,704 | 0.38% |
| 3×33×17 | board | 273 | 2.4% | 5,923 | 0.11% |
| 64×64×64 | model | 1,699 | 60.3% | — | — |
| 128×64×32 | model | 1,363 | 75.1% | — | — |
| 256×64×16 | model | 1,195 | 85.7% | — | — |

Why: each tile costs ROWS + 1 + LATENCY + 2 = 42 cycles besides its M rows
(weight load, swap, drain; tiles do not overlap), so a tile runs at
M / (M + 42); the C buffer caps M at 256 per N tile, so the job tops out at
85.9%. Shapes off the 16 grid waste the padded lanes (17×17×17: 8.0%,
model). The **call** is the real number for software today: the DMA moves
one 32-bit beat a cycle and needs a descriptor per row when K or N is not a
multiple of 16; with the core's descriptor setup and polling, everything
but the job is 95-98% of the call on the board shapes. Levers, each its own measured
change: overlap the next tile's weight load with the drain; a wider DMA
port into the buffers. With `ARRAY_CDC` = 1 at equal clocks a tile costs
2·SYNC_STAGES + 1 cycles more ("Array clock domain: model cost").

## M-extension synthesis (Phase H)

`make synth-muldiv`: `rtl/core/riscv_muldiv.sv` alone, out of context,
synth + place + route, `xc7a100tcsg324-1`, 10.000 ns, from
`docs/reports/summary_ooc_riscv_muldiv.txt`. Append-only. RV32IM rows of the
core go in their own table when the unit is in it.

| Date | Block | LUT | FF | BRAM | DSP | CARRY4 | WNS (ns) | Fmax (MHz) |
|---|---|---|---|---|---|---|---|---|
| 2026-11-06 | `riscv_muldiv`: 4-DSP multiply (3 cycles), radix-2 restoring divide (34) | 497 | 109 | 0 | 4 | 53 | +3.308 | 149.4 |

### RV32IM core (M_EXT = 1)

`make synth-m`: `riscv_core` built with M_EXT = 1, out of context, synth +
place + route, `xc7a100tcsg324-1`, 10.000 ns, from
`docs/reports/summary_ooc_m.txt`. Never compared row-for-row with the RV32I
trend table; the cost of M is this row against the RV32I core of the same date
(966 LUT / 467 FF / 0 DSP, 119.7 MHz). Append-only.

| Date | Build | LUT | FF | DSP | CARRY4 | WNS (ns) | Fmax (MHz) |
|---|---|---|---|---|---|---|---|
| 2026-11-07 | `riscv_core` M_EXT = 1, unit in EX, IF/ID/EX held while it works; worst path not in M (ID/EX forwarding select → branch compare → redirect → IF/ID reset, 6 levels) | 1440 | 577 | 4 | 108 | +1.298 | 114.9 |
| 2026-11-07 | `riscv_core_tmr` M_EXT = 1, three copies each with a unit; worst path through the voter (copy B's forwarding select → vote → copy C's pc, 14 levels), not in M | 5343 | 2209 | 12 | 416 | +0.608 | 106.5 |

The report times register to register only (only the clock is constrained).
Worst path: one restoring step, `quo_q` → `rem_q`, 11 levels. The paths
through the ports were measured once more with flops on every port (a
scratch wrapper, not committed; same part, constraint and flow), as they will
be timed in the core: **product sum, partial-product register → result
flop, 6.467 ns** (10 levels), operand flop → DSP input 3.941 ns, worst
overall still the divide step (6.333 ns). So MUL's result can leave the unit
unregistered: the core adds the EX result mux after it. Unconstrained OOC
port timing had shown 8.857 ns for the same sum, 74% of it routing to
unplaced ports.

## CDC synthesis (Phase H)

`make synth-cdc`: `rtl/cdc/cdc_async_fifo.sv` alone, out of context, synth +
place + route, `xc7a100tcsg324-1`, two unrelated 10.000 ns clocks, gray
crossings bounded by `set_max_delay -datapath_only` (one source period) and
`set_bus_skew` (half a destination period), not cut
([constr/cdc_ooc.xdc](../constr/cdc_ooc.xdc)); from
`docs/reports/summary_ooc_cdc_fifo<W>x<D>.txt`, with `report_cdc`
(`cdc_ooc_*.rpt`) and `report_bus_skew` (`bus_skew_ooc_*.rpt`). LUT is LUT
cells, as elsewhere; LUTRAM (LUTs used as distributed RAM, the storage) is
its own column. Append-only. `make synth-accel ACCEL_CDC=1`: the whole
accelerator built with `ARRAY_CDC` = 1 (the array on `clk_array`), same
flow, [constr/accel_cdc_ooc.xdc](../constr/accel_cdc_ooc.xdc), which also
bounds each FIFO's storage read and waives it in `report_cdc` (CDC-1, -13,
-15, -26: the storage of an async FIFO is read only after its pointer has
crossed, which the tool cannot see); BRAM, DSP and CARRY4 in the row.

| Date | Block | LUT | LUTRAM | FF | WNS (ns) | Fmax (MHz) | report_cdc | Bus skew |
|---|---|---|---|---|---|---|---|---|
| 2026-11-07 | `cdc_async_fifo` 259×16 (the array's input stream) | 32 | 174 | 38 | +4.010 | 166.9 | 1 Info (CDC-3), 9 gray endpoints waived (CDC-6), nothing else | met, +4.072 / +4.254 |
| 2026-11-08 | `gemm_accel` `ARRAY_CDC` = 1, 16×16 (24 BRAM, 131 DSP, 2,915 CARRY4; FIFOs 259×16 in, 512×32 out); against `ARRAY_CDC` = 0: +90 LUT, +516 LUTRAM, +101 FF | 10,223 | 516 | 11,049 | +0.137 | 101.4 | 3 Info (CDC-3 ×2, CDC-9 the reset), 20 gray endpoints (CDC-6) and 2,943 storage endpoints waived, nothing else | met, worst +3.673 of 4 |
| 2026-11-08 | same, the array-side reset synchronizer fed from a registered copy of `rst_i` (slice 4; constraints split into `accel_cdc_ooc.xdc` clocks + `accel_cdc.xdc` crossings, shared with the board) | 10,220 | 516 | 11,070 | +0.078 | 100.8 | 4 Info (CDC-3 ×2, CDC-9 ×2: both reset synchronizers), 20 gray and 2,942 storage endpoints waived, nothing else | met, worst +3.581 of 4 |
| 2026-11-09 | same, with the weight-transform hook on the clk_i side (box 3, `WX_EXT` = 0) | 10,245 | 516 | 11,054 | +0.128 | 101.3 | 4 Info (unchanged), 20 gray and 2,942 storage endpoints waived, nothing else | met, worst +3.927 of 4 |

The first run found the gray pointer's top bit unconstrained: Vivado merges
it with the binary pointer's (equal by construction), so a name filter on
`wgray_q` missed it. The constraints now take every startpoint in the fanin
of the first synchronizer flop.

## Array clock domain: model cost (Phase H)

`python3 sw/model/accel_cdc_model.py --costs`: the golden model, not RTL
(slice 3 measures the RTL against it). 16×16 array, core clock 100 MHz,
SYNC_STAGES 2, input FIFO 16 entries, CYCLES in core cycles over 20 array
phases, against ARRAY_CDC = 0 (`job_cycles`: 61, 1699, 301); last column is
the smallest output FIFO (of 8 to 64) that costs no cycle at any shape here.

| f_array | 16×16×16 | 64×64×64 | 256×16×16 | Output FIFO |
|---|---|---|---|---|
| 200 MHz | 53-54 (0.89×) | 1571-1587 (0.93×) | 293-294 (0.98×) | 24 |
| 125 MHz | 61 (1.00×) | 1699 (1.00×) | 301 (1.00×) | 32 |
| 100 MHz | 66-67 (1.10×) | 1779-1795 (1.06×) | 306-307 (1.02×) | 32 |
| 80 MHz | 80-81 (1.33×) | 2202-2204 (1.30×) | 380-381 (1.27×) | 32 |
| 50 MHz | 123-125 (2.05×) | 3459-3491 (2.05×) | 603-605 (2.01×) | 32 |
| 25 MHz | 237-241 (3.95×) | 6849-6853 (4.03×) | 1197-1201 (3.99×) | 32 |

At equal clocks the two crossings cost 5 or 6 cycles a tile (6 when the
edges coincide). A faster array drains a tile sooner, so ARRAY_CDC = 0's
count is not a lower bound; a slower one sets the pace at one row per array
cycle.

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
| 2026-11-10 | #1's config on the current RTL (Phase H core: `M_EXT`, `MEM_WAIT` off), no scan; baseline for scan (`summary_asic_core_noscan.txt`) | 35 ns | 227,667 | 119,019 (56.2%) | 13,838 (1,496) | +2.807 ns | +12.283 ns | 31.1 / 44.0 MHz | 49.5 MHz | 4.49 mW | clean / clean | 2991 |
| 2026-11-10 | **same, with scan chains** (`make asic SCAN=1`, 8 chains × 187; `summary_asic_scan.txt`) | 35 ns | 227,667 | 131,724 (62.2%) | 14,397 (1,496) | +3.613 ns | +13.408 ns | 31.9 / 46.3 MHz | 52.6 MHz | 7.38 mW* | clean / clean | 3707 |

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

**Scan chain insertion (§6.5), on the core (2026-11-10).** LibreLane has
no DFT step; `syn/librelane_plugin_scan` adds two OpenROAD steps to the
classic flow (`syn/asic_scan.yaml`, `make asic SCAN=1`): `scan_replace`
after the floorplan (every `dfxtp` to `sdfxtp`; the step fails if one is
left) and `execute_dft_plan` after the pin-less global placement (chains in
placement order, ports placed by the IO step). **8 chains of 187 flops, all
1,496 on a chain, one scan enable**; two chains end on a functional output
(`id_ex_rs1_addr_o[1]`, `ex_mem_pc_o[24]`) that OpenROAD reused as scan
out. Checked on the routed netlist ([scan_chains_asic.txt](reports/scan_chains_asic.txt)):
`scripts/scan_chains.py` traces each chain through the resizer's buffers
and each flop's scan enable back to the one port; `scripts/scan_shift_tb.py`
shifts random bits through all eight at gate level (Icarus, the PDK's cell
models), 3,024 scan-out bits correct over 565 cycles. Planted faults caught
(on the stitched netlist): a flop skipped in a chain, scan enable held low,
a chain length off by one. **Overhead against the same RTL without scan:
standard-cell area +10.7%** (+12,705 µm², the flops +29.4%: `sdfxtp_1`
is a mux in front of the flop), cells +559, routed wirelength +17.6%, hold
buffers +158; **no setup cost** (+3.613 ns against +2.807 ns, placement
noise; the scan mux is on each flop's D input, which had slack). *Power
+64% is the vectorless estimate's default activity on the scan ports and
the scan-enable tree (in mission mode scan enable is constant); not a
measured mission-mode number. First run of the step: the new ports had no
signal type and the flow's own LEF reader rejected the block LEF
(`USE ;`, LEFPARS-1); the step now types them. The baseline row reran
#1's config by hand on today's RTL (2,991 slew violations, −0.7 ns setup
against the committed #1: RTL drift since Phase E). Coverage (Quaigh) and
the SoC's chains come with run #2.

### Run #2: the SoC (Phase H)

`make asic SOC=1`: `asic_top` (`soc`'s defaults: single core, RV32I; AXI crossbar, DMA, 16×16
GEMM accelerator, UART; `syn/asic_soc.yaml`, `syn/asic_soc.sdc`), every RAM
as one of **48 OpenRAM macros** placed by hand, die 6000 × 5200 µm, 50 ns
(20 MHz), I/O delay 20% of the period, `rst_i` and `uart_rx_i` false paths,
PnR at nom_tt + max_ss + min_ff, signoff at 9 corners. The macros ship one
liberty (typical, 1.8 V, 25 °C), so **SRAM timing at the ss and ff corners
is the typical model**; the project copies raise addr/wmask's 40 ps
max_transition to 0.5 ns (yaml comment). Numbers from
[summary_asic_soc.txt](reports/summary_asic_soc.txt). Append-only.

| Date | Run | Clock | Die µm² | Std-cell µm² (util) | Cells (seq) | Setup WS worst | Hold WS worst | Fmax worst / typical | Power (tt) | DRC / LVS / antenna | Max slew / cap / fanout viol. (all corners) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-23 | **#2, the SoC (committed reports, timing closes)** | 50 ns | 31,200,000 | 3,704,850 (51.2%) | 710,656 incl. 256,840 taps (19,557) | **+0.695 ns** (max_ss) | +0.075 ns (max_ff) | 20.3 / 26.6 MHz | 87.7 mW | clean / clean / 1 net | 83,303 / 2,274 / 8,081 |
| 2026-11-25 | **#2 with scan chains** (`make asic SOC=1 SCAN=1`, 8 chains of 2,442 to 2,445; post-GRT slew/cap repair margin **10%, not 30%**; `summary_asic_soc_scan.txt`) | 50 ns | 31,200,000 | 3,954,360 (52.0%) | 741,927 incl. 256,840 taps (19,557) | +0.532 ns (max_ss) | +0.082 ns (max_ss) | 20.2 / 26.5 MHz | 95.3 mW* | clean / clean / 5 nets | 166,370 / 3,154 / 9,697 |

**Timing closes, the electrical rules do not.** 0 setup and 0 hold
violations at all 9 corners; Magic DRC 0 (KLayout DRC is off for the SoC,
yaml), LVS 0, GDS XOR 0. One antenna net is left (ratio 1.45, a hold
buffer's input on met1). Max slew is counted against LibreLane's 0.75 ns
limit: at max_ss 83,303 pins, 37,597 of them antenna-diode pins and 45,706
signal pins; **4,024 pins exceed the cell library's own 1.5 ns** (worst
3.44 ns), where STA extrapolates past the characterized tables, so ss timing
through them is less certain than the slack says. At nom_tt: 15,911 (8,065
signal), 30 above 1.5 ns. Pre-layout estimate (synthesised netlist, before
any buffering): −1,652 ns, not usable.

**Why the slew is left.** LibreLane repairs slew and cap once after global
routing, on estimated parasitics, and inserts every antenna diode after
that step; nothing repairs after detailed routing. The steps taken
(2026-11-15 to 23), with signoff counts at max_ss (all pins / signal pins):

| Change | Max slew, max_ss | Max slew, nom_tt | Note |
|---|---|---|---|
| 11-15 run (post-GRT repair off: the SRAM .lib's 40 ps limit stopped it, RSZ-0090) | 95,382 | 12,968 | setup +0.54, hold −0.92 on `uart_rx_i` |
| + SRAM .lib copies, post-GRT repair on at 10% margin (routed trial, not signoff) | 87,894 / 81,232 | 9,772 / 6,951 | repair saw 6,755 violations at GRT |
| + repair margin 30%, heuristic diodes (this run) | 83,303 / 45,706 | 15,911 / 8,065 | 148,953 diodes in all, nearly every one heuristic (nets over 90 µm) |

**Detailed routing failed twice on DRT-1231** (OpenROAD issue #12200, open):
after its antenna repair (11,605 diodes) the incremental reroute lost every
access point of an SRAM pin (g_c[15] `dout0[24]`; on the scan run
`dout0[18]`, then g_c[7] after a move). Fix: g_c[15] 0.46 µm left (half a
met4 pitch; its pins were off the tracks the other 15 sit on) and
`RUN_HEURISTIC_DIODE_INSERTION`, which fixes antennas before routing (6,486
violating nets → 0) so routing inserts almost none. About 13.5 h on the
desktop (Ryzen 5 5600): 2.5 h to post-GRT repair, then 11.0 h resumed from
that step (`ASIC_FROM`) with the 30% margin; peak memory 27.1 GB.

**Scan on the SoC (2026-11-25).** Same flow, RTL and config as #2 plus
`syn/asic_scan.yaml`, with one difference: it was started before #2's
post-GRT slew/cap margin went from 10% to 30%, and was not rerun (user's
call, 2026-11-25). Read from the run's step configs: the post-GRT repair
step's `config.json` is the only one differing from #2's (`resolved.json`
was rewritten by the signoff-only resume and shows 30%). **8 chains,
2,442 to 2,445 flops, all 19,557 on a chain, one scan enable**
([scan_chains_asic_soc.txt](reports/scan_chains_asic_soc.txt)), including
the reset synchronizer's 2 flops (`sdfsbp`, asynchronous set); shifted at
gate level on the routed netlist, 39,155 scan-out bits over 7,339 cycles,
`rst_i` held low (`--tie`) and the SRAMs as port-only stand-ins
(`tb/asic/sram_blackbox.v`). Timing: 0 setup and 0 hold violations at all
9 corners, after one SDC change: `scan_in_*` given an input delay of half
the period (`syn/asic_soc.sdc`). At the base 20% (10 ns) they failed hold
at the ss corners (−1.822 ns at max_ss, 23 paths, all `scan_in`): the clock
reaches the first scan flops ~13.6 ns after the edge. The test then has to
drive `scan_in` 25 ns after `clk_i`; checked by a direct OpenSTA query on
the final netlist (`input external delay 25.000`, hold slack +19.7 ns at
max_ss, unannotated). **Overhead against #2:** standard-cell area +249,510
µm² (+6.7%), of which the flops +122,381 µm² (+29.4%, the same as the
core's; 3.3% of #2's cell area), routed wirelength +8.7%, cells +31,271,
repair buffers +9,795. Only the flop figure is free of the margin
difference: the rest (and the doubled slew count, 4 more antenna nets) mix
scan with 10% against 30%. *Power +8.6%: the vectorless default activity
on the scan ports and enable tree, as on the core.
**Coverage** ([scan_coverage_asic_soc.txt](reports/scan_coverage_asic_soc.txt),
`scripts/scan_coverage.py`): **98.96%** of 1,449,256 collapsed stuck-at
faults (20,847 patterns); of the 15,034 undetected, 13,855 proven
untestable and 1,179 unresolved (SAT found a pattern that fault simulation
did not confirm; seed-dependent; on the core 6 with seed 1, 20 with seed
7). The 48 SRAMs are cut at their boundary (read data controlled, inputs
observed), which assumes a bypass wrapper this chip does not have; 4.83%
of the uncollapsed faults sit on logic that assumption decides. Stock
Quaigh 0.0.6 ran out of memory (killed at 25 GB on the laptop, at a 28 GB
cap on the desktop at 96% detection): one bool per fault per pattern,
~1.45 MB a pattern. `scripts/quaigh-sparse-detections.patch` stores them
sparse (identical patterns and results on the core, seeds 1 and 7; peak
1,004 → 126 MB there); the SoC then took 4 h 37 min at 8.3 GB peak on the
desktop, run twice with identical numbers. **The core, routed**
([scan_coverage_asic.txt](reports/scan_coverage_asic.txt), 2026-11-25,
`make asic SCAN=1`, whose summary and chain reports came out identical to
the committed ones): **99.12%** of 56,246 (486 proven untestable, 8
unresolved), 1,977 patterns. The 99.02% of 50,222 quoted earlier was the
stitched, unrouted netlist (no resizer buffers yet).

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

### RV32IM (Phase H)

Kept apart from RV32I's rows: the core built with M_EXT (`make impl M=1
FW_IMAGE=sw/build/coremark_m.hex`), CoreMark compiled `-O2 -march=rv32im
-mabi=ilp32` (multiply and divide inline; libgcc only in the port's report
printing, after the timed region), 5000 iterations (`COREMARK_M_ITERATIONS`,
~20 s). Simulation: `soc_m:test_coremark` → `docs/reports/coremark_m_sim.txt`.

| Date | Build | Core clock | Iterations | Cycles | CoreMark/MHz | IPC (sim) |
|---|---|---|---|---|---|---|
| 2026-11-07 | RV32IM: M unit in EX (MUL 3 cycles, DIV 34), SoC as Phase G | 100 MHz | 5000 | 1,999,390,615 | **2.500** | 0.712 |
| 2026-11-07 | RV32IM, TMR (three voted cores, each with its unit) | 100 MHz | 5000 | 1,999,390,615 | **2.500** | 0.712 |

Board ([coremark_m_board.txt](reports/coremark_m_board.txt)): "Correct operation
validated", **about 250 CoreMark at 100 MHz (RV32I: 96, 2.6×)**; the TMR bitstream
([coremark_m_board_tmr.txt](reports/coremark_m_board_tmr.txt)) cycle-identical; 399,878 cycles
per iteration against simulation's 399,865 (0.003%). Simulation, 2026-11-07, 1 iteration ([coremark_m_sim.txt](reports/coremark_m_sim.txt)):
284,853 instructions retired in 399,865 cycles (RV32I: 718,009 in 1,038,833),
IPC 0.712, **2.501 CoreMark/MHz for one iteration (RV32I 0.963, 2.6×)**; CRCs
correct; the TMR SoC (`soc_tmr_m:test_coremark`) the same with zero
mismatches.
