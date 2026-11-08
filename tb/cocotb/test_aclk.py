"""array_clk_ctl against AMD's own MMCME2_ADV model (tb/aclk/aclk_tb.sv,
Icarus, make aclk-check).

What matters and why:
  - software can change the array clock: the register, used as
    sw/lib/aclk.c uses it (AMD's read-modify-write flow, the words from
    sw/model/mmcm_drp.py), takes the real primitive from 100 MHz to 80 and
    back, measured on its output;
  - the model's picture of the MMCM is the primitive's: the registers it
    starts from read back the same, and the output period is the one the
    model computes from them;
  - the array is held in reset from RST until LOCKED is back, at every
    moment in between, so it never runs on a clock that is not locked.
"""

from pathlib import Path
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import mmcm_drp as md  # noqa: E402

GO, WE, RST = 1 << 24, 1 << 23, 1 << 31
BUSY, LOCKED = 1 << 16, 1 << 17
CLK_PS = 10_000            # clk_i (DCLK), like the board's core clock
LOCK_TIMEOUT_CYCLES = 20_000


def bits(sig):
    """The signal as a string, MSB first, x where the model drives x."""
    return str(sig.value).lower()


def status(dut):
    s = bits(dut.rdata_o)
    return int(s[-18:-16].replace("x", "0").replace("z", "0"), 2) << 16


async def write(dut, word):
    await FallingEdge(dut.clk_i)
    dut.we_i.value, dut.wdata_i.value = 1, word
    await FallingEdge(dut.clk_i)
    dut.we_i.value = 0


async def wait_idle(dut):
    for _ in range(100):
        await FallingEdge(dut.clk_i)
        if not status(dut) & BUSY:
            return
    raise AssertionError("DRP access never finished (DRDY lost)")


async def drp_read(dut, addr, rst):
    await write(dut, rst | GO | (addr << 16))
    await wait_idle(dut)
    return bits(dut.rdata_o)[-16:]


async def drp_write(dut, addr, data, rst):
    await write(dut, rst | GO | WE | (addr << 16) | data)
    await wait_idle(dut)


async def watch_held(dut, bad):
    """Whenever the array is released, the MMCM is out of reset and locked:
    checked on the primitive's own RST and LOCKED at every clk_i edge."""
    while True:
        await RisingEdge(dut.clk_i)
        if not int(dut.array_rst_o.value) and (int(dut.u_ctl.mmcm_rst_o.value)
                                               or str(dut.locked_o.value) != "1"):
            bad.append(get_sim_time("ps"))


async def wait_locked(dut):
    for _ in range(LOCK_TIMEOUT_CYCLES):
        await FallingEdge(dut.clk_i)
        if status(dut) & LOCKED:
            return get_sim_time("ps")
    raise AssertionError("LOCKED never came back")


async def period_ps(dut, n=64):
    await RisingEdge(dut.clk_out_o)
    t0 = get_sim_time("ps")
    ts = [t0]
    for _ in range(n):
        await RisingEdge(dut.clk_out_o)
        ts.append(get_sim_time("ps"))
    gaps = {b - a for a, b in zip(ts, ts[1:])}
    assert len(gaps) == 1, f"output period not steady: {sorted(gaps)}"
    return gaps.pop()


def field(s, hi, lo):
    """bits [hi:lo] of a 16-character binary string, MSB first."""
    return s[15 - hi:16 - lo]


async def reprogram(dut, d):
    t_rst = get_sim_time("ps")
    for addr, mask, val in md.updates(d):
        old = await drp_read(dut, addr, RST)
        # x (a reserved bit the primitive leaves undefined) is kept as 0
        keep = int(old.replace("x", "0"), 2) & mask
        await drp_write(dut, addr, keep | val, RST)
    assert int(dut.array_rst_o.value), "array released during reprogramming"
    await write(dut, 0)
    t_lock = await wait_locked(dut)
    # LOCKED is seen through the synchronizer: by now array_rst_o is low
    await FallingEdge(dut.clk_i)
    assert not int(dut.array_rst_o.value), "array still held after LOCKED"
    return t_lock - t_rst


@cocotb.test()
async def test_reprogram(dut):
    """100 MHz from the bitstream, 80 by DRP, back to 100."""
    cocotb.start_soon(Clock(dut.clk100_i, 10_000, unit="ps").start())
    await Timer(3_000, unit="ps")
    cocotb.start_soon(Clock(dut.clk_i, CLK_PS, unit="ps").start())
    dut.we_i.value, dut.wdata_i.value, dut.rst_i.value = 0, 0, 1
    await ClockCycles(dut.clk_i, 4)
    dut.rst_i.value = 0
    bad = []
    cocotb.start_soon(watch_held(dut, bad))

    t = await wait_locked(dut)
    await FallingEdge(dut.clk_i)
    assert not int(dut.array_rst_o.value)
    dut._log.info(f"first LOCKED at {t / 1e6:.2f} us")

    model = md.Mmcm()
    assert await period_ps(dut) == model.out_period_ps() == 10_000

    # the registers as configured read back as the model holds them, on
    # every bit the primitive defines (it reads x in reserved bits)
    defined = {md.CLKOUT0_REG1: (15, 0), md.CLKOUT0_REG2: (14, 0),
               md.CLKFBOUT_REG1: (15, 0), md.CLKFBOUT_REG2: (14, 0),
               md.DIVCLK_REG: (13, 0)}
    for addr, (hi, lo) in defined.items():
        got = await drp_read(dut, addr, 0)
        want = f"{model.regs[addr]:016b}"
        assert field(got, hi, lo) == field(want, hi, lo), \
            f"DRP 0x{addr:02x}: read {got}, model {want}"
    # reads with RST low left the clock running
    assert status(dut) & LOCKED

    for d, want_ps in ((10, 12_500), (8, 10_000), (10, 12_500)):
        t = await reprogram(dut, d)
        md.reprogram(model, d)
        got = await period_ps(dut)
        assert got == model.out_period_ps() == want_ps, f"/{d}: period {got} ps, model {model.out_period_ps()}"
        dut._log.info(f"/{d}: {got} ps, relocked {t / 1e6:.2f} us after RST")
        # what was written reads back
        r1 = await drp_read(dut, md.CLKOUT0_REG1, 0)
        assert field(r1, 11, 0) == f"{md.divider(d)[0]:016b}"[4:], r1
    assert not bad, f"array released in reset or unlocked at {bad[:5]} ps"


@cocotb.test()
async def test_go_while_busy(dut):
    """A second GO before DRDY is ignored: the first access completes and
    is the one whose data comes back (UG472 forbids a second DEN)."""
    cocotb.start_soon(Clock(dut.clk100_i, 10_000, unit="ps").start())
    cocotb.start_soon(Clock(dut.clk_i, CLK_PS, unit="ps").start())
    dut.we_i.value, dut.wdata_i.value, dut.rst_i.value = 0, 0, 1
    await ClockCycles(dut.clk_i, 4)
    dut.rst_i.value = 0
    await wait_locked(dut)
    dens = []

    async def count_den():
        while True:
            await RisingEdge(dut.clk_i)
            if int(dut.u_ctl.drp_den_o.value):
                dens.append(get_sim_time("ps"))

    cocotb.start_soon(count_den())
    await FallingEdge(dut.clk_i)
    dut.we_i.value, dut.wdata_i.value = 1, GO | (md.CLKFBOUT_REG1 << 16)
    await FallingEdge(dut.clk_i)
    dut.wdata_i.value = GO | (md.CLKOUT0_REG2 << 16)     # while busy, held
    while status(dut) & BUSY:
        await FallingEdge(dut.clk_i)
    dut.we_i.value = 0
    await ClockCycles(dut.clk_i, 4)
    got = bits(dut.rdata_o)[-16:]
    assert len(dens) == 1, f"{len(dens)} DEN pulses for one access (at {dens} ps)"
    assert field(got, 15, 0) == f"{md.Mmcm().regs[md.CLKFBOUT_REG1]:016b}", got
