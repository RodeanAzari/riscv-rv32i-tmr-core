Current state of the work — read this first:
@docs/PROGRESS.md

## Project 1: RISC-V SoC with ML Accelerator

## What this is

A RISC-V RV32I SoC built in SystemVerilog, targeting the Digilent Arty A7-100T.

Built in two stages. **Stage 1 must be complete and running on hardware before Stage 2 begins.**

| Stage | Phases | Deliverable |
|---|---|---|
| **Stage 1 — CPU** | A–E | Formally verified, TMR'd, hardware-proven RV32I core, taken to GDSII once (§6.4 run #1) |
| **Stage 2 — SoC** | F–H | Core + systolic array accelerator + DMA + AXI interconnect |

This is a portfolio project. **Measured results matter as much as working RTL.** Every phase produces numbers that go in the README.

---

## Current status

<!-- Claude: update this table as phases complete. Do not mark a phase done until its
     definition-of-done checklist in §8 passes in full. -->

| Phase | Status | Key result |
|---|---|---|
| A — Working core | DONE (2026-10-08) | 40/40 RV32I; riscv-tests rv32ui 40/42 (2 excluded, reasons in PROGRESS.md); 104.5 MHz OOC, 1107 LUT / 501 FF |
| B — Formal verification | DONE (2026-10-17) | riscv-formal 46/46 (37 insn + reg/pc/unique/causal/liveness/hang/ill, BMC), each reached or shown to fail; all §5.5 properties (x0, stall, forwarding, branch flush, structural hazard, X propagation) by k-induction, plus a bounded X check with an undefined regfile; 2 bugs found that simulation missed |
| C — UVM environment | DONE (2026-10-17) | XSim UVM + DPI-C C golden model; 205/205 functional coverage bins (100%), ~45k retirements/run checked, 0 mismatches; 3 planted RTL faults caught |
| D — Hardware bring-up | DONE (2026-10-18) | On the board at 100 MHz (WNS +0.948 ns, Fmax estimate 110.5 MHz); CoreMark 0.962/MHz (about 96 at 100 MHz), IPC 0.691; UART both ways, a serial bootloader and six interactive demos (video in the README); ILA on the pipeline registers |
| E — TMR + fault injection | DONE (2026-10-18) | Three voted copies with feedback (three survive synthesis); voter formally proven; 10,000 single-bit faults, 0 failures, all detected faults corrected and recovered; 100 MHz on the board, 3.1x LUT, Fmax −8.7%; live injector on the board: 250,971 pc flips over 133 runs, same answer, same cycles; LibreLane run #1 (Sky130): DRC/LVS clean, timing met at all 9 corners at 35 ns, 31.7 MHz worst case, 119,277 µm² of cells |
| F — Systolic array | DONE (2026-10-18) | 16×16 INT8 weight-stationary, two MACs per DSP48E1: 128 DSP, 7,681 LUT, 104.5 MHz OOC; NumPy golden model first; bit-exact on 5,000 GEMMs at 4×4/16×16/4×8, PE and packed pair exhaustive. Not yet joined to the core (H) |
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
make formal        # SymbiYosys + riscv-formal, all properties         [live]
make uvm           # UVM regression in XSim                            [Phase C]
make impl          # board-level place & route, emits bitstream        [Phase D]
make prog          # program the board                                 [Phase D]
make asic          # LibreLane RTL-to-GDSII, area/timing/power (§6.4)   [Phase E, H]
make clean
```

**`synth` routes, not just synthesizes:** post-synthesis timing is an estimate, post-route is measured. `impl` is the separate board-level flow that produces a bitstream.

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

**Not in hosted CI: `make synth`.** Vivado (~54 GB) does not fit a hosted runner. Synthesis runs locally and its **reports are committed** to `docs/reports/` in the same commit as the RTL that produced them. A self-hosted runner is the upgrade path.

**A commit that breaks CI gets fixed before anything else.**

### Commits

Small, frequent, meaningful messages; the history is portfolio evidence (no commits titled "final").

---

## 5-8. Spec, scope and phase checklists → `docs/buildplan.md`

The full spec lives in [docs/buildplan.md](docs/buildplan.md) under the **same
section numbers**: §5 Stage 1 (ISA, pipeline, forwarding, RVFI, formal
properties, UVM, TMR), §6 Stage 2 (systolic array, AXI, DMA, LibreLane, scan),
§7 out of scope, §8 phase definitions of done. Read the relevant section when
starting a phase. Rules that apply to every session:

- **ISA:** RV32I base, 40 instructions. No A/F/D/C (M only after Phase G, see
  buildplan Phase H), CSRs beyond a basic timer,
  MMU, privilege modes or interrupts. 5-stage in-order pipeline, branches
  resolved in EX, static not-taken, load-use stall of one cycle, `x0` always 0.
- **Out of scope, flag rather than build:** out-of-order, superscalar, caches
  beyond BRAM, MMU/interrupts, branch prediction (only after Phase E, with
  measured IPC), full mesh NoC (say "AXI interconnect"), training hardware, BF16.
- **Formal (§5.5):** run BMC **and induction**; check every property for
  **reachability** (a vacuous pass proves nothing); record proof depth; log every
  bug formal caught that simulation missed.
- **TMR (§5.7):** `DONT_TOUCH` / `KEEP_HIERARCHY` on the three copies, and verify
  in the synthesis report that three copies survive.
- **Phase is done only when every box in its §8 checklist is checked.** Ship
  Stage 1 before starting Stage 2. LibreLane run #1 is part of Phase E.

---

## 9. Known failure modes (Stage 1; Stage 2 in docs/buildplan.md)

Check these first when debugging.

- **Load-use hazard** — the most commonly botched case. Directed tests before random.
- **Forwarding to the wrong operand** when rs1 and rs2 both match the same destination register.
- **Branch flush off by one stage** — a wrong-path instruction reaches WB.
- **X propagation** from uninitialized BRAM masking real bugs in simulation.
- **Vacuous formal proofs** — properties that pass because they're never reachable.
- **Vivado merging TMR copies** — always verify three copies survive synthesis.

---

## 10. Measurement discipline

What to record per stage is in `docs/buildplan.md` §10.

These three rules govern every number in this repo:

- **Measure every increment.** After each RTL slice, run `make synth` and append a row to the trend table in `docs/PROGRESS.md` (date, slice, LUT/FF/CARRY, WNS, Fmax). A table of what each stage cost localises regressions; one final number is a claim.
- **Numbers come from generated files, never from typing.** Reports are committed in `docs/reports/` in the same commit as the RTL that produced them; tables in `README.md` and `docs/PROGRESS.md` are transcribed from them, not from scrollback or memory.
- **Every number carries its measurement conditions** (part, clock constraint, out-of-context or board-level). Different conditions, different table. FPGA and §6.4 ASIC numbers never share a table.

---

## 11. Working principles

- **Golden model before RTL.** Every time. Applies to the ISA model in Phase C and the GEMM model in Phase F.
- **Measure, don't assert.** "High performance" means nothing. Numbers mean something.
- **Hardware over simulation.** A design proven on the board is worth far more than one that only ever ran in a testbench.
- **Parameterize by default.** Widths, array sizes, field sizes.
- **Ship Stage 1 before starting Stage 2.** A finished CPU is a strong portfolio piece. A half-built SoC bolted onto an unfinished core is worth less than either.
- **State limitations plainly.** In the README and in conversation. Accurate framing of a real constraint beats a vague claim that collapses under questioning.