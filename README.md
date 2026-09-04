# RISC-V RV32I Core — Formally Verified, Fault-Tolerant

In-order 5-stage pipelined RV32I core targeting the Arty A7, with formal
verification, a UVM environment, and a TMR variant with fault injection.

Full scope, phases, and deliverables: [CLAUDE.md](CLAUDE.md)

## Status

Phase A — working core. PC and IF stage implemented; ID/EX/MEM/WB, hazard
unit, and forwarding still to come.

```
make lint    # Verilator 5.050 lint, clean
make sim     # cocotb 2.0.1 regression, 3/3 passing
```

## Architecture

_TODO: block diagram_

## Results

_TODO: measured numbers only — no results claimed until they are reproduced by
`make`._

| Metric | Value |
|---|---|
| Fmax (Artix-7) | — |
| LUT / FF / BRAM / DSP | — |
| CPI (CoreMark / Dhrystone) | — |
| Properties proven | — |
| Functional coverage | — |
| TMR fault detection / recovery | — |

## Build

| Target | Does |
|---|---|
| `make lint` | Verilator lint of `rtl/` |
| `make sim` | cocotb regression on Verilator |
| `make sw` | Build `sw/*.c` to `.elf` / `.hex` with riscv32-unknown-elf-gcc |
| `make spike` | Run the `.elf` on the spike reference model |

Requires Verilator >= 5.036 (cocotb 2.x floor) and the cocotb venv at
`~/cocotb-env`. Synthesis targets land in Phase D, once Vivado is installed.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/` | Synthesizable SystemVerilog only |
| `tb/` | Testbenches (UVM / cocotb) |
| `sim/` | Simulation scripts, waveform configs |
| `syn/` | Synthesis + implementation scripts (Tcl) |
| `constr/` | XDC timing/pin constraints |
| `sw/` | Host software, drivers, reference models |
| `docs/` | Design docs, coverage plans, timing reports |
| `scripts/` | Build automation |
