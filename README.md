# RISC-V RV32I Core — Formally Verified, Fault-Tolerant

In-order 5-stage pipelined RV32I core targeting the Arty A7, with formal
verification, a UVM environment, and a TMR variant with fault injection.

Full scope, phases, and deliverables: [CLAUDE.md](CLAUDE.md)

## Status

Phase A — working core. Not yet implemented.

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

_TODO: `make sim` / `make synth` / `make prog` once the toolchain is pinned._

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
