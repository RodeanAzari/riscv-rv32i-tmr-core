"""The GEMM accelerator on the whole SoC, launched by software on the core
(buildplan Phase G: "software on the core configures and launches an
accelerator job").

The RAM starts with the bootloader and sw/apps/gemmtest.c saved
(sw/build/boot_gemm_sim.hex), reached with r. gemmtest moves each A and W
into the accelerator's buffers with the DMA, starts the job over the core's
AXI4-Lite bridge, polls, moves C back, and checks it against the core's own
multiply. This test requires its summary to be all passes and,
independently of the core's arithmetic, reads the last A, W and C out of
the RAM and checks C against the golden model; and every job's cycle count
must be the model's.

What matters and why:
  - core -> bridge -> crossbar -> accelerator registers, and DMA -> crossbar
    -> accelerator buffers, work end to end, with the core held on every
    register access and the DMA stealing RAM cycles;
  - the job's cycle count on the SoC is the contract measured in the
    block test: utilization figures quoted from it hold here too.
"""

from pathlib import Path
import re
import sys

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from test_demo import CLK_PERIOD_NS, CLKS_PER_BIT, uart_out
from test_soc import assert_no_tmr_mismatch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import accel_model as am  # noqa: E402


def ram_bytes(dut, addr, length):
    ram = dut.u_ram.mem
    out = bytearray()
    for i in range(addr // 4, (addr + length + 3) // 4):
        out += int(ram[i].value).to_bytes(4, "little")
    off = addr % 4
    return bytes(out[off:off + length])


@cocotb.test()
async def test_gemmtest(dut):
    out = []
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    dut.uart_rx_i.value = 1
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 5)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0
    cocotb.start_soon(uart_out(dut, out))

    async def expect(text, cycles=60_000_000):
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
    dut._log.info("\n" + text[text.index("gemmtest:"):])

    summary = re.search(r"gemmtest: (\d+)/(\d+) ok", text)
    assert summary and summary[1] == summary[2], f"gemmtest failed:\n{text}"
    assert "FAIL" not in text and "WRONG" not in text

    jobs = re.findall(r"gemmtest: (\d+)x(\d+)x(\d+) ok, job (\d+) cycles", text)
    assert len(jobs) >= 6, "gemmtest ran fewer shapes than it has"
    for m, k, n, cyc in jobs:
        m, k, n, cyc = int(m), int(k), int(n), int(cyc)
        want = am.job_cycles(m, k, n, 16, 16)
        assert cyc == want, f"{m}x{k}x{n}: job {cyc} cycles, model {want}"
        util = m * k * n / (cyc * 256)
        dut._log.info(f"{m}x{k}x{n}: {cyc} cycles, PE utilization {100 * util:.1f}%")

    # the last shape, from RAM, against the golden model
    m, k, n = (int(x) for x in jobs[-1][:3])
    addr = re.search(r"last a 0x([0-9a-f]+) w 0x([0-9a-f]+) c 0x([0-9a-f]+)", text)
    pa, pw, pc = (int(addr[i], 16) for i in (1, 2, 3))
    a = np.frombuffer(ram_bytes(dut, pa, m * k), dtype=np.int8).reshape(m, k)
    w = np.frombuffer(ram_bytes(dut, pw, k * n), dtype=np.int8).reshape(k, n)
    c = np.frombuffer(ram_bytes(dut, pc, 4 * m * n), dtype="<i4").reshape(m, n)
    assert np.array_equal(c, am.gemm(a, w)), "C in RAM differs from the model"
    assert_no_tmr_mismatch(dut)
