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
    def __init__(self, dut, scale=2, lock_ps=4_000_000, offsets=(7_000,), seed=5):
        self.dut = dut
        self.scale = scale
        self.lock_ps = lock_ps
        self.offsets = list(offsets)
        self.rng = random.Random(seed)
        self.model = md.Mmcm()
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
