Current state of the work — read this first:
@docs/PROGRESS.md

# CLAUDE.md — Project 1: RISC-V SoC with ML Accelerator

## What this is

A RISC-V RV32I SoC built in SystemVerilog, targeting the Digilent Arty A7-100T.

Built in two stages. **Stage 1 must be complete and running on hardware before Stage 2 begins.**

| Stage | Phases | Deliverable |
|---|---|---|
| **Stage 1 — CPU** | A–E | Formally verified, TMR'd, hardware-proven RV32I core, taken to GDSII once (§6.4 run #1) |
| **Stage 2 — SoC** | F–H | Core + systolic array accelerator + DMA + AXI interconnect |

This is a portfolio project. **Measured results matter as much as working RTL.** Every phase produces numbers that go in the README.


**I want to learn as we build. When something new is implemented or something is changed I want to know why and how. Teach me everything in depth and detail as we build. This includes testbenches, cocotb, vivado, synthesis, simulation, scripts, git, everything. I want to understand every inch of this project.** 

---

## Current status

<!-- Claude: update this table as phases complete. Do not mark a phase done until its
     definition-of-done checklist in §8 passes in full. -->

| Phase | Status | Key result |
|---|---|---|
| A — Working core | DONE (2026-10-08) | 40/40 RV32I; riscv-tests rv32ui 40/42 (2 excluded, reasons in PROGRESS.md); 104.5 MHz OOC, 1107 LUT / 501 FF |
| B — Formal verification | NOT STARTED | — |
| C — UVM environment | NOT STARTED | — |
| D — Hardware bring-up | NOT STARTED | — |
| E — TMR + fault injection | NOT STARTED | — |
| F — Systolic array | NOT STARTED | — |
| G — DMA + interconnect | NOT STARTED | — |
| H — Integration + DFT | NOT STARTED | — |

---

## 1. Hardware target

**Board:** Digilent Arty A7-100T
**Part:** `xc7a100tcsg324-1`

| Resource | Available | Notes |
|---|---|---|
| Logic cells | 101,440 | 63,400 LUTs, 126,800 FFs |
| **DSP48E1** | **240** | Binding constraint for Stage 2. See §6.1. |
| Block RAM | 4,860 Kb (~607 KB) | IMEM, DMEM, weight/activation tiles |
| DDR3L | 256 MB, 16-bit @ 667 MHz | Via MIG. Only needed if matrices exceed BRAM. |
| Clock | 100 MHz oscillator (pin E3) | 6× MMCM/PLL available |
| UART | USB-UART bridge | Console output |
| **Transceivers** | **NONE** | No SFP, no PCIe, no Aurora. Not relevant to this project. |

Use Digilent's master XDC as the constraints starting point. Uncomment only the pins in use.

**Free Vivado ML Standard fully supports this part.** No licence needed.

---

## 2. Toolchain

| Tool | Use |
|---|---|
| Vivado ML Standard | Synthesis, implementation, bitstream, XSim (UVM) |
| Verilator | Fast simulation, linting, CI |
| cocotb | Python testbenches — primary sim environment from Phase A |
| SymbiYosys + Yosys | Formal property verification |
| riscv-formal | ISA compliance proofs |
| RISC-V GNU toolchain | `riscv32-unknown-elf-gcc`, compiling test programs |
| GTKWave / Surfer | Waveform viewing |
| LibreLane + Sky130 | RTL-to-GDSII flow. **In scope for this project** — run once closing Phase E, again in Phase H. See §6.4. |

### Required Makefile targets

Every one of these must exist from a clean checkout and must never be GUI-only. A
target whose phase has not arrived yet exists as a stub that prints which phase it
belongs to and what it is waiting on — a clean checkout gets a reason, not `No rule
to make target`.

```
make lint          # verilator --lint-only -Wall, zero warnings        [live]
make sim           # full regression (Verilator + cocotb)              [live]
make synth         # OOC synth AND place & route of the core alone,    [live]
                   #   emits utilization + timing to docs/reports/
make formal        # SymbiYosys, all properties                        [Phase B]
make uvm           # UVM regression in XSim                            [Phase C]
make impl          # board-level place & route, emits bitstream        [Phase D]
make prog          # program the board                                 [Phase D]
make asic          # LibreLane RTL-to-GDSII, area/timing/power (§6.4)   [Phase E, H]
make clean
```

**Why `synth` routes rather than stopping at synthesis:** post-synthesis timing is
an estimate — Vivado is guessing routing delay. Post-route timing is measured. For a
design this size the extra minute is free, and reporting an estimate as a measurement
is the thing §10 exists to prevent. `impl` is the separate board-level flow that
produces a bitstream, and it needs a top and pin constraints that `synth` does not.

Vivado runs in **batch mode via Tcl scripts** in `syn/`. Never commit a Vivado project directory.

---

## 3. Repository layout

```
├── README.md              # architecture diagram + MEASURED results
├── rtl/                   # synthesizable SystemVerilog ONLY
│   ├── core/              # pipeline stages, regfile, ALU, hazard unit
│   ├── tmr/               # triplicated wrapper + voter
│   ├── accel/             # systolic array (Stage 2)
│   ├── bus/               # AXI interconnect, DMA (Stage 2)
│   └── periph/            # UART, timer
├── tb/
│   ├── uvm/               # SystemVerilog UVM environment
│   ├── cocotb/            # Python testbenches
│   └── formal/            # SVA property files, SymbiYosys configs
├── sw/
│   ├── tests/             # C and assembly test programs
│   └── model/             # Python/C++ golden reference models
├── sim/                   # simulation scripts, waveform configs
├── syn/                   # Vivado Tcl scripts
├── constr/                # XDC files
├── docs/                  # design docs, coverage plans, committed reports
├── scripts/               # automation
├── Makefile
└── .github/workflows/     # CI
```

**`rtl/` contains synthesizable code only.** No `$display`, no `initial` blocks other than BRAM init, no delays. Testbench code lives in `tb/`.

**This is the target layout, not a scaffold to create up front.** A directory appears
when it has a file to hold; empty placeholder directories are speculative structure.
Every build script walks `rtl/` **recursively** and errors if it matches nothing, so a
new subdirectory needs no build change — and a file in a directory the tools cannot
find fails loudly instead of being silently dropped from lint, simulation and synthesis.

---

## 4. Coding standards

### SystemVerilog rules

- `always_ff @(posedge clk)` for sequential, `always_comb` for combinational. Never bare `always`.
- Non-blocking `<=` in sequential, blocking `=` in combinational. Never mix within a block.
- **Synchronous, active-high reset** (`rst`). Xilinx FPGAs prefer this over async.
- Every `always_comb` must assign every output on every path. No inferred latches — `make lint` must be clean.
- Parameterize widths. No magic numbers in RTL.
- One module per file, filename matches module name.
- `logic` everywhere. Never `reg`/`wire` in new code.
- Explicit port directions, named port connections on instantiation. No positional connections.
- Suffix conventions: `_i` input, `_o` output, `_n` active-low, `_q` registered, `_d` next-state.

### Yosys compatibility constraint

Formal verification runs through Yosys, whose SystemVerilog support is narrower than Vivado's.

**Keep `rtl/core/` within the Yosys-supported synthesizable subset.** Avoid: complex `interface` constructs, advanced `struct`/`union` in module ports, `unique`/`priority` outside simple cases. If a construct is needed for readability, verify `make formal` still elaborates before committing. `sv2v` is a fallback, not a first choice.

Testbench code (`tb/uvm/`) has no such constraint.

### CI

**On GitHub-hosted runners, every push:**
1. `make lint` — zero warnings
2. `make sim` — full regression
3. `make formal` — all properties (joins CI in Phase B)

**Not in hosted CI: `make synth`.** Vivado is a ~54 GB install with no headless-friendly
free distribution; it does not fit a hosted runner. This is a deliberate exclusion, not
an oversight. Synthesis runs locally and its **reports are committed** to `docs/reports/`
in the same commit as the RTL that produced them, which is what makes the numbers
auditable without a runner. A self-hosted runner is the honest upgrade path if that ever
stops being enough.

The distinction is cost, not principle: yosys and SymbiYosys install in a couple of
minutes, so formal verification belongs in hosted CI from the day it has properties to
prove. Vivado does not.

**A commit that breaks CI gets fixed before anything else.**

### Commits

Small, frequent, meaningful messages. This repo's commit history is itself portfolio evidence — 200 commits over six months tells a truthful story, three commits titled "final" tells a different one.

---

## 5. Stage 1 specification

### 5.1 ISA

**RV32I base integer set**, 40 instructions:
- `LUI` `AUIPC` `JAL` `JALR`
- `BEQ` `BNE` `BLT` `BGE` `BLTU` `BGEU`
- `LB` `LH` `LW` `LBU` `LHU`
- `SB` `SH` `SW`
- `ADDI` `SLTI` `SLTIU` `XORI` `ORI` `ANDI` `SLLI` `SRLI` `SRAI`
- `ADD` `SUB` `SLL` `SLT` `SLTU` `XOR` `SRL` `SRA` `OR` `AND`
- `FENCE` `ECALL` `EBREAK`

**Out of scope:** M/A/F/D/C extensions, CSRs beyond a basic timer, MMU, privilege modes, interrupts.

### 5.2 Pipeline

Classic 5-stage in-order:

| Stage | Function |
|---|---|
| **IF** | PC update, instruction fetch from BRAM |
| **ID** | Decode, regfile read, immediate generation, hazard detection |
| **EX** | ALU, branch resolution, forwarding muxes |
| **MEM** | Data memory access, load/store alignment |
| **WB** | Regfile writeback |

**Branch resolution in EX.** Static not-taken prediction; flush IF/ID and ID/EX on taken.

### 5.3 Forwarding and hazards

Required paths:
- **EX→EX** (ALU result to next instruction's operand)
- **MEM→EX**
- **WB→ID** (regfile internal forwarding — write-first behaviour)

**Load-use hazard requires a one-cycle stall.** Forwarding cannot fix it because the load result isn't available until MEM. This is the single most commonly botched case — write directed tests for it before trusting random stimulus.

`x0` must always read zero regardless of writes.

### 5.4 RVFI interface (required for Phase B)

The core **must expose a RISC-V Formal Interface (RVFI) port** for `riscv-formal`. Design this in from Phase A — retrofitting it is painful.

Minimum signals: `rvfi_valid`, `rvfi_order`, `rvfi_insn`, `rvfi_trap`, `rvfi_halt`, `rvfi_intr`, `rvfi_rs1_addr`, `rvfi_rs2_addr`, `rvfi_rs1_rdata`, `rvfi_rs2_rdata`, `rvfi_rd_addr`, `rvfi_rd_wdata`, `rvfi_pc_rdata`, `rvfi_pc_wdata`, `rvfi_mem_addr`, `rvfi_mem_rmask`, `rvfi_mem_wmask`, `rvfi_mem_rdata`, `rvfi_mem_wdata`.

Emitted at the WB stage, one retirement per `rvfi_valid`.

### 5.5 Formal properties (Phase B)

Beyond riscv-formal's ISA compliance, hand-write SVA for:

- **Forwarding correctness** — forwarded value equals the architectural value the instruction should have read
- **No structural hazard** on regfile read/write ports
- **Branch flush correctness** — no wrong-path instruction ever reaches WB
- **Pipeline register validity** — no X propagation into committed architectural state
- **`x0` invariance** — reads as zero always
- **Stall correctness** — a stalled stage holds its value; no instruction is lost or duplicated

Run bounded model checking **and induction**. Check every property for **reachability** — a property that passes vacuously proves nothing. Record proof depth.

**Log every bug formal catches that simulation missed.** This is the highest-value artifact of the phase.

### 5.6 UVM environment (Phase C)

- Driver, monitor, scoreboard, coverage collector
- Golden ISA reference model (C++ or Python) via **DPI-C**
- Per-instruction architectural state comparison against the model
- Constrained-random instruction stream generation

**Functional coverage plan** (write it in `docs/` first, then close against it):
- All 40 instructions
- All forwarding paths, individually and in combination
- Load-use stall
- Branch taken / not-taken for each branch type
- Corner immediates (0, max positive, max negative, sign-extension boundaries)
- Back-to-back dependent instructions
- Memory alignment cases for each load/store width

**Target: ≥95% functional coverage.**

### 5.7 TMR (Phase E)

```
   ┌──────────────┐
──▶│  Core Copy A │──┐
   └──────────────┘  │
   ┌──────────────┐  │   ┌─────────────┐
──▶│  Core Copy B │──┼──▶│    VOTER    │──▶ output
   └──────────────┘  │   │  (2-of-3)   │
   ┌──────────────┐  │   └──────┬──────┘
──▶│  Core Copy C │──┘          │
   └──────────────┘             ▼
                          mismatch counter
```

- Vote on **architectural state**: regfile writes, PC, memory writes
- Expose a **mismatch counter** readable at runtime
- **Fault-injection harness** (testbench only, not synthesizable): flip random bits in regfile/pipeline registers at randomized cycles
- **Formally verify the voter**: any two agreeing inputs produce that output

Measure: fault detection rate, recovery rate, area overhead vs. baseline, Fmax penalty.

⚠ **Use `DONT_TOUCH` / `KEEP_HIERARCHY` on the three copies.** Vivado will otherwise merge identical logic and silently defeat the redundancy. Verify in the synthesis report that three copies actually exist.

---

## 6. Stage 2 specification

```
   ┌──────────────────┐        ┌──────────────────────────┐
   │  RISC-V CORE     │        │  SYSTOLIC ARRAY          │
   │  (Stage 1)       │        │  16×16 PE, INT8→INT32    │
   │  control code    │        │  weight-stationary       │
   └────────┬─────────┘        └────────────┬─────────────┘
            │ AXI4-Lite master              │ AXI4-Lite slave (ctrl)
            │                               │ AXI4 master (data)
   ┌────────▼───────────────────────────────▼─────────────┐
   │           AXI4 / AXI4-Lite INTERCONNECT              │
   │   round-robin arbiter · address decode · outstanding │
   └──────┬─────────────────┬─────────────────┬───────────┘
          │                 │                 │
   ┌──────▼──────┐  ┌───────▼──────┐  ┌───────▼────────┐
   │ DMA ENGINE  │  │ BRAM weights │  │ BRAM activations│
   │ descriptor  │  │  + scratchpad│  │  + results      │
   │ scatter-gath│  │              │  │                 │
   └─────────────┘  └──────────────┘  └─────────────────┘
```

### 6.1 Systolic array

**Weight-stationary**, 16×16 PE grid.

```
   weights preloaded into PEs and held
   activations stream left→right, partial sums flow top→bottom

   Each PE:  acc_out = acc_in + (w_stationary × a_in)
             a_out   = a_in   (registered, passes right)
```

| Parameter | Value | Rationale |
|---|---|---|
| Array size | 16×16 = 256 MACs | Parameterize it. 8×8 is the fallback. |
| Input precision | INT8 signed | — |
| Accumulator | INT32 | 16 terms × (±128)² ≈ 2^18; INT32 gives ample headroom |
| Dataflow | Weight-stationary | Simplest; good for GEMM with weight reuse |

**DSP budget.** 256 MACs vs. 240 DSP48E1. Two INT8 multiplies can be packed into one DSP48E1 by placing two 8-bit operands in the 25-bit A port with sufficient guard bits (see Xilinx WP487 — written for DSP48E2, adapt for the 25×18 DSP48E1).

**Verify packing empirically.** Check the synthesis report for actual DSP count. If Vivado maps MACs to LUT fabric instead, either restructure the code or instantiate `DSP48E1` explicitly. **If packing doesn't work out, drop to 8×8 rather than fighting it** — a working 8×8 with honest numbers beats a broken 16×16.

**Data feeding is the real problem.** A 16×16 array consumes 16 activations per cycle. Document BRAM banking and how the array stays fed. **Report measured PE utilization, not peak theoretical GOPS.** An honest 40% with an explanation is a better answer than a peak figure that can't be defended.

Also specify: edge handling for matrices not a multiple of 16 (zero-pad vs. partial-tile control), and output requantization (scale, saturation, rounding mode).

### 6.2 AXI interconnect

- **AXI4-Lite** for control registers (core → accelerator, core → DMA)
- **AXI4** for data movement
- Round-robin arbitration, address decode, outstanding-transaction tracking

**SVA protocol assertions required:**
- `VALID` must not deassert before `READY` (handshake stability)
- Address/data stable while `VALID` high and `READY` low
- No `READY`/`VALID` combinational dependency loop (deadlock freedom)
- Outstanding transaction count never exceeds the configured limit
- Write response follows write data

### 6.3 DMA engine

Descriptor-based with scatter-gather. Descriptor in memory: source address, destination address, length, next-descriptor pointer, control/status flags.

> **Design note:** this DMA is reused later for a PCIe host bridge. **Separate the descriptor/scatter-gather logic from the transport layer** so only the transport changes. Do not entangle AXI specifics into the descriptor engine.

### 6.4 ASIC flow (LibreLane + Sky130)

Not a separate project — it runs on this repo's RTL and its results belong in this README.

**LibreLane, not OpenLane.** LibreLane is the FOSSi Foundation's continuation of
Efabless's OpenLane 2; after Efabless wound down, OpenLane 2 went quiet and the original
OpenLane became the legacy flow. Same underlying tools (Yosys, OpenROAD, Magic, Netgen,
KLayout), same Sky130 PDK, same steps below. Older docs and tutorials say "OpenLane" —
read them as background, not as install or config instructions.

**This section spans both stages.** It sits in §6 to keep the ASIC story in one place,
but run #1 is a **Phase E deliverable and therefore part of Stage 1** — it is a checkbox
in Phase E's definition of done, so Stage 1 is not complete until it has been done.

**Run it twice:**

| Run | When | Input |
|---|---|---|
| **1** | Closing Phase E | Stage 1 bare core, non-TMR variant (smaller, simpler) |
| **2** | During Phase H | Full Stage 2 SoC with accelerator, DMA, AXI |

The **comparison between the two runs** is the interesting result — how area, congestion, and timing closure change when an accelerator and a bus fabric are added. That feedback loop (physical results informing RTL decisions) is more valuable than either run alone.

**Flow steps:**
1. Synthesis (Yosys)
2. **Scan chain insertion** (§6.5)
3. Floorplanning
4. Placement
5. Clock tree synthesis
6. Routing
7. STA signoff
8. DRC / LVS clean
9. GDSII output

**Report per run:** die area (µm²), cell count, utilization %, post-layout Fmax vs. pre-synthesis estimate, power estimate, DRC/LVS clean confirmation, layout screenshot.

Also write a short FPGA-vs-ASIC comparison for the same RTL — the two targets have very different cost models and saying why is a good interview answer.

### 6.5 Scan chain insertion (DFT)

Small addition during Phase H — budget 2–3 days.

**Achievable with free tools:**
- Scan chain insertion via Yosys/LibreLane — convert flops to scan flops, stitch chains.
  **Unverified:** whether LibreLane has a built-in scan-insertion step. Check before
  budgeting Phase H around it.
- Scan shift verification in simulation
- Report chain count, chain length, test coverage, area and timing overhead vs. non-scan

**Not achievable — do not attempt:** MBIST generation, commercial ATPG (Tessent, TetraMAX), SSN, boundary scan insertion. All require licensed tools.

**Framing:** "inserted and verified scan chains in an open-source ASIC flow, with coverage and area overhead reported" is truthful. It is not production DFT experience — don't claim it is.

---

## 7. Out of scope — do not build these

Hard boundaries. If a task seems to require one of these, stop and flag it rather than expanding scope.

**Stage 1:**
- Out-of-order execution / Tomasulo *(architecturally incoherent with TMR — rad-hard designs are deliberately simple, in-order, deterministic)*
- Superscalar issue
- Cache hierarchy beyond simple BRAM IMEM/DMEM
- MMU, privilege modes, interrupt controller
- Branch prediction *(optional extension only after Phase E ships, and then only with measured IPC deltas)*

**Stage 2:**
- Full mesh NoC *(the AXI interconnect is the interconnect story — say "AXI interconnect," never "NoC")*
- Training hardware, backward passes, ML framework integration
- BF16 *(only if Phases F–H finish early, and only after INT8 is complete and measured on hardware)*

---

## 8. Phase definitions of done

A phase is done when **every** box is checked. No partial credit.

### Phase A — Working core
- [x] All 40 RV32I instructions implemented
- [x] All forwarding paths working; load-use stall correct
- [x] RVFI port exposed and populated
- [x] Official `riscv-tests` RV32I suite passes
- [x] `make lint` clean, `make sim` passes in CI

### Phase B — Formal verification
- [ ] `riscv-formal` ISA compliance passing
- [ ] All §5.5 hand-written properties written and proven
- [ ] Induction runs, not just BMC
- [ ] Reachability checked for every property (no vacuous passes)
- [ ] `docs/formal-properties.md` lists every property, proof depth, and result
- [ ] Bugs formal found that simulation missed are logged

### Phase C — UVM environment
- [ ] Driver, monitor, scoreboard, coverage collector implemented
- [ ] DPI-C golden model comparing per-instruction architectural state
- [ ] Constrained-random instruction generation
- [ ] `docs/coverage-plan.md` written
- [ ] ≥95% functional coverage achieved

### Phase D — Hardware bring-up
- [ ] Synthesizes and meets timing; Fmax documented
- [ ] UART peripheral working
- [ ] Compiled C program boots and prints over UART
- [ ] Dhrystone or CoreMark runs; IPC measured
- [ ] ILA probes on pipeline registers
- [ ] Timing + utilization reports committed to `docs/`
- [ ] Photo/video of the board running

### Phase E — TMR + fault injection
- [ ] Three copies + voter; `DONT_TOUCH` verified in synthesis report
- [ ] Fault-injection harness with randomized bit flips
- [ ] Voter formally verified
- [ ] Fault detection rate, recovery rate measured over a documented campaign size
- [ ] Area overhead and Fmax penalty vs. baseline recorded
- [ ] **LibreLane run #1** on the non-TMR core: area, post-layout Fmax, power, DRC/LVS clean, layout screenshot (§6.4)

**→ Stage 1 complete. Update README with all results before starting Phase F.**

### Phase F — Systolic array
- [ ] Single PE verified exhaustively
- [ ] Python/NumPy GEMM golden model written **before** the RTL
- [ ] 4×4 working, then parameterized to 16×16 (or 8×8 if DSP packing fails)
- [ ] Bit-exact match against golden model across thousands of random matrices
- [ ] Edge cases: non-multiple-of-16 matrices, saturation boundaries
- [ ] Synthesis report confirms expected DSP usage

### Phase G — DMA + interconnect
- [ ] AXI4-Lite control interface
- [ ] AXI4 data interface
- [ ] Descriptor-based DMA with scatter-gather
- [ ] Interconnect with round-robin arbitration and address decode
- [ ] All §6.2 SVA assertions written and passing
- [ ] Software on the core configures and launches an accelerator job

### Phase H — Integration + DFT
- [ ] End-to-end on hardware: C program loads weights via DMA, launches GEMM, reads results
- [ ] Benchmarked against software matmul on the same core, several matrix sizes
- [ ] Measured PE utilization reported
- [ ] Scan chain insertion; chain count, coverage, area overhead reported (§6.5)
- [ ] **LibreLane run #2** on the full SoC (§6.4)
- [ ] Written comparison of run #1 vs. run #2 — how area, congestion, and timing changed

---

## 9. Known failure modes

Check these first when debugging.

**Stage 1**
- **Load-use hazard** — the most commonly botched case. Directed tests before random.
- **Forwarding to the wrong operand** when rs1 and rs2 both match the same destination register.
- **Branch flush off by one stage** — a wrong-path instruction reaches WB.
- **X propagation** from uninitialized BRAM masking real bugs in simulation.
- **Vacuous formal proofs** — properties that pass because they're never reachable.
- **Vivado merging TMR copies** — always verify three copies survive synthesis.

**Stage 2**
- **Building the array before the golden model** — you cannot distinguish a dataflow bug from an indexing bug without a reference.
- **Underestimating the feeding problem** — if memory can't supply 16 activations/cycle, utilization collapses and GOPS figures become fiction.
- **DSP inference failure** — Vivado silently mapping MACs to LUTs. Check the synthesis report.
- **AXI handshake deadlock** — ready/valid dependency loops. Write the assertions before debugging on hardware.
- **Accumulator overflow unnoticed** because random test matrices have small values. Include adversarial saturation cases.

---

## 10. Metrics to record in README

The README is the deliverable. It must contain an architecture diagram and a results table with real numbers.

### Measurement discipline

These three rules govern every number in this repo. They are not style preferences — each one exists because breaking it is how an honest project starts telling lies about itself.

**Measure every increment, not just the finished thing.** Re-run the synthesis flow after each RTL slice lands and append a row to the trend table in `docs/PROGRESS.md`: date, slice, LUT/FF/CARRY, WNS, Fmax. One number at the end of the project is a claim. A table showing what each pipeline stage cost in MHz and LUTs is evidence of engineering rather than hoping — and it is a far better interview answer than a single figure, because it means you can say *why* the number is what it is. It also localises regressions: if Fmax halves, the row tells you which change did it, instead of bisecting months of commits at the end.

**Numbers come from generated files, never from typing.** The tool's own reports are the primary source and get committed (`docs/reports/`, regenerated in the same commit as the RTL that produced them, so a report always matches the code beside it in history). Tables in `README.md` and `docs/PROGRESS.md` are transcribed from those files, not from terminal scrollback or memory.

**Every number carries its measurement conditions.** Part, clock constraint, and whether it is out-of-context or board-level. An out-of-context Fmax has no clock skew modelled and is not the same quantity as a post-implementation board number — mixing the two in one table is how the lying starts. Different conditions, different table. The same rule separates FPGA numbers from the §6.4 ASIC numbers: different targets, different tables.

**Stage 1**
- Fmax (MHz) on Artix-7
- Utilization: LUTs, FFs, BRAM, DSP, and % of device
- CPI / IPC on Dhrystone and CoreMark
- Formal: properties proven, proof depth, bugs found that simulation missed
- Functional coverage %
- TMR: fault detection rate, recovery rate, area overhead %, Fmax penalty

**Stage 2**
- GOPS (INT8) at achieved Fmax
- **Measured** PE utilization % (not peak theoretical)
- Speedup vs. software matmul, across several matrix sizes
- DSP slices used vs. LUT-fabric MACs
- AXI: outstanding depth, measured throughput
- SVA properties proven on AXI interfaces
- LibreLane **both runs**: die area, post-layout Fmax, power — and the delta between bare core and full SoC
- Scan chain count, coverage %, area overhead

**Also in the README:** architecture diagram (image, not ASCII), hardware photo or ILA capture, and build/run instructions.

---

## 11. Working principles

- **Golden model before RTL.** Every time. Applies to the ISA model in Phase C and the GEMM model in Phase F.
- **Measure, don't assert.** "High performance" means nothing. Numbers mean something.
- **Hardware over simulation.** A design proven on the board is worth far more than one that only ever ran in a testbench.
- **Parameterize by default.** Widths, array sizes, field sizes.
- **Ship Stage 1 before starting Stage 2.** A finished CPU is a strong portfolio piece. A half-built SoC bolted onto an unfinished core is worth less than either.
- **State limitations plainly.** In the README and in conversation. Accurate framing of a real constraint beats a vague claim that collapses under questioning.