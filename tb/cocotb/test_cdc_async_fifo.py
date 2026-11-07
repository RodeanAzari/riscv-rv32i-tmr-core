"""Asynchronous FIFO: two unrelated clocks, scoreboard, latency, flushes.

Each test starts the two clocks itself, at its own periods and a random phase
between them, so the regression covers write clock faster, slower, equal
(shifted) and nearly equal (the edges drift through each other).

Inputs are driven, and outputs read, on falling edges: wr_full_o changes only
on a write-clock edge and rd_empty_o only on a read-clock edge, so what is
read half a period before an edge is what that edge acts on. The scoreboard
is a deque of the entries accepted so far, updated after the rising edge that
does the write or the pop, so at every falling edge it is the true content.
Checked there:
  - the head: !rd_empty_o means an entry exists, and rd_data_o is the oldest
  - full: !wr_full_o means fewer than DEPTH entries; wr_used_o >= the true
    occupancy (the writer may over-count, never under-count)
  - every entry comes out once, in order, with its data
The RTL's own invariants (FORMAL, --assert) run on every cycle as well.

Latency: a write into an empty FIFO shows on the read side SYNC_STAGES
read-clock edges after the write edge, and a pop from a full FIFO frees space
SYNC_STAGES write-clock edges later. A synchronizer one flop short fails it.

Flush: both resets rise together and each falls on its own clock edge,
SYNC_STAGES edges after the source drops (cdc_reset_sync's behaviour), in
the middle of a stream; the FIFO must then read empty and carry a new stream.

DEPTH comes from the port width; SYNC_STAGES from CDC_SYNC_STAGES (the
Makefile sets it for each build).
"""

from collections import deque
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

SYNC_STAGES = int(os.environ.get("CDC_SYNC_STAGES", "2"))

# (write period, read period) in ps: faster, slower, equal, nearly equal,
# far apart both ways
CLOCK_PAIRS = [(10_000, 13_700), (23_300, 10_000), (10_000, 10_000),
               (10_000, 10_030), (7_000, 31_000), (31_000, 7_000)]


def depth(dut):
    return 1 << (len(dut.wr_used_o) - 1)


_clocks = []


def stop_clocks():
    while _clocks:
        _clocks.pop().cancel()


async def start_clocks(dut, wr_ps, rd_ps, rng):
    """Stop any running clocks, start both (in reset), release the resets."""
    stop_clocks()
    dut.wr_rst_i.value = 1
    dut.rd_rst_i.value = 1
    dut.wr_en_i.value = 0
    dut.rd_en_i.value = 0
    dut.wr_data_i.value = 0
    _clocks.append(cocotb.start_soon(Clock(dut.wr_clk_i, wr_ps, unit="ps").start()))
    await Timer(rng.randrange(1, rd_ps), unit="ps")       # random phase
    _clocks.append(cocotb.start_soon(Clock(dut.rd_clk_i, rd_ps, unit="ps").start()))
    await release_resets(dut)


async def release_resets(dut):
    """Both resets are high: hold them, then release each as cdc_reset_sync
    would -- on its own clock's edge, SYNC_STAGES edges after the source falls
    (here: after both clocks have had SYNC_STAGES + 1 edges in reset)."""
    async def release(clk, rst):
        for _ in range(SYNC_STAGES + 1):
            await RisingEdge(clk)
        await FallingEdge(clk)
        rst.value = 0
    a = cocotb.start_soon(release(dut.wr_clk_i, dut.wr_rst_i))
    b = cocotb.start_soon(release(dut.rd_clk_i, dut.rd_rst_i))
    await a
    await b


class Bench:
    """Producer and consumer coroutines around one scoreboard."""

    def __init__(self, dut, rng):
        self.dut = dut
        self.rng = rng
        self.depth = depth(dut)
        self.width = len(dut.wr_data_i)
        self.model = deque()      # true content, oldest first
        self.sent = 0
        self.got = 0
        self.full_seen = 0
        self.empty_seen = 0
        self.stop = False

    async def producer(self, n, p_write):
        dut, rng = self.dut, self.rng
        while self.sent < n and not self.stop:
            await FallingEdge(dut.wr_clk_i)
            occ = len(self.model)
            used = int(dut.wr_used_o.value)
            full = int(dut.wr_full_o.value)
            assert used >= occ, f"wr_used_o {used} under the true occupancy {occ}"
            assert used <= self.depth
            if not full:
                assert occ < self.depth, f"not full with {occ} of {self.depth} entries"
            else:
                self.full_seen += 1
            want = rng.random() < p_write()
            data = rng.getrandbits(self.width)
            dut.wr_en_i.value = int(want)
            dut.wr_data_i.value = data
            await RisingEdge(dut.wr_clk_i)
            if want and not full:
                self.model.append(data)
                self.sent += 1
        await FallingEdge(dut.wr_clk_i)
        dut.wr_en_i.value = 0

    async def consumer(self, n, p_read):
        dut, rng = self.dut, self.rng
        while self.got < n and not self.stop:
            await FallingEdge(dut.rd_clk_i)
            empty = int(dut.rd_empty_o.value)
            if not empty:
                assert self.model, "rd_empty_o low with nothing written"
                data = int(dut.rd_data_o.value)
                assert data == self.model[0], (
                    f"entry {self.got}: read {data:#x}, expected {self.model[0]:#x}")
            else:
                self.empty_seen += 1
            want = rng.random() < p_read()
            dut.rd_en_i.value = int(want)
            await RisingEdge(dut.rd_clk_i)
            if want and not empty:
                self.model.popleft()
                self.got += 1
        await FallingEdge(dut.rd_clk_i)
        dut.rd_en_i.value = 0


def bursty(rng, period=200):
    """A probability that switches between busy and idle phases, so the FIFO
    spends time both full and empty."""
    state = {"left": 0, "p": 0.5}

    def p():
        if state["left"] == 0:
            state["left"] = rng.randrange(1, period)
            state["p"] = rng.choice([0.05, 0.5, 0.95, 1.0])
        state["left"] -= 1
        return state["p"]
    return p


@cocotb.test()
async def test_stream(dut):
    """Random bursty streams at every clock pair; each entry once, in order."""
    for i, (wr_ps, rd_ps) in enumerate(CLOCK_PAIRS):
        rng = random.Random(100 + i)
        await start_clocks(dut, wr_ps, rd_ps, rng)
        bench = Bench(dut, rng)
        n = 3000
        p = cocotb.start_soon(bench.producer(n, bursty(rng)))
        c = cocotb.start_soon(bench.consumer(n, bursty(rng)))
        await p
        await c
        assert not bench.model, f"{len(bench.model)} entries never came out"
        assert bench.full_seen > 0 and bench.empty_seen > 0, (
            f"stream at {wr_ps}/{rd_ps} ps never reached full ({bench.full_seen}) "
            f"or empty ({bench.empty_seen})")
        dut._log.info(f"{wr_ps}/{rd_ps} ps: {n} entries, full on {bench.full_seen} "
                      f"write cycles, empty on {bench.empty_seen} read cycles")
        # back into reset for the next pair; the clocks are restarted
        dut.wr_rst_i.value = 1
        dut.rd_rst_i.value = 1
        await Timer(100_000, unit="ps")


async def edges_until(clk, cond, limit=50):
    """Rising edges of clk, from now, until cond() holds at the falling edge
    after one; returns at that falling edge."""
    n = 0
    while True:
        await RisingEdge(clk)
        n += 1
        await FallingEdge(clk)
        if cond():
            return n
        assert n < limit, "never happened"


@cocotb.test()
async def test_latency(dut):
    """A write reaches the reader, and a pop reaches the writer, after exactly
    SYNC_STAGES edges of the receiving clock -- with the edges apart (equal
    periods, half a period out of phase), so no edge is shared."""
    rng = random.Random(7)
    dut.wr_rst_i.value = 1
    dut.rd_rst_i.value = 1
    dut.wr_en_i.value = 0
    dut.rd_en_i.value = 0
    dut.wr_data_i.value = 0
    stop_clocks()
    _clocks.append(cocotb.start_soon(Clock(dut.wr_clk_i, 10_000, unit="ps").start()))
    await Timer(2_500, unit="ps")                  # quarter period apart
    _clocks.append(cocotb.start_soon(Clock(dut.rd_clk_i, 10_000, unit="ps").start()))
    await release_resets(dut)
    d = depth(dut)

    for _ in range(5):
        # write one entry into the empty FIFO
        await FallingEdge(dut.wr_clk_i)
        assert int(dut.rd_empty_o.value) == 1
        dut.wr_en_i.value = 1
        dut.wr_data_i.value = rng.getrandbits(len(dut.wr_data_i))
        await RisingEdge(dut.wr_clk_i)            # the write edge
        dut.wr_en_i.value = 0
        n = await edges_until(dut.rd_clk_i, lambda: int(dut.rd_empty_o.value) == 0)
        assert n == SYNC_STAGES, f"write visible after {n} read edges, expected {SYNC_STAGES}"
        # pop it
        dut.rd_en_i.value = 1
        await RisingEdge(dut.rd_clk_i)
        dut.rd_en_i.value = 0
        await edges_until(dut.wr_clk_i, lambda: int(dut.wr_used_o.value) == 0)

    # fill, then one pop: space returns after SYNC_STAGES write edges
    for _ in range(d):
        await FallingEdge(dut.wr_clk_i)
        dut.wr_en_i.value = 1
        await RisingEdge(dut.wr_clk_i)
    await FallingEdge(dut.wr_clk_i)
    dut.wr_en_i.value = 0
    assert int(dut.wr_full_o.value) == 1
    await FallingEdge(dut.rd_clk_i)
    dut.rd_en_i.value = 1
    await RisingEdge(dut.rd_clk_i)                 # the pop edge
    dut.rd_en_i.value = 0
    n = await edges_until(dut.wr_clk_i, lambda: int(dut.wr_full_o.value) == 0)
    assert n == SYNC_STAGES, f"space visible after {n} write edges, expected {SYNC_STAGES}"


@cocotb.test()
async def test_full_ignores_writes(dut):
    """Writes while full are dropped, and the entries already held survive."""
    rng = random.Random(11)
    await start_clocks(dut, 10_000, 17_300, rng)
    d = depth(dut)
    data = [rng.getrandbits(len(dut.wr_data_i)) for _ in range(d)]
    for v in data:
        await FallingEdge(dut.wr_clk_i)
        dut.wr_en_i.value = 1
        dut.wr_data_i.value = v
        await RisingEdge(dut.wr_clk_i)
    for _ in range(20):                            # hammer the full FIFO
        await FallingEdge(dut.wr_clk_i)
        assert int(dut.wr_full_o.value) == 1
        dut.wr_data_i.value = rng.getrandbits(len(dut.wr_data_i))
        await RisingEdge(dut.wr_clk_i)
    await FallingEdge(dut.wr_clk_i)
    dut.wr_en_i.value = 0
    out = []
    while len(out) < d + 1:
        await FallingEdge(dut.rd_clk_i)
        if int(dut.rd_empty_o.value):
            if len(out) == d:
                break
            dut.rd_en_i.value = 0
            continue
        out.append(int(dut.rd_data_o.value))
        dut.rd_en_i.value = 1
        await RisingEdge(dut.rd_clk_i)
    dut.rd_en_i.value = 0
    assert out == data, f"read {out}, wrote {data}"


@cocotb.test()
async def test_flush(dut):
    """Flush mid-stream, at several clock pairs and moments: afterwards the FIFO
    is empty on both sides, stays so, and carries a new stream."""
    for i, (wr_ps, rd_ps) in enumerate(CLOCK_PAIRS):
        rng = random.Random(300 + i)
        await start_clocks(dut, wr_ps, rd_ps, rng)
        for _ in range(4):
            bench = Bench(dut, rng)
            p = cocotb.start_soon(bench.producer(10**9, bursty(rng, 50)))
            c = cocotb.start_soon(bench.consumer(10**9, bursty(rng, 50)))
            await Timer(rng.randrange(50, 400) * max(wr_ps, rd_ps), unit="ps")
            # the flush source rises at an arbitrary moment: both resets at once
            bench.stop = True
            dut.wr_rst_i.value = 1
            dut.rd_rst_i.value = 1
            await p
            await c
            dut.wr_en_i.value = 0
            dut.rd_en_i.value = 0
            await Timer(rng.randrange(1, 4) * max(wr_ps, rd_ps), unit="ps")
            await release_resets(dut)
            # empty on both sides, and no stale pointer arrives later
            for _ in range(4 * SYNC_STAGES):
                await FallingEdge(dut.rd_clk_i)
                assert int(dut.rd_empty_o.value) == 1, "entries after a flush"
            await FallingEdge(dut.wr_clk_i)
            assert int(dut.wr_used_o.value) == 0 and int(dut.wr_full_o.value) == 0
            # and a fresh stream goes through
            bench = Bench(dut, rng)
            p = cocotb.start_soon(bench.producer(200, bursty(rng, 50)))
            c = cocotb.start_soon(bench.consumer(200, bursty(rng, 50)))
            await p
            await c
            assert not bench.model
        dut.wr_rst_i.value = 1
        dut.rd_rst_i.value = 1
        await Timer(100_000, unit="ps")
