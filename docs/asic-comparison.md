# Two comparisons: ASIC run #1 vs run #2, and FPGA vs ASIC

Buildplan §6.4 asks for both. Every number is from a committed report,
named where it is used; arithmetic on them is shown.

## 1. Run #1 (the core) vs run #2 (the SoC)

Both: LibreLane 3.0.16, sky130A `sky130_fd_sc_hd`, signoff at 9 corners,
worst corner quoted (always max_ss_100C_1v60 for setup).

| | Run #1 ([summary_asic.txt](reports/summary_asic.txt)) | Run #2 ([summary_asic_soc.txt](reports/summary_asic_soc.txt)) | Ratio |
|---|---|---|---|
| Design | `riscv_core` alone: single core, RV32I; memories are pins; register file as 1,024 flops | `asic_top`: the same core (single, RV32I) + AXI crossbar + DMA + 16×16 INT8 accelerator + UART; every RAM one of 48 OpenRAM macros | |
| Clock | 35 ns | 50 ns | |
| Die | 227,997 µm² (472 × 483 µm) | 31,200,000 µm² (6000 × 5200 µm) | 137× |
| Standard-cell area | 119,277 µm² | 3,704,850 µm² | 31× |
| SRAM macro area | none | 12.16 mm²: 32 × 683.1 × 416.54 µm + 16 × 479.78 × 397.5 µm (macro LEFs); 39% of the core area | |
| Flip-flops | 1,496 | 19,557 | 13× |
| Routed wirelength | 474,722 µm | 16,716,547 µm | 35× |
| Global-route usage, overflow ([congestion_asic.txt](reports/congestion_asic.txt)) | 42.0% (met1/met2 55%), 0 | 17.7% (met1 27%), 0 | |
| Worst setup slack, Fmax | +3.502 ns, 31.7 MHz | +0.695 ns, 20.3 MHz | |
| Worst path | flop → fetch address → `imem_addr_o` (output port, 20% of the period owed outside) | SRAM read port → accelerator logic → flop, in half a period | |
| Power (tt, vectorless) | 4.60 mW | 87.7 mW | 19× |
| Max-slew pins (max_ss) | 3,091 | 83,303 | 27× |
| Antenna nets left | 0 | 1 | |

**Area: the memories set the die, not the logic.** Run #1 is a block
whose memories are someone else's problem; run #2 owns 80 KiB of SRAM. The
48 macros take 12.16 mm², three times the standard cells, and the die is
sized to place them with 100 to 150 µm routing channels around each (the
floorplan in `syn/asic_soc.yaml`, by hand: the Classic flow has no macro
placer). The logic sits in the centre, about 3100 × 2630 µm. Utilization
looks similar (56.3% against 51.2%) but means different things: run #2's
figure counts the macros.

**Congestion did not get worse; distance did.** Global routing used 42%
of run #1's resources (55% on met1/met2) and 17.7% of run #2's, with no
overflow on any layer in either. Run #2's die has room to spare, so its
problems were length, not crowding: wirelength grew 35× for 31× the cell
area, the longest net from 1.25 mm to 2.32 mm, clock latency from about
2.4 ns (measurements.md, run #1) to about 12.3 ns at the worst path's
endpoint, and setup skew to 1.97 ns (from 0.34 ns, `final/metrics.json`).
Long nets are also what left the slew violations: LibreLane repairs slew
once, after global routing, on estimated parasitics (measurements.md,
"Why the slew is left"). Routing's real trouble was local: OpenROAD lost
every access point of one SRAM pin after antenna repair (issue #12200),
fixed by moving one macro 0.46 µm and inserting diodes before routing.

**Timing: the critical path moved from the core to the memory interface.**
Run #1's worst path is the core's own fetch-address path, the same one
that limits it on the FPGA; register to register it would run at 46.2 MHz.
In run #2 that path is no longer near the top. The worst path starts at an
accelerator buffer's SRAM read port. OpenRAM's liberty times `dout` from
the **falling** clock edge (`timing_type : falling_edge`), so whatever
logic follows an SRAM read gets half a period, and the macros sit
millimetres from the read mux (16 repeaters on `dout`): 23.5 ns of the
25 ns half-period at max_ss. 40 ns failed by −2.7 ns for that reason; 50 ns
closes with +0.695 ns. **The RTL feedback:** a register on every SRAM
read output (one cycle of read latency, which the accelerator's sequencer
and the core's load path would have to absorb) is the change that would
let the clock move; the core's fetch-address path is the next limit after
that.

**Power** rises 19× for 31× the cell area, at a lower clock (20 against
28.6 MHz); both are vectorless estimates with default activity, not
measurements.

## 2. FPGA vs ASIC, the same RTL

Same RTL: `soc` with its defaults (single core, RV32I, the array on the
core clock), on the Arty's Artix-7 (`xc7a100tcsg324-1`, 28 nm, speed grade
−1, Vivado 2025.2, [summary_board.txt](reports/summary_board.txt)) and on
Sky130 (130 nm, run #2 above). FPGA and ASIC numbers are never put in one
table elsewhere in this repo (CLAUDE.md §10); this section only compares
them side by side in prose.

**Speed: 100 MHz against 20.3 MHz.** The FPGA meets 100 MHz with
+0.263 ns (102.7 MHz at that placement); the ASIC closes at 50 ns, 26.6 MHz
at the typical corner. Most of the gap is process and signoff: 28 nm
against 130 nm, and Sky130 signed off at its slow corner (1.60 V, 100 °C).
The rest is memory. On the FPGA, the 32 block RAMs are hard blocks next to
the logic with a registered or same-edge read; on the ASIC the SRAM
macros are millimetres away and their model launches read data on the
falling edge, which halves the budget of the worst path (section 1).

**What is cheap differs.** On the FPGA a multiplier is free until the
DSP48s run out: the 16×16 array packs two INT8 MACs per DSP (128 of the
build's 131 DSPs, of 240) and costs 7,681 LUTs out of context; built in LUTs instead it needs 28,545
([summary_ooc_array16x16.txt](reports/summary_ooc_array16x16.txt)). On the
ASIC every multiplier is standard cells, and the 256 MACs are part of the
3.7 mm² of logic, against 12.16 mm² of SRAM. Memory is the reverse: on the
FPGA the SoC's 80 KiB takes 32 of 135 block RAMs and no logic; on the ASIC
it is the largest thing on the die and sets the floorplan. Flip-flops
follow the same pattern: 12,366 on the FPGA against 19,557 on the ASIC.
Small memories the FPGA puts in LUTs (82 LUTs as distributed RAM,
[utilization_board.rpt](reports/utilization_board.rpt)), the register file
among them, and registers it can keep inside the DSP48s, are ordinary
flops on the ASIC.

**Effort and what "done" means.** A board build takes minutes (`make impl
CDC=1`, 2026-11-25: 5 min on the laptop), on one timing model for the part. Run #2 took about 13.5 h on the desktop with a
27.1 GB peak, signs off at 9 corners, and adds checks with no FPGA
equivalent: DRC, LVS, antenna, slew and capacitance. Two of those stay
open in run #2 (one antenna net, 83,303 max-slew pins), which on the FPGA
are the vendor's problem, solved once in the silicon.

**Where the same RTL decision costs differently.** Triple modular
redundancy costs 3.1× the LUTs on the FPGA and still meets 100 MHz; it was
not taken to the ASIC. The register file is LUT RAM on the FPGA and 1,024
flops in run #1. The array's clock domain (`ARRAY_CDC`) needs a second
MMCM on the FPGA; `asic_top` leaves it off. Each of these is a different
trade on the two targets, which is the point of building both.
