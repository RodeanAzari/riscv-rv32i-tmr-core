# Changelog

Releases of the `soc` block (owner P1, `~/fpga-coord/dependencies.toml`).
Consume only at a tag, as a git submodule checked out at that tag.

## soc-v2.0 (2026-11-25)

Phase H: the array on its own clock, reprogrammable by the core; the
weight-transform hook; the M extension. **Every addition is a parameter
that defaults off**, so a v1.0 consumer that sets none of them gets the
same SoC and the same cycle counts.

- **Release test:** `make lint`, `make accel-model`, `make aclk-check`,
  `make -C tb/cocotb TESTS="gemm_accel_cdc gemm_accel_4x4_cdc gemm_accel_4x4_wx
  gemm_accel_4x4_cdc_wx (test_gemm_accel); soc, soc_cdc, soc_tmr_cdc
  (test_gemm); soc_m, soc_tmr_m (test_coremark)"`; the full regression in CI
  (lint, sim, formal); on the board, `make impl CDC=1` and `gemmtest` with the
  array clock moved 100 → 80 → 100 MHz by the core over the DRP.
- **Result:** all pass. cocotb 9 builds, 0 failures; board 22/22 in each of
  5 runs, every job's CYCLES the golden model's at a phase the two clocks
  allow; `report_cdc` 0 warnings, 0 unsafe crossings; 100 MHz met on both
  clocks (+0.349 ns).
- **Evidence:** [docs/reports/release_soc-v2.0.txt](docs/reports/release_soc-v2.0.txt),
  [docs/reports/gemmtest_board_soc-v2.0.txt](docs/reports/gemmtest_board_soc-v2.0.txt),
  [docs/reports/cdc_board_cdc.rpt](docs/reports/cdc_board_cdc.rpt).

**What consumers must change:** tie the new input ports to 0 (`clk_array_i`,
`aclk_locked_i`, `drp_do_i`, `drp_drdy_i`, `wx_w_i`) and leave the new outputs
open; nothing else unless they set the new parameters. New ports on `soc`:

| Parameter (default) | What it adds | Ports, registers |
|---|---|---|
| `ARRAY_CDC` (0) | The systolic array on `clk_array_i`, async FIFOs both ways, reset synchronized into it; the sequencer and buffers stay on `clk_i` | `clk_array_i`. Board: a second `MMCME2_ADV` (`arty_a7_top`), crossings bounded per path in `constr/accel_cdc.xdc` (max-delay, not `set_clock_groups`) |
| (with `ARRAY_CDC`) | The array clock reprogrammed at run time over the MMCM's DRP (DCLK = `clk_i`) | `aclk_rst_o`, `aclk_locked_i`, `drp_*`; register **ACLK at `0x1000_001C`** (reads 0 without `ARRAY_CDC`); driver `sw/lib/aclk.{h,c}`, `aclk_set_divide(d)`; the accelerator must be idle, its registers reset afterwards |
| `WX_EXT` (0) | Weight-transform hook on the `clk_i` side, before the array's input FIFO (P5 0009, 0010): with 1 the array loads `wx_w_i` | `wx_start_o`, `wx_valid_o`, `wx_kt_o`, `wx_nt_o`, `wx_row_o`, `wx_pad_o`, `wx_w_o`, `wx_w_i`; contract in `rtl/accel/gemm_accel_seq.sv`'s header, load order = `weight_beats()` in `sw/model/accel_model.py` |
| `M_EXT` (0) | RV32IM: MUL/MULH* 2-3 cycles on DSPs, DIV/REM* fixed ~34 cycles | firmware with `-march=rv32im` (`make ... M=1`) |

**Limits consumers should know:** no interrupts (poll); every trap halts;
the array clock divider is reprogrammed only while the accelerator is idle;
`aclk_set_divide` gives up after 10 ms without LOCKED (on the board it
relocks in ~22 µs). The ASIC top (`asic_top`, LibreLane run #2) is the
default SoC and is not part of this block's interface.

## soc-v1.0 (2026-11-05)

Phase G: the RV32I core (single or TMR) with an AXI4 interconnect, a DMA
engine and a GEMM accelerator, all launched by software on the core.

- **Release test:** `make lint`, `make dma-model`,
  `make -C tb/cocotb TESTS="dmaeng_regs:test_dmaeng_regs dmaeng:test_dmaeng axi_xbar:test_axi_xbar soc:test_dma soc_tmr:test_dma"`,
  `sby -f tb/formal/axi_xbar.sby` (in `tb/formal/`).
- **Result:** all pass. cocotb 18/18; the crossbar's AXI properties (VALID
  held and payload stable, grant next edge, no combinational VALID→READY,
  outstanding ≤ 1, B only after WLAST) proven by k-induction at depth 8, all 4
  covers reached. Full regression on the same RTL green in CI (run 42103046882).
- **Evidence:** [docs/reports/release_soc-v1.0.txt](docs/reports/release_soc-v1.0.txt).

**Interface** (memory map in `rtl/top/soc.sv`'s header):

| Address | What |
|---|---|
| `0x0000_0000` | RAM, code and data (32 KiB) |
| `0x1000_0000`–`0x1000_0018` | LED, UART TX/ST/RX, CYCLE, TMR, BUSERR |
| `0x2000_0000`–`0x2000_0FFF` | DMA engine registers ([DMA-Engine](https://github.com/RodeanAzari/DMA-Engine)'s map; driver `sw/lib/dma.{h,c}`) |
| `0x2000_1000`–`0x2000_1FFF` | GEMM accelerator registers (driver `sw/lib/gemm.{h,c}`) |
| `0x2010_0000` / `_4000` / `_8000` | accelerator A / W / C buffers, 16 KiB each |

Rest of `0x2000_0000`–`0x2FFF_FFFF`: DECERR (load reads 0, BUSERR set).
Accesses there hold the core until the bus answers; RAM and I/O never do.

**Limits consumers should know:** RV32I only (no M; `*` `/` `%` are libgcc
calls); no interrupts (poll the DMA and the accelerator); every trap halts the
core; `clk_array` is the core clock (its own domain comes in `soc-v2.0`).
Board: 100 MHz met, single core and TMR. At the tag, `dmatest` and `gemmtest`
had run in simulation only. **Later the same day (no RTL change):** both pass on
the board, single core and TMR, with cycle counts equal to simulation's
([dmatest_board.txt](docs/reports/dmatest_board.txt),
[gemmtest_board.txt](docs/reports/gemmtest_board.txt)).
