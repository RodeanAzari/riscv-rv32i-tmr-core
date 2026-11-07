"""Pulse synchronizer: every accepted pulse arrives exactly once, one cycle long.

Two unrelated clocks per run (the pairs of test_cdc_async_fifo.py), random
phase. The source tries to pulse at random, busy or not; a pulse counts as
accepted when src_busy_o was low (pulses while busy must be ignored). Inputs
are driven and outputs read on falling edges (src_busy_o changes only on
source edges, dst_pulse_o only on destination edges), so a pulse two
destination cycles long is seen twice and counted twice. Checked throughout:
  - delivered <= accepted <= delivered + 1: never lost, duplicated or
    stretched, never two in flight
  - !src_busy_o means everything accepted has been delivered
  - the round trip (pulse to !busy) takes at most 2 * (SYNC_STAGES + 1)
    cycles of each clock
The RTL's own invariant (P3, one toggle in flight) runs as well (--assert).
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

SYNC_STAGES = int(os.environ.get("CDC_SYNC_STAGES", "2"))
CLOCK_PAIRS = [(10_000, 13_700), (23_300, 10_000), (10_000, 10_000),
               (10_000, 10_030), (7_000, 31_000), (31_000, 7_000)]


@cocotb.test()
async def test_pulses(dut):
    clocks = []
    for i, (src_ps, dst_ps) in enumerate(CLOCK_PAIRS):
        rng = random.Random(500 + i)
        for c in clocks:
            c.cancel()
        dut.src_rst_i.value = 1
        dut.dst_rst_i.value = 1
        dut.src_pulse_i.value = 0
        clocks = [cocotb.start_soon(Clock(dut.src_clk_i, src_ps, unit="ps").start())]
        await Timer(rng.randrange(1, dst_ps), unit="ps")
        clocks.append(cocotb.start_soon(Clock(dut.dst_clk_i, dst_ps, unit="ps").start()))
        for _ in range(SYNC_STAGES + 2):
            await RisingEdge(dut.src_clk_i)
            await RisingEdge(dut.dst_clk_i)
        await FallingEdge(dut.src_clk_i)
        dut.src_rst_i.value = 0
        await FallingEdge(dut.dst_clk_i)
        dut.dst_rst_i.value = 0

        st = {"acc": 0, "del": 0, "ignored": 0, "done": False}
        bound_ps = 2 * (SYNC_STAGES + 1) * (src_ps + dst_ps)

        async def watch_dst():
            while not st["done"]:
                await FallingEdge(dut.dst_clk_i)
                if int(dut.dst_pulse_o.value):
                    st["del"] += 1
                assert st["del"] <= st["acc"] <= st["del"] + 1, st

        watcher = cocotb.start_soon(watch_dst())
        n, sent_at = 300, None
        p = rng.choice([0.1, 0.5, 1.0])
        while st["acc"] < n:
            await FallingEdge(dut.src_clk_i)
            busy = int(dut.src_busy_o.value)
            now = cocotb.utils.get_sim_time("ps")
            if not busy:
                assert st["acc"] == st["del"], f"not busy with a pulse undelivered: {st}"
                if sent_at is not None:
                    assert now - sent_at <= bound_ps, f"round trip {now - sent_at} ps"
                    sent_at = None
            want = rng.random() < p
            dut.src_pulse_i.value = int(want)
            await RisingEdge(dut.src_clk_i)
            dut.src_pulse_i.value = 0
            if want and not busy:
                st["acc"] += 1
                sent_at = now
            elif want:
                st["ignored"] += 1
        # let the last one arrive
        for _ in range(4 * (SYNC_STAGES + 1)):
            await FallingEdge(dut.src_clk_i)
            await FallingEdge(dut.dst_clk_i)
        assert st["del"] == st["acc"] == n, st
        assert int(dut.src_busy_o.value) == 0
        st["done"] = True
        await watcher
        if p > 0.4:
            assert st["ignored"] > 0, "no pulse was tried while busy"
        dut._log.info(f"{src_ps}/{dst_ps} ps: {n} pulses delivered once each, "
                      f"{st['ignored']} ignored while busy")
    for c in clocks:
        c.cancel()
