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
| Fmax, out-of-context (`xc7a100tcsg324-1`, 10.000 ns constraint) | 122.7 MHz |
| Fmax, board-level (Arty A7, core + BRAM + I/O, in context) | runs at 100 MHz, WNS +1.550 ns (118.3 MHz estimate) |
| LUT / FF / BRAM / DSP (core, out-of-context) | 964 / 467 / 0 / 0 |
| CoreMark/MHz (on the board, 100 MHz, 2000 iterations, validated) | 0.962 (about 96 CoreMark) — RV32I without M, so multiply and divide run in software |
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

## On the chip

The single (non-TMR) core as it runs on the Arty A7-100T: CoreMark image,
100 MHz, the build whose reports are committed (WNS +1.550 ns). A new set
follows each milestone; these are from Phase D, in
[`docs/img/vivado/phase-d/`](docs/img/vivado/phase-d/).

**Floorplan** (`make floorplan`): every placed cell at its real site, coloured
by module, with its routed wires and the worst setup path in yellow. Drawn
from the routed checkpoint, not a screenshot; click to open it full size and
zoom in to individual LUTs and flip-flops.

[![Floorplan of the core, cropped to the logic](docs/img/floorplan_board_core.svg)](docs/img/floorplan_board_core.svg)

The [whole die](docs/img/floorplan_board.svg), for scale: the SoC uses under
2% of the chip's LUTs, in one of eight clock regions.

**Vivado** (`make gui`, `make gui VIEW=rtl`):

| | |
|---|---|
| ![Device view](docs/img/vivado/phase-d/device.png) Device view, coloured by module | ![Device view, zoomed](docs/img/vivado/phase-d/device-zoom.png) Zoomed to single slices, with routing |
| ![Worst path on the device](docs/img/vivado/phase-d/worstpathdevice.png) The worst setup path on the die | ![Worst path schematic](docs/img/vivado/phase-d/worstpath.png) The same path: forwarding select → branch comparator (CARRY4 chain) → redirect → pc mux → block RAM address |
| ![RTL schematic of the core](docs/img/vivado/phase-d/rtl-schematic-u_core.png) The core as elaborated RTL | ![RTL schematic of the ALU](docs/img/vivado/phase-d/rtl-schematic-alu.png) The ALU, opened up |
| ![Timing summary](docs/img/vivado/phase-d/timing.png) Timing: met at 100 MHz, WNS +1.550 ns, WHS +0.110 ns | ![Utilization by hierarchy](docs/img/vivado/phase-d/utilization-hierarchy.png) Utilization by module |
| ![Power estimate](docs/img/vivado/phase-d/power.png) Power: 0.26 W, Vivado's **vectorless estimate**, not a measurement; the MMCM is 65% of it | |

**On the board, live** (ILA, `make impl ILA=1`, `make gui VIEW=ila`): the
pipeline registers captured on the chip while CoreMark runs, triggered as
`core_state_transition` enters EX. Rows top to bottom: the pc in IF/ID, ID/EX,
EX/MEM, MEM/WB, then the instruction in ID/EX. Capture:
[`docs/reports/ila_coremark.csv`](docs/reports/ila_coremark.csv).

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
| `make gui` | Open the routed design in the Vivado GUI (`VIEW=rtl`: RTL schematic; `VIEW=ila`: live waveforms) | live |
| `make floorplan` | Draw the routed design as zoomable SVGs in `docs/img/` | live |
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
