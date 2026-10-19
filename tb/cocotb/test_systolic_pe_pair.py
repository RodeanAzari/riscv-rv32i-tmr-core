"""Two PEs sharing one DSP: both lanes against the golden model.

systolic_pe_pair must behave as two systolic_pe fed the same activation:
each psum_o[k] = gemm_model.pe(a, w_k, psum_i[k]) one cycle later. The
packing arithmetic itself is checked for every (a, w0, w1) in the model
(sw/model/gemm_model.py); here the RTL's slicing of it is. Each lane sweeps
all 65,536 (activation, weight) pairs while the other lane's weight sits at
-128, -1, 0, 1 and 127: the extremes, and the negative values whose borrow
the upper lane has to give back. Weights swap back to back, as in the
single-PE test, and psums take both INT32 limits.
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
PARTNERS = (-128, -1, 0, 1, 127)


def pair(lo, hi, width):
    return (lo & ((1 << width) - 1)) | ((hi & ((1 << width) - 1)) << width)


def lanes(word, width):
    out = []
    for k in range(2):
        v = (word >> (width * k)) & ((1 << width) - 1)
        out.append(v - (1 << width) if v >> (width - 1) else v)
    return out


def drive(dut, a=0, psums=(0, 0), ws=(0, 0), shift=0, swap=0):
    dut.a_i.value = a & 0xFF
    dut.psum_i.value = pair(psums[0], psums[1], 32)
    dut.w_i.value = pair(ws[0], ws[1], 8)
    dut.w_shift_i.value = shift
    dut.w_swap_i.value = swap


@cocotb.test()
async def test_lanes(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    drive(dut)
    dut.rst_i.value = 1
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0

    rng = random.Random(4)
    psums = [0, INT32_MAX, INT32_MIN, -1, 1] + [rng.randint(INT32_MIN, INT32_MAX) for _ in range(6)]
    weights = [(w, p) for p in PARTNERS for w in range(-128, 128)] + \
              [(p, w) for p in PARTNERS for w in range(-128, 128)]

    drive(dut, ws=weights[0], shift=1)
    await FallingEdge(dut.clk_i)
    drive(dut, swap=1)
    await FallingEdge(dut.clk_i)

    checked = 0
    for wi, ws in enumerate(weights):
        nxt = weights[wi + 1] if wi + 1 < len(weights) else (0, 0)
        for ai, a in enumerate(range(-128, 128)):
            ps = (psums[(ai + wi) % len(psums)], psums[(ai + 3 * wi + 1) % len(psums)])
            drive(dut, a=a, psums=ps, ws=nxt, shift=int(ai == 100), swap=int(ai == 255))
            await FallingEdge(dut.clk_i)
            got = lanes(int(dut.psum_o.value), 32)
            want = [gemm_model.pe(a, ws[k], ps[k]) for k in range(2)]
            if got != want:
                raise AssertionError(f"a={a} w={ws} psum={ps}: psum_o {got}, model {want}")
            assert dut.a_o.value.to_signed() == a
            assert dut.w_swap_o.value == int(ai == 255)
            if ai == 100:
                assert lanes(int(dut.w_o.value), 8) == list(nxt), "w_o is not the shadow weights"
            checked += 1
    dut._log.info("PE pair: %d activations x weight pairs, both lanes match the golden model", checked)
