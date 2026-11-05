# RISC-V RV32I SoC — Formally Verified, Fault-Tolerant, with an ML Accelerator

A 5-stage in-order RV32I CPU written from scratch in SystemVerilog, **formally
verified, checked by a UVM environment against a golden model, and running on
an FPGA at 100 MHz**: a Digilent Arty A7-100T, where it runs CoreMark at
0.962 CoreMark/MHz. It can also run as **three voted copies (triple modular
redundancy)**, still at 100 MHz: in 10,000 injected single-bit faults, none
changed its output, and on the board it shrugs off faults injected live
while it computes. The core has also been taken through the open-source
LibreLane flow to a **DRC- and LVS-clean layout on SkyWater's 130 nm
process**, timing met at all nine signoff corners.

The project has two stages. Stage 1 is the CPU: verified, hardware-proven,
then made fault-tolerant with triple modular redundancy (TMR) and taken through
an open-source ASIC flow to GDSII. Stage 2 builds an SoC around it: an INT8
systolic-array accelerator, a descriptor-based DMA and an AXI interconnect.
**Stage 1 (Phases A–E) is done**: the CPU is verified, running on the
board, fault-tolerant and taken to GDSII. Stage 2 is under way: the
systolic-array accelerator (Phase F) is built and verified on its own.

Every number below is transcribed from a report committed in
[`docs/reports/`](docs/reports/), produced by a `make` target, with its
measurement conditions stated. Dashes mean not measured yet.

[![Floorplan of the TMR core on the FPGA](docs/img/floorplan_board_core.svg)](docs/img/floorplan_board_core.svg)

*The fault-tolerant core as placed and routed on the Artix-7: three copies of
the CPU (orange, green, cyan) and the voter between them (magenta), beside
the block-RAM memory (white) and the UART (red), with the critical path in
yellow. Generated from the routed design by `make floorplan`. Click to open
it, or download it and open it in a browser to zoom in to individual LUTs
and flip-flops. The single core's floorplan, from Phase D, is
[here](docs/img/vivado/phase-d/floorplan_board_core.svg).*

## At a glance

| | |
|---|---|
| **ISA** | RV32I, all 40 instructions; every exception traps (halts) |
| **Pipeline** | 5 stages, full forwarding, 1-cycle load-use stall, branches resolved in EX (static not-taken) |
| **On the board** | Arty A7-100T, **100 MHz**, timing met with +0.955 ns slack (110.6 MHz estimate); the TMR core also meets 100 MHz (+0.095 ns) |
| **CoreMark** | **0.962 CoreMark/MHz**, about **96 CoreMark** at 100 MHz, validated, with no hardware multiply |
| **IPC** | 0.691 on CoreMark (CPI 1.447), counted in RTL simulation of the same SoC; it matches the board's cycle count to 0.0013% |
| **Size** | 966 LUT, 467 FF (core alone); 1123 LUT, 435 FF, 8 BRAM (whole SoC on the board): under 2% of the chip. TMR: 3446 LUT, 1621 FF on the board |
| **Fault tolerance** | Three voted copies with feedback; voter formally proven; **10,000 random single-bit faults, 0 failures**, every detected fault corrected and the copies back in step; **live on the board**, 250,971 faults injected over 133 runs of one computation, all outvoted, every run the same answer and the same cycle count |
| **Accelerator** | A 16×16 INT8 weight-stationary systolic array, **two multiply-accumulates per DSP slice**: 256 MACs on 128 DSP48E1, 7,681 LUT, 104.5 MHz (array alone, out of context); bit-exact against a NumPy golden model written first, on 5,000 GEMMs at three array sizes. Not yet connected to the core (Phases G and H) |
| **As a chip** | The core through LibreLane to GDSII on Sky130 (130 nm): 0.23 mm² die, 13,853 cells, **DRC and LVS clean**, timing met at all 9 corners at 35 ns, **31.7 MHz worst case** (slow silicon, 100 °C, 1.60 V), 50.6 MHz typical |
| **Formal** | riscv-formal **46/46 checks**; the pipeline's hazard, forwarding, flush, reset and X-propagation properties proven by k-induction; every check shown reachable, and the consistency checks shown to fail on planted bugs |
| **Bugs formal caught that simulation missed** | **2**, both of which would have broken the ASIC (below) |
| **UVM** | **205/205** functional coverage bins (100%); ~45,000 retirements per run compared with a C golden model, 0 mismatches |
| **Simulation** | 320/320 cocotb tests, including the official `riscv-tests` suite (40/42; the 2 exclusions are explained) |
| **Interactive** | A serial bootloader: programs load over the UART in a fraction of a second, no FPGA rebuild; seven interactive demos, one of them injecting faults into the running TMR core |
| **CI** | Lint, simulation and formal on every push |

## Status

| Stage | Phase | State |
|---|---|---|
| **1 — CPU** | A — Working core | **Done** |
| | B — Formal verification | **Done** |
| | C — UVM environment | **Done** |
| | D — Hardware bring-up | **Done** |
| | E — TMR + fault injection, ASIC run #1 | **Done** |
| **2 — SoC** | F — Systolic array | **Done** (on its own; joined to the core in H) |
| | G — DMA + AXI interconnect | **In progress**: the DMA engine replays DMA-Engine's golden trace and runs on the SoC under software, through an AXI4 crossbar whose §6.2 properties are proven; the accelerator on the bus and the release remain |
| | H — Integration + DFT, ASIC run #2 | Not started |

Full scope and each phase's definition of done: [docs/buildplan.md](docs/buildplan.md).
Day-to-day state, trend tables and decisions: [docs/PROGRESS.md](docs/PROGRESS.md).

## Architecture

```mermaid
flowchart LR
    subgraph core["riscv_core (rtl/core/)"]
        IF["IF<br/>pc, fetch"] --> ID["ID<br/>decode, regfile read,<br/>hazard + forwarding select"]
        ID --> EX["EX<br/>ALU, branch compare + target,<br/>data address, store issue"]
        EX --> MEM["MEM<br/>load data aligned"]
        MEM --> WB["WB<br/>register write"]
        EX -. "forward EX/MEM" .-> EX
        MEM -. "forward MEM/WB" .-> EX
        WB -. "write-through regfile" .-> ID
        EX -- "redirect: flush IF/ID, ID/EX" --> IF
    end
    IF <-->|"instruction port"| RAM["32 KiB dual-port block RAM<br/>(code + data)"]
    EX <-->|"data port"| RAM
    EX <--> IO["I/O: 4 LEDs, UART TX 115200,<br/>cycle counter"]
```

- **Five stages, BRAM-timed memories.** Fetch presents the next pc to the block
  RAM so RAM and pc latch on the same edge. Data memory is accessed from EX:
  the address comes from its own adder, and load data arrives in MEM and is
  registered, so no forwarding path starts at a RAM output. That change took
  the board from 50 MHz to 100 MHz.
- **Forwarding** from EX/MEM and MEM/WB into EX, with the selects decided in ID
  and registered; WB writes through the register file to ID. One stall cycle
  for a load followed directly by its use.
- **Branches and jumps resolve in EX** with static not-taken prediction:
  taken costs two cycles, not taken none.
- **Exceptions halt**: ECALL, EBREAK, illegal instructions (anything outside
  the 40 RV32I encodings), misaligned accesses and misaligned taken targets.
- **SoC** (`rtl/top/soc.sv`): the core, one 32 KiB dual-port RAM for code and
  data, LED and UART (transmit and receive) registers and a cycle counter at
  `0x1000_0000`. The RAM boots a serial bootloader (`sw/boot/`) that receives
  programs from `scripts/load.py` and runs them.
  `arty_a7_top.sv` adds the MMCM (100 MHz), the reset synchroniser and the
  pins.
- **RVFI** trace port and the formal properties live in the RTL under
  `ifdef`, compiled out of synthesis.

## Verification

Four independent layers, each catching what the others cannot.

**Formal** (`make formal`, SymbiYosys and riscv-formal, about 6 minutes;
[docs/formal-properties.md](docs/formal-properties.md)):

- **riscv-formal: 46/46 checks** by bounded model checking: all 37
  instruction checks, plus register, pc forward/backward, uniqueness, causal,
  causal memory, liveness, hang and illegal-instruction checks. Each of the
  46 has a cover run showing it is reachable, and each consistency check was
  shown to fail on a deliberately planted bug.
- **Pipeline properties proven by k-induction**, which covers every reachable
  state, not just a bounded depth: x0 is always zero; stall correctness
  (S1–S4); forwarding correctness (F1/F2, L1); reset commits nothing (X1);
  branch-flush correctness (B1/B2); no register-file structural hazard (SH1);
  nothing left over from power-up ever reaches committed state as X (XP,
  induction; XT, bounded with an undefined register file).
- **Two bugs found that simulation missed:**
  1. **Yosys misreads a size cast.** `~XLEN'(2'b11)` was parsed with the `~`
     applied to the width, so jump targets were never masked. Verilator and
     Vivado read it correctly, so simulation and the FPGA were fine, but Yosys
     is also the front end of the ASIC flow. Without this check, the chip's
     jumps would have landed on unaligned addresses.
  2. **Reset could write garbage to data memory.** The pipeline registers hold
     their power-up values during the reset cycle, and nothing gated the store
     port. Verilator and the FPGA both power flops up to zero, so it never
     showed; on an ASIC, flops power up random. Now proven impossible (X1).

**UVM** (`make uvm`, Vivado XSim): random programs from a constrained
generator, a reactive memory responder, and a scoreboard that steps a C golden
model (via DPI-C) on every RVFI retirement. **205/205 coverage bins** from
[docs/coverage-plan.md](docs/coverage-plan.md), about 45,000 retirements per
run, 0 mismatches. Three planted RTL bugs (wrong forwarding priority, LBU
sign-extending, a missing load-use stall) are each caught.

**Simulation** (`make sim`, cocotb on Verilator): **320/320 tests**. Unit
tests for every module; random programs with every retirement checked against
a Python golden model; the official **`riscv-tests` rv32ui suite, 40 of 42**
(`fence_i` needs the Zifencei extension; `ma_data` expects misaligned
accesses to work, and this core traps them); the first-light firmware and one
CoreMark iteration on the whole SoC, CRCs checked; the bootloader receiving a
program bit by bit on the RX pin; and each of the seven demos below, its output
checked against an independent Python model. The core's tests and the SoC's
first-light, CoreMark and bootloader tests run again on the TMR core, which
must also report zero mismatches, and 1,000 injected faults must change
nothing. The systolic array's tests are in the same regression (below).

**On the hardware**: an Integrated Logic Analyzer on the pipeline registers,
captured from the running chip and checked by script (below).

## Fault tolerance (TMR)

Three copies of the core run in lockstep, and a 2-of-3 voter
([`rtl/tmr/`](rtl/tmr/)) decides everything that leaves them: the fetch
address, every memory access, every register write and the halt. The voted
values also go **back into all three copies** (their pc, halt flags and
register files), so a copy that a fault knocks off course is outvoted on the
cycle it diverges and then pulled back into step. A mismatch counter, readable
by software at `0x1000_0014`, counts disagreements.

- **The voter is formally proven** for every input: any two agreeing inputs
  produce that output, and the mismatch and which-copy flags are exact.
- **Three copies survive synthesis**: `DONT_TOUCH` and `KEEP_HIERARCHY` stop
  Vivado merging them, and the build fails if any copy is missing (1601
  cells each, [`summary_ooc_tmr.txt`](docs/reports/summary_ooc_tmr.txt)).
- **Fault injection** (`make faults`): 10,000 trials, each a fresh random
  program with one random bit flipped in one copy, in any pipeline register
  or the register file, at a random cycle, judged against the golden model
  ([`tmr_faults.txt`](docs/reports/tmr_faults.txt)):

| 10,000 single-bit faults | Count | |
|---|---|---|
| Output wrong (failure) | **0** | |
| Detected (copies disagreed) | 1,275 | all corrected; all three copies identical again afterwards |
| Masked (the bit was never used) | 8,725 | 5,777 of them still sitting in registers the programs never touch |
| Disagreement length | median 1 cycle | 90th percentile 4, max 30 |

The latent ones are the honest limit of voting: a flipped bit in a register
the program never writes again stays in that copy, outvoted whenever it is
read, until software rewrites the register.

- **Live, on the board** (demo 7, [`tmr_inject_board.txt`](docs/reports/tmr_inject_board.txt)):
  a write to `0x1000_0014` flips the written bits of copy B's program
  counter for real, in the flop. The demo runs a prime sieve once clean,
  then again and again until a key, each pass flipping a random pc bit every
  64 composites marked (1,887 flips a pass), with the totals on screen and
  on the LEDs. Every pass executes the same instructions (the clean one
  writes 0), so they compare exactly:

| Sieve to 163,840 on the TMR core, 100 MHz | Passes | Primes | Cycles per pass | Faults injected | Detected |
|---|---|---|---|---|---|
| Clean | 1 | 14,999 | 3,354,864 | 0 | 0 |
| Injected | 133 | 14,999 every pass | 3,354,864 every pass | 250,971 | 250,971 |

  Same answer, not one cycle lost: correction happens in the vote, with
  no stall or retry. Simulation of the same SoC gives the same counts. On the
  single-core build the writes do nothing, and the demo says so.

https://github.com/user-attachments/assets/3b082685-84fa-4263-9e76-155c5df5d54e

*On the board, TMR build: demo 7 injecting faults pass after pass. In the terminal the flip and detected totals climb together while primes and cycles stay the same; on the Arty, LD4-LD7 count the disagreements in binary (one step per 4,096).*

What it costs, same RTL, same conditions:

| | Single core | TMR | |
|---|---|---|---|
| Board LUT / FF | 1123 / 435 | 3446 / 1621 | 3.1x / 3.7x |
| Board Fmax (100 MHz target) | 110.6 MHz | 101.0 MHz | −8.7% |
| Core alone, out of context | 966 LUT, 120.4 MHz | 3690 LUT, 101.4 MHz | 3.8x, −15.8% |

The TMR build includes the mismatch counter and the live injector.

## Systolic array (Phase F)

A weight-stationary INT8 array ([`rtl/accel/`](rtl/accel/)): each PE holds
one weight, activations stream left to right and partial sums flow down, so
a 16×16 array does 256 multiply-accumulates a cycle. A row of A goes in as
one vector and its results come out as one vector 23 cycles later; the
array skews and deskews internally. Weights are double-buffered, so the next
tile loads while the current one computes.

**Golden model first.** [`sw/model/gemm_model.py`](sw/model/gemm_model.py)
was written before any RTL: INT8 GEMM with INT32 accumulation, a
cycle-by-cycle model of the array, the DSP packing and the requantization
(per-column fixed-point scale, round half away from zero, saturate to INT8).
It checks itself against plain Python integers and exact fractions
(`make gemm-model`, run first by `make sim`).

**Two MACs per DSP.** 16×16 is 256 multiplies; the Artix-7 has 240 DSP
slices. Two neighbouring PEs see the same activation, so one 25 × 18 DSP
multiply by the packed weight w0 + w1·2¹⁶ gives both products: a·w0 in the
low 16 bits, a·w1 above them plus the low lane's borrow. (Spacing 17 would
overflow the 25-bit port at w1 = −128, w0 < 0.) The sums stay in fabric: a
16-bit lane cannot hold a column's total.

| 16×16 array, alone, out of context, 100 MHz constraint | LUT | DSP | Fmax |
|---|---|---|---|
| Vivado's default: every MAC in LUT fabric | 28,545 (45%) | 0 | 104.6 MHz |
| One DSP per PE (synthesis only) | — | 256 of 240: does not fit | — |
| **Two MACs per DSP** ([report](docs/reports/summary_ooc_array16x16.txt)) | **7,681 (12%)** | **128** (53%) | **104.5 MHz** |

**Verification**, all against the golden model: one PE on all 65,536
(activation, weight) pairs; the DSP-packed pair on each lane's 65,536 with
the other lane at its extremes (the packing itself, for all 16.7 million
(a, w0, w1), in the model); the whole array at 4×4, 16×16 and 4×8 on 5,000
random GEMMs (multiples of the array and not), edge shapes and saturating
values, every element bit-exact and every row's latency exact. Planted bugs
in the skew, the deskew, the weight swap and the lane split are each caught.

## On the board

[![First light on the Arty A7-100T](docs/img/fpgafirstlight.jpg)](docs/img/fpgafirstlight.jpg)

**First light**: a C program compiled with GCC, printing over the UART and
counting on the LEDs.

**CoreMark**, 2000 iterations at 100 MHz, from the board's UART
([coremark_board.txt](docs/reports/coremark_board.txt)):

```
CoreMark on rv32i, 2000 iterations
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 2077692270
Total time (secs): 20
Iterations/Sec   : 100
Iterations       : 2000
Compiler version : GCC16.1.0
Compiler flags   : -O2 -march=rv32i -mabi=ilp32
Memory location  : STATIC
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0x4983
Correct operation validated. See README.md for run and reporting rules.
CoreMark/MHz: 0.962
```

RV32I has no multiply instruction, so every multiply and divide in CoreMark
is a software routine. Ticks are core cycles from the SoC's cycle counter.

**Live on the chip** (`make impl ILA=1`, `make gui VIEW=ila`): the pipeline
registers captured while CoreMark runs, triggered as `core_state_transition`
enters EX. Rows top to bottom: the pc in IF/ID, ID/EX, EX/MEM and MEM/WB, then
the instruction in ID/EX. Capture:
[`ila_coremark.csv`](docs/reports/ila_coremark.csv).

![ILA capture, samples 58-72](docs/img/vivado/phase-d/58-72.png)

| Sample | What the pipeline does |
|---|---|
| 61 | `jal` (`c55ff0ef`) into `core_state_transition` is in EX |
| 62–63 | Jump taken: IF/ID flushed (pc `0`), a NOP bubble (`00000013`) moves down |
| 64 | Trigger: the function's first instruction, `lw a5` at `21dc`, enters EX |
| 65–66 | Load-use stall: `lbu` needs `a5` from the load just ahead, and holds a cycle |
| 67–68 | And again: `beqz` needs the byte `lbu` loaded |
| 69–72 | One instruction per cycle |

![ILA capture, samples 129-143](docs/img/vivado/phase-d/129-143.png)

The return: `ret` (`00008067`) at sample 134 flushes, and sample 137 is back in
`core_bench_state` at `258c`, the instruction after the call. Samples 140–143
are the counterpart to the stall above: `lw a5`, an unrelated `lbu`, then
`addi a5` and `sw a5` use the results with no stall, because one instruction
sits between the load and its use and forwarding covers it. Over this
1024-cycle window, 881 instructions retire (IPC 0.86 here; CoreMark overall is
0.691).

## Interactive demos

https://github.com/user-attachments/assets/613c0f44-95a8-44bf-8c4c-f08adaeafa4e

*On the board, in PuTTY: the bootloader, then the six original demos from the menu (demo 7, fault injection, came later).*

The board boots a serial bootloader, so any program loads in a fraction of
a second without rebuilding the FPGA:

```
make apps
scripts/load.py sw/build/apps/demo.bin --term
```

A menu of seven demos ([`sw/demo/`](sw/demo/)), each interactive. Every one was
checked in simulation against an independent Python model before it ran on
the board. Board results, from
[`demo_board.txt`](docs/reports/demo_board.txt):

| Demo | What it shows | On the board at 100 MHz |
|---|---|---|
| **System info** | A RAM test, and the pipeline's costs **measured live** by timing blocks of instructions with the cycle counter | 1 cycle per ALU op; +1 per load used by the next instruction; 0 when one instruction sits between (forwarding); +2 per taken branch or jump; 0 for a branch not taken. Exactly as designed |
| **Mandelbrot** | Pan and zoom; the same frame in integer fixed point and in **software floating point** (no FPU) | 128 ms fixed point, 491 ms float: **3.8x**. Both pictures match a bit-exact model, IEEE single precision included |
| **Digits of π** | A spigot algorithm, streamed digit by digit; every step divides, in software | 750 digits in 4.95 s, all correct |
| **Game of Life** | Animated; pause, step, random or glider gun; the LEDs count generations | 81,581 cycles per generation |
| **Tower of Hanoi** | Animated, adjustable speed | 2ⁿ − 1 moves |
| **Prime sieve** | Up to 163,840, then tests any number you type | π(10⁵) = 9592; the full sieve in 16.0 ms |
| **TMR fault injection** | The sieve again and again until a key, a random bit of one copy's pc flipped 1,887 times a pass, the totals on screen and the LEDs (TMR build) | 133 passes: same 14,999 primes and 3,354,864 cycles every pass, all 250,971 flips detected ([`tmr_inject_board.txt`](docs/reports/tmr_inject_board.txt)) |

## In Vivado

A screenshot set per milestone, each kept in its own folder and taken from the
build whose reports are committed (`make gui`, `make gui VIEW=rtl`, with
`TMR=1` for the TMR core; `VIEW=array` and `VIEW=pair` for the systolic
array). Side by side, so the change shows:

- **Phase D, the single core** ([`phase-d/`](docs/img/vivado/phase-d/)): the CoreMark build of
  2026-10-17, 100 MHz, WNS +1.550 ns, before the UART receiver (+38 LUT,
  +37 FF) joined. [Whole-die floorplan](docs/img/vivado/phase-d/floorplan_board.svg).
- **Phase E, the TMR core** ([`phase-e/`](docs/img/vivado/phase-e/)): three copies and the voter,
  with the live injector, 2026-10-18, 100 MHz, WNS +0.095 ns. Its floorplan is
  the one at the top ([whole die](docs/img/vivado/phase-e/floorplan_board.svg)).

| Phase D — single core | Phase E — TMR |
|---|---|
| ![Device view, single core](docs/img/vivado/phase-d/device.png) Device view, coloured by module | ![Device view, TMR](docs/img/vivado/phase-e/device.png) Device view, coloured by copy: A orange, B green, C cyan, voter and mismatch counter magenta; RAM white, UART red. Still one clock region of eight |
| ![Device view zoomed, single core](docs/img/vivado/phase-d/device-zoom.png) Zoomed to single slices, with routing | ![Device view zoomed, TMR](docs/img/vivado/phase-e/device-zoom.png) Zoomed in where the voter sits: magenta voter cells placed between the copies, the worst path in yellow |
| ![Worst path on the device, single core](docs/img/vivado/phase-d/worstpathdevice.png) The worst setup path on the die | ![Worst path on the device, TMR](docs/img/vivado/phase-e/worstpathdevice.png) The worst path, from copy B's logic (green) into the voter (magenta) |
| ![Worst path schematic, single core](docs/img/vivado/phase-d/worstpath.png) Forwarding select → branch comparator (CARRY4 chain) → redirect → pc mux → block RAM address | ![Worst path schematic, TMR](docs/img/vivado/phase-e/worstpath.png) Copy B's forwarding select → its branch comparator → redirect → the **voter's mismatch detector** (a CARRY4 chain comparing the copies) → `mismatch_q`. TMR's slowest path is the error *detection*, not the vote |
| ![Timing summary, single core](docs/img/vivado/phase-d/timing.png) Timing: met at 100 MHz, WNS +1.550 ns, WHS +0.110 ns | ![Timing summary, TMR](docs/img/vivado/phase-e/timing.png) Timing: still met at 100 MHz, WNS +0.095 ns, WHS +0.119 ns |
| ![Utilization by hierarchy, single core](docs/img/vivado/phase-d/utilization-hierarchy.png) Utilization by module | ![Utilization by hierarchy, TMR](docs/img/vivado/phase-e/utilization-hierarchy.png) Three copies of equal size (893–894 slice LUTs, 472 registers each) and the voter (160): all three survived synthesis. Vivado counts physical slice LUTs here (3,172); the 3,446 elsewhere in this README are LUT cells, two of which can share one LUT |
| ![RTL schematic of the core](docs/img/vivado/phase-d/rtl-schematic-u_core.png) The core as elaborated RTL | ![RTL schematic of the TMR core](docs/img/vivado/phase-e/rtl-schematic-tmr.png) The TMR core as elaborated RTL: copy A (`u_core_a`), copies B and C (`g_other`), the voted feedback into each, the voter (`u_voter`) and the mismatch counter |
| ![RTL schematic of the ALU](docs/img/vivado/phase-d/rtl-schematic-alu.png) The ALU, opened up | ![RTL schematic of the voter](docs/img/vivado/phase-e/rtl-schematic-voter.png) The voter, opened up: a 2-of-3 majority (`a&b \| b&c \| a&c`) over each copy's 143-bit bundle, a compare flagging any disagreement, and one per copy saying which disagrees |
| ![Power estimate](docs/img/vivado/phase-d/power.png) Power: 0.26 W, Vivado's **vectorless estimate**, not a measurement; the MMCM is 65% of it | |

### Phase F, the systolic array

The 16×16 array on its own ([`phase-f/`](docs/img/vivado/phase-f/)): the
`make synth-array ARRAY=16x16` build of 2026-10-18, **out of context** (no
board, no core, no clock tree), so not comparable cell for cell with the
board builds above. 10 ns constraint, WNS +0.431 ns, 128 DSP48E1.

| Placed and routed | Inside a PE pair |
|---|---|
| ![Device view, array](docs/img/vivado/phase-f/device.png) Device view, coloured by array row (row 0 red … row 15 white; skew, deskew and `valid` grey). Vivado does not lay the rows out as a grid: they form ragged vertical strips around the DSP columns | ![RTL schematic of a PE pair](docs/img/vivado/phase-f/rtl-schematic-pair.png) One `systolic_pe_pair` as elaborated RTL: two columns' shadow weights, the activation in and out, two psums in and out |
| ![One DSP48E1 site](docs/img/vivado/phase-f/device-dsp.png) One DSP48E1 site (`DSP48_X2Y40`, row 15, pair 0) with the worst path (yellow) leaving its product output for the fabric | ![RTL datapath of a PE pair](docs/img/vivado/phase-f/rtl-schematic-pair-datapath.png) The datapath alone: the two INT8 weights packed into `w0 + w1·2^16`, **one multiply** by the shared activation, the lane split, two INT32 psum adders |
| ![One slice](docs/img/vivado/phase-f/device-slice.png) One slice (SLICEM) of the fabric around the DSPs: four LUTs, a CARRY4 and flip-flops, coloured by row | ![DSP register properties](docs/img/vivado/phase-f/dsp-properties.png) The DSP's registers. **AREG = 1**: the pair's packed-weight register went *into* the DSP's A input, so the stationary weight is stored inside the multiplier. BREG = 2 (on 125 of the 128): two registers from the activation's path absorbed too. MREG = PREG = 0: the product leaves unregistered (CREG/DREG are unused ports) |
| ![Worst path on the device, array](docs/img/vivado/phase-f/worstpathdevice.png) The worst setup path on the die | ![Worst path schematic, array](docs/img/vivado/phase-f/worstpath.png) The worst path: row 15, pair 0's DSP multiply → lane split and psum adder (CARRY4 chains; one LUT is row 14's psum coming down) → the output deskew shift register (Vivado folded the bottom psum register into an SRL16E) |
| ![Timing summary, array](docs/img/vivado/phase-f/timing.png) Timing: met at 100 MHz out of context, WNS +0.431 ns, WHS +0.097 ns | ![Utilization by hierarchy, array](docs/img/vivado/phase-f/utilization-hierarchy.png) 128 pairs (16 rows × 8), one DSP each. 7,645 physical slice LUTs here; the 7,681 elsewhere are LUT cells |

## As a chip (Sky130)

Run #1 of the ASIC flow: the bare core (one copy, no TMR) from RTL to GDSII
with [LibreLane](https://github.com/librelane/librelane) 3.0.16 on SkyWater's
open 130 nm PDK, `sky130_fd_sc_hd` cells (`make asic`,
[`syn/asic_config.yaml`](syn/asic_config.yaml)). It is hardened as a block:
the memory ports are the block's pins, the register file is 1,024
flip-flops, with no SRAM macros and no pads. Timing is signed off at 9
corners (slow, typical and fast silicon, each with minimum, nominal and
maximum wiring parasitics), and the worst of them, slow silicon at 100 °C
and 1.60 V, is the number quoted.

| | |
|---|---|
| [![The whole block in KLayout](docs/img/asic/run1/layout.png)](docs/img/asic/run1/layout.png) The whole block, 472 × 483 µm, in KLayout with the met4/met5 power grid hidden: standard cells under the lower metal layers of signal wiring, the memory-port pins along the edges | [![Single standard cells](docs/img/asic/run1/layout-zoom.png)](docs/img/asic/run1/layout-zoom.png) Zoomed in to single Sky130 standard cells, each labelled: flip-flops (`dfxtp`), multiplexers (`mux2`), clock buffers (`clkbuf`), with their local wiring and vias |

*Both screenshots are of the first 25 ns run; the final 35 ns layout has the
same die and floorplan.*

**Getting it to close.** At a 25 ns target the layout met timing at the
typical corner (58 MHz) but failed by 4.7 ns at the slow one, on the fetch
address leaving the block: forwarding select → branch compare → redirect →
pc mux → `imem_addr_o`, the same path that is critical on the FPGA. Two
things were in the way. The tool was buffering high-fanout nets with a clock
*delay* cell (`clkdlybuf4s25_1`, up to 2.4 ns per stage at the slow corner,
seven of them on the worst path); excluding it fixed that. What remained was
21.9 ns of real logic at the slow corner, against 19.75 ns allowed at 25 ns
once 20% of the cycle is reserved for the memory outside the block. At 35 ns,
with the delay cells excluded, timing is met at every corner. Each attempt is
a row in the ASIC table in [docs/PROGRESS.md](docs/PROGRESS.md).

## Results

Conditions travel with every number: an out-of-context Fmax models no clock
skew and is not the same quantity as a board-level one, so they are separate
rows. The per-slice trends (what each feature cost in LUTs and MHz) are in
[docs/PROGRESS.md](docs/PROGRESS.md).

**Stage 1 — CPU.** Part `xc7a100tcsg324-1`, Vivado 2025.2.

| Metric | Value | Report |
|---|---|---|
| Fmax, core alone, out-of-context, post-route (10.000 ns constraint) | 120.4 MHz | [summary_ooc.txt](docs/reports/summary_ooc.txt) |
| Fmax, on the board (core + RAM + I/O, in context, MMCM clock) | runs at **100 MHz**, WNS +0.955 ns, 110.6 MHz estimate | [summary_board.txt](docs/reports/summary_board.txt) |
| LUT / FF / BRAM / DSP, core alone, out-of-context | 966 / 467 / 0 / 0 | [summary_ooc.txt](docs/reports/summary_ooc.txt) |
| LUT / FF / BRAM / DSP, whole SoC on the board | 1123 / 435 / 8 / 0 | [summary_board.txt](docs/reports/summary_board.txt) |
| CoreMark/MHz, on the board, 100 MHz, 2000 iterations, validated | **0.962** (about 96 CoreMark); RV32I without M | [coremark_board.txt](docs/reports/coremark_board.txt) |
| IPC / CPI, CoreMark timed region, RTL simulation of the same SoC | 0.691 / 1.447 | [coremark_sim.txt](docs/reports/coremark_sim.txt) |
| Formal | riscv-formal 46/46 (BMC); pipeline properties by k-induction (k = 1 to 7), XT by BMC to depth 10 | [formal-properties.md](docs/formal-properties.md) |
| Bugs formal caught that simulation missed | 2 | [formal-properties.md](docs/formal-properties.md) |
| Functional coverage (UVM) | 205/205 bins, 100% | [coverage-plan.md](docs/coverage-plan.md) |
| TMR: faults injected / failures | 10,000 / **0**; 1,275 detected, all corrected and recovered | [tmr_faults.txt](docs/reports/tmr_faults.txt) |
| TMR: faults injected live on the board / effect | 250,971 pc flips over 133 sieves; all detected; answer and cycle count unchanged in every one | [tmr_inject_board.txt](docs/reports/tmr_inject_board.txt) |
| TMR: area overhead / Fmax penalty (board) | 3.1x LUT, 3.7x FF / −8.7% (still meets 100 MHz) | [summary_board_tmr.txt](docs/reports/summary_board_tmr.txt) |

**Stage 2 — SoC.** Phase F (the array, on its own) done.

| Metric | Value |
|---|---|
| GOPS (INT8) at achieved Fmax | — (Phase H, measured on the board) |
| **Measured** PE utilization | — (Phase H) |
| Speedup vs. software matmul | — (Phase H) |
| DSP slices used vs. LUT-fabric MACs, 16×16 array alone, out of context | 128 DSP + 7,681 LUT (two MACs per DSP) vs. 0 DSP + 28,545 LUT (all in fabric); 104.5 / 104.6 MHz ([summary_ooc_array16x16.txt](docs/reports/summary_ooc_array16x16.txt)) |
| AXI outstanding depth / measured throughput | — |
| SVA properties proven on AXI interfaces | — |

**ASIC flow (LibreLane + Sky130).** Two runs: the bare core closing Phase E, the full
SoC in Phase H. The delta between them is the result. Run 1: LibreLane 3.0.16,
sky130A `sky130_fd_sc_hd`, 35 ns constraint, inputs and outputs given 20% of
the period, worst of 9 signoff corners
([summary_asic.txt](docs/reports/summary_asic.txt),
[sta_asic.rpt](docs/reports/sta_asic.rpt)).

| Metric | Run 1 (bare core) | Run 2 (full SoC) |
|---|---|---|
| Die area, cell count, utilization | 227,997 µm² (472 × 483 µm); 13,853 cells, 1,496 of them flip-flops; 56.3% | — |
| Post-layout Fmax, worst corner | **31.7 MHz** including the I/O budget (35 ns met, +3.502 ns); 46.2 MHz register to register | — |
| Post-layout Fmax, typical corner | 50.6 MHz | — |
| Pre-layout estimate, synthesised netlist | 35.1 MHz including I/O; 46.0 MHz register to register | — |
| Power estimate (typical, 35 ns, vectorless) | 4.60 mW | — |
| DRC / LVS clean | **Clean**: Magic and KLayout DRC 0, LVS 0, antenna 0 | — |
| Scan chains: count, coverage, area overhead | — (Phase H) | — |

## Limitations

Stated plainly, because they are real:

- **RV32I only.** No multiply/divide (M), no floating point, no compressed
  instructions, no CSRs (the cycle counter is memory-mapped), no interrupts or
  privilege modes. Every exception halts the core rather than trapping to a
  handler. These are scope choices ([docs/buildplan.md](docs/buildplan.md) §7),
  and CoreMark is reported with that in mind.
- **32 KiB of memory**, code and data together, in block RAM. No caches and no
  DDR. Programs get 28 KiB after the bootloader.
- **The UART receiver buffers one byte.** Typing is fine; text pasted while a
  program is busy printing can lose characters.
- **Static not-taken branches**: every taken branch or jump costs two
  cycles. Branch prediction is deferred until after TMR, and then only with a
  measured IPC gain.
- **The out-of-context Fmax is optimistic**: it leaves the core's ports
  untimed. The board-level number is the one that counts, and it is the one
  quoted first.
- **Power is an estimate.** Vivado's vectorless analysis, not a measurement.
- **The ASIC run is the bare core, and slow.** 31.7 MHz worst case
  (50.6 MHz typical) against 100 MHz on the FPGA: a 130 nm process signed off
  at its slow corner, with a fifth of each cycle given to memories outside
  the block. A 25 ns target at the slow corner needs an RTL change on the
  fetch-address path. 3,091 max-slew violations remain (timing is signed off
  with them included). One copy, not TMR; the register file is flip-flops;
  power is a vectorless estimate.
- **TMR guards the core, not the memory.** The RAM, the I/O and the voter
  itself are single; protecting memory (ECC) is out of scope. Register-file
  faults in unused registers stay latent until rewritten (see Fault
  tolerance).

## Build and reproduce

Requires Verilator ≥ 5.036 and **cocotb ≥ 2.1.0** (2.0.1 segfaults reading a
port once a register-file-sized array exists), a venv at `~/cocotb-env`, the
RISC-V GNU toolchain, and OSS CAD Suite for formal. Vivado 2025.2 (free ML
Standard edition) for synthesis, UVM and the board:
[docs/vivado-setup.md](docs/vivado-setup.md). For `make asic`: Nix and
LibreLane 3.0.16, cloned to `~/librelane` (`LIBRELANE_DIR`), which fetches
the sky130 PDK. Vivado runs in batch from Tcl
scripts in `syn/`; no project directory is ever committed.

| Target | Does |
|---|---|
| `make lint` | Verilator lint of `rtl/`, zero warnings |
| `make sim` | The GEMM golden model's self-check, then the cocotb regression on Verilator, 320 tests |
| `make formal` | SymbiYosys properties and riscv-formal, checks and covers |
| `make uvm` | UVM regression in XSim (`SEED`, `PROGRAMS`, `COV_MIN`) |
| `make model-test` | The C golden model alone on rv32ui |
| `make synth` | Out-of-context synth **and** place & route of the core and of the TMR core, reports to `docs/reports/` |
| `make faults` | The TMR fault-injection campaign (10,000 trials) |
| `make gemm-model` | The systolic array's golden model, checked on its own |
| `make synth-array` | The systolic array alone, out of context, synth and place & route (`ARRAY=16x16`) |
| `make fw` / `make bench` | First-light firmware / CoreMark images |
| `make boot` / `make apps` | The serial bootloader (the default bitstream image) / programs and the demo reel for it |
| `scripts/load.py <bin> [--term]` | Send a program to the board and, with `--term`, talk to it |
| `make impl` | Board-level place & route and bitstream (`FW_IMAGE=`, `ILA=1`), reports to `docs/reports/` |
| `make prog` | Program the Arty (from WSL via usbipd, or prints the Windows steps) |
| `make ila` | Capture the pipeline registers from the running board and check them |
| `make gui` | Open the routed design in the Vivado GUI (`VIEW=rtl`: RTL schematic, `TMR=1` for the TMR core; `VIEW=ila`: live waveforms) |
| `make floorplan` | Draw the routed design as zoomable SVGs in `docs/img/` |
| `make asic` | LibreLane RTL-to-GDSII of the core on Sky130 (`syn/asic_config.yaml`), reports to `docs/reports/`; about 15 minutes |

`make synth` routes rather than stopping at synthesis: post-synthesis timing is
an estimate, post-route timing is measured. CI runs lint, simulation and
formal; Vivado is too large for a hosted runner, so synthesis runs locally and
its reports are committed with the RTL that produced them.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/core/` | The pipeline: `riscv_core`, decoder, ALU, branch unit, hazard unit, load/store alignment, register file |
| `rtl/tmr/` | The 2-of-3 voter and the triplicated core |
| `rtl/accel/` | The systolic array, its DSP-packed PE pairs, and the single-PE reference |
| `rtl/periph/` | UART transmitter and receiver |
| `rtl/bus/` | The AXI4 crossbar (`axi_xbar.sv`) and AXI4→Lite converter, the DMA engine (`dmaeng*.sv`: registers, descriptor sequencer, AXI4 master), the core's AXI4-Lite bridge and the DMA's port into RAM. The engine implements [DMA-Engine](https://github.com/RodeanAzari/DMA-Engine)'s device: its register package `rtl/dmaeng_pkg.sv`, generated from that repo's `spec/dmaeng.yaml`, is used straight from the submodule |
| `rtl/top/` | The SoC (`soc.sv`), its RAM, and the Arty A7 top (clocking, reset, pins, optional ILA) |
| `tb/cocotb/` | Python testbenches and the Python golden model |
| `tb/uvm/` | UVM environment (XSim), DPI-C bridge to the C model |
| `tb/formal/` | SymbiYosys jobs, harnesses, riscv-formal config (submodule) |
| `sw/model/` | C golden model (ISS); the systolic array's NumPy golden model; the DMA's Python model, a port of [DMA-Engine](https://github.com/RodeanAzari/DMA-Engine)'s QEMU device |
| `sw/boot/`, `sw/app/`, `sw/lib/` | The serial bootloader; startup and linker script for the programs it loads; their console library |
| `sw/demo/`, `sw/apps/` | The demo reel; small programs (`echo`, `dmatest`, the DMA self-test) |
| `sw/lib/dma.{h,c}` | Bare-metal DMA driver, on [DMA-Engine](https://github.com/RodeanAzari/DMA-Engine)'s generated header `include/dmaeng_regs.h` (from the submodule), the same header its Linux driver uses |
| `sw/firstlight/`, `sw/coremark-port/` | Bare-metal firmware and the CoreMark port (CoreMark itself is a submodule) |
| `sw/dma-engine/` | [DMA-Engine](https://github.com/RodeanAzari/DMA-Engine) (submodule): the DMA's register map and descriptor spec, its QEMU device model and recorded trace, the reference for Phase G |
| `sw/riscv-tests-env/` | Our environment for the official `riscv-tests` (the suite is a submodule, `sw/riscv-tests/`) |
| `syn/` | Vivado Tcl: OOC synth, board impl, ILA capture, GUI views, floorplan export; the LibreLane config |
| `constr/` | Arty A7 pin constraints |
| `scripts/` | Build automation, the ILA checker, the floorplan renderer, the ASIC report summary |
| `docs/` | Build plan, progress log, formal and coverage plans, committed reports, images |

## Roadmap

- **Stage 2 — the rest of the SoC.** A descriptor-based DMA and an AXI
  interconnect with formally proven interfaces (Phase G). The DMA's register
  map, descriptor format and golden trace come from my companion project,
  [DMA-Engine](https://github.com/RodeanAzari/DMA-Engine) (a Linux driver and
  QEMU device model for the same engine), pinned here as the submodule
  `sw/dma-engine/`; then the core
  driving the array on the board, with measured GOPS, PE utilisation and
  speedup over software matmul, scan insertion, and a second ASIC run of the
  whole SoC (Phase H).
- **After everything else: Doom.** Once Stage 2 ships, build what the SoC lacks
  to play Doom on the Arty: DDR3 with a cache, the game data from flash, a VGA
  framebuffer, and the M extension, measured in frames per second.
