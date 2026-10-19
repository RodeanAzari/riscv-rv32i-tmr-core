"""Systolic array: GEMMs against the golden model, values and timing.

The test plays the parts that come later in hardware (Phase G/H): the feeder,
which splits a job into ROWS x COLS tiles of W, pads the edges with zeros and
streams A row by row, and the output buffer, which sums the tiles along K.
Every result is checked against gemm_model.gemm (sw/model/gemm_model.py, in
turn checked against the model's cycle-level array), and every row's results
must arrive exactly LATENCY = ROWS + COLS - 1 edges after the row went in.

Weights load the way the double buffering allows: the next tile's rows shift
into the shadow registers while the current tile streams, as soon as the
previous swap has reached the last PE; the swap rides on the current tile's
last row when the load has finished by then, otherwise on an idle cycle
after it. Jobs run back to back without a reset, so tile and job boundaries
are exercised hundreds of times. The array shape comes from the port widths,
so the same test runs every parameterisation in the regression.
"""

from pathlib import Path
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import gemm_model  # noqa: E402

CLK_PERIOD_NS = 10
DATA_W, ACC_W = 8, 32


def pack(values, width):
    word = 0
    for i, v in enumerate(values):
        word |= (int(v) & ((1 << width) - 1)) << (width * i)
    return word


def unpack_signed(word, width, n):
    out = []
    for i in range(n):
        v = (word >> (width * i)) & ((1 << width) - 1)
        out.append(v - (1 << width) if v >> (width - 1) else v)
    return out


def schedule(jobs, rows, cols):
    """Per-cycle inputs for a list of (A, W) jobs, and for each valid input
    row the (job, n0, m) its results belong to."""
    cyc = {}

    def at(t):
        return cyc.setdefault(t, {"valid": 0, "swap": 0, "a": [0] * rows, "shift": 0, "w": [0] * cols})

    owners = []
    last_swap = -(rows + cols)      # loads may start at once
    row_t = 0                       # next free input-row cycle
    prev_last_row = None            # cycle of the previous tile's last row
    for j, (a, w) in enumerate(jobs):
        m, k = a.shape
        n = w.shape[1]
        for n0 in range(0, n, cols):
            for k0 in range(0, k, rows):
                tile = np.zeros((rows, cols), dtype=np.int64)
                kk, nn = min(rows, k - k0), min(cols, n - n0)
                tile[:kk, :nn] = w[k0:k0 + kk, n0:n0 + nn]
                # Shift this tile into the shadows, bottom row first, once
                # the previous swap has passed the last PE.
                ls = max(last_swap + rows + cols - 1, 0)
                for i in range(rows):
                    e = at(ls + i)
                    e["shift"] = 1
                    e["w"] = tile[rows - 1 - i].tolist()
                # Swap after the previous tile's last row if the load is in
                # by then, else on an idle cycle once it is.
                if prev_last_row is not None and prev_last_row >= ls + rows:
                    sc = prev_last_row
                else:
                    sc = max(row_t, ls + rows)
                at(sc)["swap"] = 1
                last_swap = sc
                row_t = max(row_t, sc + 1)
                for mm in range(m):
                    e = at(row_t)
                    e["valid"] = 1
                    e["a"] = [int(a[mm, k0 + r]) if r < kk else 0 for r in range(rows)]
                    owners.append((j, n0, mm, row_t))
                    row_t += 1
                prev_last_row = row_t - 1
    length = max(cyc) + 1
    return [at(t) for t in range(length)], owners


async def run_jobs(dut, jobs, rows, cols):
    """Drive the jobs through the array; return per-job results and cycles."""
    cycles, owners = schedule(jobs, rows, cols)
    latency = rows + cols - 1
    results = [np.zeros((a.shape[0], w.shape[1]), dtype=np.int64) for a, w in jobs]
    outs = []
    for t in range(len(cycles) + latency):
        e = cycles[t] if t < len(cycles) else None
        dut.valid_i.value = e["valid"] if e else 0
        dut.swap_i.value = e["swap"] if e else 0
        dut.a_i.value = pack(e["a"], DATA_W) if e else 0
        dut.w_shift_i.value = e["shift"] if e else 0
        dut.w_i.value = pack(e["w"], DATA_W) if e else 0
        await FallingEdge(dut.clk_i)
        if dut.valid_o.value:
            outs.append((t, unpack_signed(int(dut.c_o.value), ACC_W, cols)))
    assert len(outs) == len(owners), f"{len(outs)} result rows for {len(owners)} input rows"
    for (j, n0, mm, t_in), (t_out, vec) in zip(owners, outs):
        assert t_out - t_in == latency - 1, \
            f"row entering at cycle {t_in} left at {t_out}: latency {t_out - t_in + 1}, expected {latency}"
        n = jobs[j][1].shape[1]
        for c in range(min(cols, n - n0)):
            results[j][mm, n0 + c] += vec[c]
    return [gemm_model.wrap32(r) for r in results], len(cycles) + latency


async def start(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    dut.valid_i.value = 0
    dut.swap_i.value = 0
    dut.a_i.value = 0
    dut.w_shift_i.value = 0
    dut.w_i.value = 0
    dut.rst_i.value = 1
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0
    rows = len(dut.a_i) // DATA_W
    cols = len(dut.c_o) // ACC_W
    return rows, cols


async def check(dut, jobs, rows, cols, label):
    got, cycles = await run_jobs(dut, jobs, rows, cols)
    for (a, w), g in zip(jobs, got):
        want = gemm_model.gemm(a, w)
        if not np.array_equal(g, want):
            bad = np.argwhere(g != want)[0]
            raise AssertionError(f"{label}: {a.shape} x {w.shape}, C{tuple(bad)} = {g[tuple(bad)]}, "
                                 f"model {want[tuple(bad)]}")
    macs = sum(a.shape[0] * a.shape[1] * w.shape[1] for a, w in jobs)
    dut._log.info("%s: %d GEMMs match the golden model, %d cycles, %.1f%% of PE-cycles useful",
                  label, len(jobs), cycles, 100.0 * macs / (rows * cols * cycles))


@cocotb.test()
async def test_random(dut):
    """Random shapes, multiples of the array and not, back to back."""
    rows, cols = await start(dut)
    rng = np.random.default_rng(2)
    limit = 3 * max(rows, cols)
    jobs = []
    for _ in range(2000 if rows * cols <= 64 else 1000):
        m, k, n = rng.integers(1, limit + 1, size=3)
        jobs.append((rng.integers(-128, 128, size=(m, k)), rng.integers(-128, 128, size=(k, n))))
    await check(dut, jobs, rows, cols, f"{rows}x{cols} random")


@cocotb.test()
async def test_shapes(dut):
    """Shapes at the tile edges: one row, one column, exactly one tile, one
    past it, one short of it, and several tiles each way."""
    rows, cols = await start(dut)
    rng = random.Random(3)
    shapes = [(1, 1, 1), (1, rows, cols), (rows, rows, cols), (rows + 1, rows + 1, cols + 1),
              (1, rows - 1 or 1, cols - 1 or 1), (2 * rows, 3 * rows, 2 * cols),
              (3, 2 * rows + 1, 1), (1, 1, 2 * cols + 1), (5 * rows, rows, cols)]
    jobs = []
    for m, k, n in shapes:
        a = np.array([[rng.randint(-128, 127) for _ in range(k)] for _ in range(m)])
        w = np.array([[rng.randint(-128, 127) for _ in range(n)] for _ in range(k)])
        jobs.append((a, w))
    await check(dut, jobs, rows, cols, f"{rows}x{cols} edge shapes")


@cocotb.test()
async def test_saturation(dut):
    """The largest products of each sign in every term, so every partial sum
    is at its extreme, and alternating extremes."""
    rows, cols = await start(dut)
    jobs = []
    for av, wv in ((-128, -128), (-128, 127), (127, 127), (127, -128)):
        k = 3 * rows + 1
        jobs.append((np.full((2 * rows, k), av), np.full((k, 2 * cols + 1), wv)))
    k = 2 * rows
    alt = lambda m, n: np.array([[(-128 if (i + j) % 2 else 127) for j in range(n)] for i in range(m)])
    jobs.append((alt(rows + 2, k), alt(k, cols + 3)))
    await check(dut, jobs, rows, cols, f"{rows}x{cols} saturation")
