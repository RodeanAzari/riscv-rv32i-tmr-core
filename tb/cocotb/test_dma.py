"""The DMA engine on the whole SoC, driven by software on the core.

The RAM starts with the bootloader and sw/apps/dmatest.c saved
(sw/build/boot_dma_sim.hex), reached with r. dmatest drives the engine
through the bare-metal driver (sw/lib/dma.c, DMA-Engine's dmaeng_regs.h)
over the core's AXI4-Lite bridge, and the engine copies through the RAM's
shared port in the cycles the core leaves free. dmatest checks every copy
itself; this test requires its summary to be all passes and, independently,
reads the 4 KiB copy back out of the RAM.

What matters and why:
  - the path core -> bridge -> registers -> engine -> RAM works end to end,
    with the core held on each register access (MEM_WAIT) and the engine
    stealing RAM cycles, which no block-level test covers;
  - the core is never wrong for it: dmatest is ordinary code whose every
    other memory access goes on in parallel with the engine's.
"""

import re

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from test_demo import CLK_PERIOD_NS, CLKS_PER_BIT, uart_out


@cocotb.test()
async def test_dmatest(dut):
    out = []
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    dut.uart_rx_i.value = 1
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 5)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0
    cocotb.start_soon(uart_out(dut, out))

    async def expect(text, cycles=40_000_000):
        for _ in range(0, cycles, 2000):
            if text in "".join(out):
                return "".join(out)
            await ClockCycles(dut.clk_i, 2000)
        raise AssertionError(f"waited for {text!r}; output was {''.join(out)[-800:]!r}")

    await expect("or r to rerun the last one\r\n")
    for bit in [0] + [(ord("r") >> i) & 1 for i in range(8)] + [1]:
        dut.uart_rx_i.value = bit
        await ClockCycles(dut.clk_i, CLKS_PER_BIT)
    text = await expect(" ok\r\n")
    dut._log.info("\n" + text[text.index("dmatest:"):])

    summary = re.search(r"dmatest: (\d+)/(\d+) ok", text)
    assert summary and summary[1] == summary[2], f"dmatest failed:\n{text}"
    assert int(summary[2]) >= 180, "dmatest ran fewer checks than it has"
    assert "FAIL" not in text

    # the 4 KiB copy, read back from the RAM by this test
    big = re.search(r"4096 B 0x([0-9a-f]+) -> 0x([0-9a-f]+): dma (\d+) cycles, core (\d+)", text)
    assert big, "no timing line"
    src, dst = int(big[1], 16), int(big[2], 16)
    ram = dut.u_ram.mem
    for i in range(0, 4096, 4):
        assert int(ram[(src + i) // 4].value) == int(ram[(dst + i) // 4].value), \
            f"word {i // 4} of the copy differs in RAM"
    dut._log.info(f"4 KiB: engine {big[3]} cycles, core {big[4]} cycles")
