# Changelog

Releases of the `soc` block (owner P1, `~/fpga-coord/dependencies.toml`).
Consume only at a tag, as a git submodule checked out at that tag.

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
