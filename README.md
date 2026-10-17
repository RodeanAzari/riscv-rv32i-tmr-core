# RISC-V RV32I SoC — Formally Verified, Fault-Tolerant, with an ML Accelerator

An in-order 5-stage RV32I core in SystemVerilog targeting the Digilent Arty A7-100T,
built in two stages: a formally verified, TMR'd, hardware-proven CPU, then an SoC
adding an INT8 systolic-array accelerator, a descriptor-based DMA, and an AXI
interconnect. The RTL is also taken through an open-source ASIC flow to GDSII.

Full scope, phases, and definitions of done: [CLAUDE.md](CLAUDE.md).
Current state of the work: [docs/PROGRESS.md](docs/PROGRESS.md).

## Status

**Stage 1, Phase A — working core. In progress.** All five stages
implemented, and 37 of the 40 RV32I instructions: all ALU operations, loads
and stores, branches, JAL and JALR. Full forwarding, a one-cycle load-use
stall, and branches resolved in EX with static not-taken prediction (taken
costs two cycles). Both memory ports are BRAM-timed. Checked against a Python
golden model on dense random programs with branches and jumps — every
retirement compared field by field through the RVFI port. FENCE, ECALL and
EBREAK still decode inert rather than half-working.

| Stage | Phases | State |
|---|---|---|
| 1 — CPU | A–E | Phase A in progress |
| 2 — SoC | F–H | Not started |

```
make lint    # Verilator 5.050 lint, zero warnings
make sim     # cocotb 2.1.0 regression, 116/116 passing
make synth   # out-of-context synth + P&R, reports to docs/reports/
```

## Architecture

_TODO: block diagram_

## Results

No result is claimed here until it is reproduced by `make` and transcribed from a
committed report in [`docs/reports/`](docs/reports/). Dashes are honest.

**Stage 1 — CPU.** Conditions travel with the number: an out-of-context Fmax models
no clock skew and is not the same quantity as a board-level one, so the two never
share a table. See [docs/PROGRESS.md](docs/PROGRESS.md) for the per-slice trend.

| Metric | Value |
|---|---|
| Fmax, out-of-context (`xc7a100tcsg324-1`, 10.000 ns constraint) | 104.1 MHz *(Phase A in progress)* |
| Fmax, board-level | — |
| LUT / FF / BRAM / DSP | 1095 / 496 / 0 / 0 *(Phase A in progress)* |
| CoreMark/MHz (on the board, 50 MHz, 1000 iterations, validated) | 0.962 — RV32I without M, so multiply and divide run in software |
| IPC / CPI (CoreMark timed region, RTL simulation of the same SoC) | 0.691 / 1.447 |
| Formal: properties proven, proof depth | — |
| Bugs formal caught that simulation missed | — |
| Functional coverage | — |
| TMR: fault detection / recovery rate | — |
| TMR: area overhead / Fmax penalty | — |

**Stage 2 — SoC.**

| Metric | Value |
|---|---|
| GOPS (INT8) at achieved Fmax | — |
| **Measured** PE utilization | — |
| Speedup vs. software matmul | — |
| DSP slices used vs. LUT-fabric MACs | — |
| AXI outstanding depth / measured throughput | — |
| SVA properties proven on AXI interfaces | — |

**ASIC flow (LibreLane + Sky130).** Two runs: the bare core closing Phase E, the full
SoC in Phase H. The delta between them is the result.

| Metric | Run 1 (bare core) | Run 2 (full SoC) |
|---|---|---|
| Die area, cell count, utilization | — | — |
| Post-layout Fmax | — | — |
| Power estimate | — | — |
| DRC / LVS clean | — | — |
| Scan chains: count, coverage, area overhead | — | — |

## Build

Requires Verilator ≥ 5.036 (the cocotb 2.x floor) and **cocotb ≥ 2.1.0**; the repo
expects a venv at `~/cocotb-env`, falling back to whatever `cocotb-config` is on
`PATH`. The cocotb floor is not arbitrary — on 2.0.1, a register-file-sized array in
the design corrupts Verilator's VPI layer and reading a top-level port segfaults. Vivado 2025.2
is needed for `make synth` — see [docs/vivado-setup.md](docs/vivado-setup.md).

| Target | Does | State |
|---|---|---|
| `make lint` | Verilator lint of `rtl/`, zero warnings | live |
| `make sim` | cocotb regression on Verilator | live |
| `make synth` | Out-of-context synth **and** P&R of the core, reports to `docs/reports/` | live |
| `make sw` | Build `sw/**/*.c` to `.elf` / `.hex` | live, no sources yet |
| `make spike` | Run the `.elf` on the spike reference model | live, no sources yet |
| `make formal` | SymbiYosys, all properties | Phase B |
| `make uvm` | UVM regression in XSim | Phase C |
| `make impl` | Board-level P&R, emits bitstream | Phase D |
| `make prog` | Program the board | Phase D |
| `make asic` | LibreLane RTL-to-GDSII | Phase E, then H |

Targets whose phase has not arrived print which phase they belong to and what they are
waiting on, rather than failing with `No rule to make target`.

`make synth` runs through place & route rather than stopping at synthesis, because
post-synthesis timing is an estimate and post-route timing is measured.

## Repository layout

Directories are created when they have something to hold, so this is the target shape
rather than the current one — build scripts walk `rtl/` recursively and error on an
empty match, so a new subdirectory needs no build change.

| Path | Contents |
|---|---|
| `rtl/core/` | Pipeline stages, regfile, ALU, hazard unit |
| `rtl/tmr/` | Triplicated wrapper + voter |
| `rtl/accel/` | Systolic array (Stage 2) |
| `rtl/bus/` | AXI interconnect, DMA (Stage 2) |
| `rtl/periph/` | UART, timer |
| `tb/cocotb/` | Python testbenches |
| `tb/uvm/` | SystemVerilog UVM environment |
| `tb/formal/` | SVA property files, SymbiYosys configs |
| `sw/tests/` | C and assembly test programs |
| `sw/model/` | Python/C++ golden reference models |
| `sim/` | Simulation scripts, waveform configs |
| `syn/` | Vivado Tcl scripts |
| `constr/` | XDC timing/pin constraints |
| `docs/` | Design docs, coverage plans, committed reports |
| `scripts/` | Build automation |
