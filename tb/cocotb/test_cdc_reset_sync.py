"""Reset synchronizer: asserts at once, releases on a clock edge.

  - arst_i rising sets rst_o within the same instant, at a random point in
    the clock period, and with the clock stopped
  - after arst_i falls (at a random point), rst_o stays high through
    STAGES - 1 rising edges and falls on exactly the STAGES-th, and only on
    an edge: it is checked just before and just after every edge
STAGES from CDC_SYNC_STAGES.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

STAGES = int(os.environ.get("CDC_SYNC_STAGES", "2"))
PERIOD_PS = 10_000


@cocotb.test()
async def test_reset_sync(dut):
    rng = random.Random(9)
    # clock stopped: assertion still immediate
    dut.clk_i.value = 0
    dut.arst_i.value = 0
    await Timer(5_000, unit="ps")
    dut.arst_i.value = 1
    await Timer(1, unit="ps")
    assert int(dut.rst_o.value) == 1, "rst_o did not assert without a clock"

    cocotb.start_soon(Clock(dut.clk_i, PERIOD_PS, unit="ps").start())
    for trial in range(200):
        # release at a random point in the period
        await Timer(rng.randrange(1, 3 * PERIOD_PS), unit="ps")
        dut.arst_i.value = 0
        await Timer(1, unit="ps")
        assert int(dut.rst_o.value) == 1, "rst_o fell with arst_i, not on an edge"
        for k in range(1, STAGES + 1):
            await RisingEdge(dut.clk_i)
            await Timer(1, unit="ps")
            want = 0 if k == STAGES else 1
            assert int(dut.rst_o.value) == want, f"after edge {k}: rst_o {int(dut.rst_o.value)}"
            if k < STAGES:
                await Timer(PERIOD_PS - 2, unit="ps")   # just before the next edge
                assert int(dut.rst_o.value) == 1, "rst_o fell between edges"
        # stays released
        for _ in range(rng.randrange(1, 5)):
            await FallingEdge(dut.clk_i)
            assert int(dut.rst_o.value) == 0
        # assert at a random point: immediate
        await Timer(rng.randrange(1, PERIOD_PS), unit="ps")
        dut.arst_i.value = 1
        await Timer(1, unit="ps")
        assert int(dut.rst_o.value) == 1, "rst_o did not assert at once"
