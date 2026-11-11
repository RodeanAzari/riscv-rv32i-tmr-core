"""The array MMCM at the SoC's ports (soc.sv aclk_* and drp_*), for the SoC
tests built with ARRAY_CDC: a stand-in for arty_a7_top.sv's MMCME2_ADV,
driving clk_array_i.

The registers and the rules a DRP master must keep are the golden model's
(sw/model/mmcm_drp.py: a write with RST low, or a second DEN before DRDY,
fails the test); its picture of the primitive is checked against AMD's own
model by make aclk-check. Around it, what the SoC must survive:
  - DRDY a random 1-6 DCLK cycles after DEN;
  - RST stops CLKOUT0 at once and drops LOCKED;
  - after RST falls, a few runt pulses at random (UG472: the output is not
    guaranteed before LOCKED), then LOCKED and a clean clock at the period
    the registers give, from a phase the test chooses (on the board the
    two MMCMs are deskewed and their edges coincide; in simulation every
    phase is fair game).
Every period is the board's times SCALE (the simulated core runs at 50 MHz,
half the board's 100).

segments records each clean stretch of clock: (first rising edge, period),
for the tests to find the clock a job ran on. unsafe() is True from RST
until the clean clock starts, when the SoC must hold the array in reset.
"""

from pathlib import Path
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb.utils import get_sim_time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import mmcm_drp as md  # noqa: E402


class MmcmBfm:
    def __init__(self, dut, scale=2, lock_ps=4_000_000, offsets=(7_000,), seed=5,
                 out0=md.OUT0_DIV):
        self.dut = dut
        self.scale = scale
        self.lock_ps = lock_ps
        self.offsets = list(offsets)
        self.rng = random.Random(seed)
        self.model = md.Mmcm(out0=out0)   # CLKOUT0's divide at power-up
        self.model.rst = False
        self.segments: list[tuple[int, int]] = []
        self.clock = None
        self.relock = None
        self.locking = True
        self.writes: list[tuple[int, int]] = []

    def unsafe(self) -> bool:
        return self.locking

    def start(self):
        d = self.dut
        d.clk_array_i.value = 0
        d.aclk_locked_i.value = 0
        d.drp_do_i.value = 0
        d.drp_drdy_i.value = 0
        self.relock = cocotb.start_soon(self._lock(runts=False))
        cocotb.start_soon(self._rst())
        cocotb.start_soon(self._drp())

    async def _lock(self, runts):
        d = self.dut
        t_end = get_sim_time("ps") + self.lock_ps
        if runts:
            for _ in range(self.rng.randint(2, 6)):
                await Timer(self.rng.randint(1_000, 40_000), unit="ps")
                d.clk_array_i.value = 1
                await Timer(self.rng.randint(300, 3_000), unit="ps")
                d.clk_array_i.value = 0
        rest = t_end - get_sim_time("ps")
        offset = self.offsets[len(self.segments) % len(self.offsets)]
        await Timer(max(rest, 0) + offset, unit="ps")
        period = self.model.out_period_ps() * self.scale
        self.clock = Clock(d.clk_array_i, period, unit="ps")
        self.clock.start()
        self.segments.append((get_sim_time("ps"), period))
        d.aclk_locked_i.value = 1
        self.locking = False

    async def _rst(self):
        d = self.dut
        while True:
            await d.aclk_rst_o.value_change
            if int(d.aclk_rst_o.value):
                self.model.rst = True
                self.locking = True
                if self.relock is not None:
                    self.relock.cancel()
                    self.relock = None
                if self.clock is not None:
                    self.clock.stop()
                    self.clock = None
                d.clk_array_i.value = 0
                d.aclk_locked_i.value = 0
            elif self.model.rst:            # a fall from RST, not X to 0
                self.model.rst = False
                self.relock = cocotb.start_soon(self._lock(runts=True))

    async def _drp(self):
        d = self.dut
        while True:
            await RisingEdge(d.clk_i)
            if not int(d.drp_den_o.value):
                continue
            addr, we, di = int(d.drp_daddr_o.value), int(d.drp_dwe_o.value), int(d.drp_di_o.value)
            dout = self.model.access(addr, bool(we), di)       # raises on a broken rule
            if we:
                self.writes.append((addr, di))
            self.model.busy = True
            for _ in range(self.rng.randint(1, 6)):
                await RisingEdge(d.clk_i)
                if int(d.drp_den_o.value):
                    raise md.DrpError("DEN before DRDY returned")
            d.drp_do_i.value = dout
            d.drp_drdy_i.value = 1
            self.model.busy = False
            await RisingEdge(d.clk_i)
            d.drp_drdy_i.value = 0
            d.drp_do_i.value = 0


ARRAY_DIV = 10      # /10: 25 ns here against the core's 20, 80 MHz on the board


def start_array_clock(dut):
    """For the SoC tests that leave the ACLK register alone: with ARRAY_CDC,
    the array MMCM comes up at /ARRAY_DIV instead of the board's /8, so the
    test runs with clk_array at another frequency than the core (buildplan
    Phase H, slice 5), at a phase that drifts against the core's edges. A
    watcher fails the test unless the array side then leaves reset and its
    clock runs at that period. Without ARRAY_CDC, nothing."""
    if not int(dut.ARRAY_CDC.value):
        return None
    bfm = MmcmBfm(dut, out0=ARRAY_DIV, offsets=(7_000,))
    bfm.start()
    cocotb.start_soon(_array_runs(dut, bfm))
    return bfm


async def _array_runs(dut, bfm):
    want = md.Mmcm(out0=ARRAY_DIV).out_period_ps() * bfm.scale
    while not bfm.segments:
        await RisingEdge(dut.clk_array_i)
    for _ in range(20):                      # the reset synchronizer's edges
        await RisingEdge(dut.clk_array_i)
    assert not int(dut.u_accel.rst_a.value), "array side still in reset after LOCKED"
    t0 = get_sim_time("ps")
    for _ in range(10):
        await RisingEdge(dut.clk_array_i)
    period = (get_sim_time("ps") - t0) / 10
    assert period == want, f"clk_array at {period} ps, want {want}"
    dut._log.info(f"clk_array_i at {period:.0f} ps, the array side out of reset")
