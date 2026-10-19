"""Systolic-array PE: every activation x weight pair against the golden model.

sw/model/gemm_model.py is the reference (written before the RTL, buildplan
Phase F): psum_o must equal its pe(a, w, psum) one cycle after the inputs,
for all 65,536 (activation, weight) pairs, with partial sums at both INT32
limits so the wraparound is exercised too.

The weights are loaded the way the array will load them: the next weight
shifts into the shadow register while the current one is still in use, and
the swap lands on the last activation of the current weight, so the 65,536
pairs run back to back with no idle cycle. Any premature or late swap shows
up as a wrong product.
"""

from pathlib import Path
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import gemm_model  # noqa: E402

CLK_PERIOD_NS = 10
INT32_MIN, INT32_MAX = -2**31, 2**31 - 1


def drive(dut, a=0, psum=0, w=0, shift=0, swap=0):
    dut.a_i.value = a & 0xFF
    dut.psum_i.value = psum & 0xFFFF_FFFF
    dut.w_i.value = w & 0xFF
    dut.w_shift_i.value = shift
    dut.w_swap_i.value = swap


async def start(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    drive(dut)
    dut.rst_i.value = 1
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0


@cocotb.test()
async def test_reset(dut):
    """After reset: everything zero, and a zero weight gives psum_o = psum_i."""
    await start(dut)
    assert dut.a_o.value.to_signed() == 0
    assert dut.psum_o.value.to_signed() == 0
    assert dut.w_o.value.to_signed() == 0
    drive(dut, a=-128, psum=12345)
    await FallingEdge(dut.clk_i)
    assert dut.psum_o.value.to_signed() == 12345, "the active weight is not zero after reset"
    assert dut.a_o.value.to_signed() == -128


@cocotb.test()
async def test_exhaustive(dut):
    """All 256 x 256 (activation, weight) pairs, back to back, with psums at
    0, both INT32 limits and random values."""
    await start(dut)
    rng = random.Random(1)
    psums = [0, INT32_MAX, INT32_MIN, -1, 1] + [rng.randint(INT32_MIN, INT32_MAX) for _ in range(6)]
    weights = list(range(-128, 128))

    # Load the first weight: shift it into the shadow, then swap.
    drive(dut, w=weights[0], shift=1)
    await FallingEdge(dut.clk_i)
    assert dut.w_o.value.to_signed() == weights[0]
    drive(dut, swap=1)
    await FallingEdge(dut.clk_i)

    checked = 0
    for wi, w in enumerate(weights):
        nxt = weights[wi + 1] if wi + 1 < len(weights) else 0
        for ai, a in enumerate(range(-128, 128)):
            psum = psums[(ai + wi) % len(psums)]
            # Mid-stream, shift the next weight in; it must not be used yet.
            # On the last activation, swap: the next cycle uses it.
            drive(dut, a=a, psum=psum, w=nxt, shift=int(ai == 100), swap=int(ai == 255))
            await FallingEdge(dut.clk_i)
            got = dut.psum_o.value.to_signed()
            want = gemm_model.pe(a, w, psum)
            if got != want:
                raise AssertionError(f"a={a} w={w} psum={psum}: psum_o {got}, model {want}")
            assert dut.a_o.value.to_signed() == a
            assert dut.w_swap_o.value == int(ai == 255), "w_swap_o is not w_swap_i, registered"
            if ai == 100:
                assert dut.w_o.value.to_signed() == nxt, "w_o is not the shadow weight"
            checked += 1
    assert checked == 65536
    dut._log.info("PE: %d (activation, weight) pairs match the golden model", checked)
