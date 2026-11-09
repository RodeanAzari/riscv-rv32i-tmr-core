"""The GEMM accelerator (rtl/accel/gemm_accel.sv) against its golden model.

sw/model/accel_model.py is the reference: every buffer write and register
write goes to both, the RTL over its two bus ports (AXI4-Lite registers,
AXI4 buffers, every VALID and READY randomly delayed), and after each job
the whole C buffer is read back and compared byte for byte with the model's.

What matters and why:
  - a job computes C = A @ W for any shape that fits, whatever garbage sits
    in the padding of A's and W's lines: software lays matrices out with
    padded rows and must not have to clear the padding;
  - C's padding words come out 0 and C lines past M * NT are untouched:
    software can keep data there between jobs;
  - CYCLES equals the model's count exactly: the schedule is a contract,
    and utilization numbers in the README come from it;
  - a refused shape (a dimension 0, a matrix over its buffer) writes
    nothing and says ERROR, at each buffer's limit alone;
  - while BUSY the buffers are the engine's: a bus access waits for the
    job to end and then sees its result; START while busy changes nothing;
  - sums along K wrap in INT32 like the model (saturation inputs).

Built with ARRAY_CDC = 1 (gemm_accel*_cdc), the array runs on clk_array_i
at another period and phase, and the reference for each job is
sw/model/accel_cdc_model.py's stream_job() at those clocks: the bench
records the core edge where the job starts (busy_o rising) and an array
edge, so the model runs at the very phase the RTL saw, and CYCLES must
match exactly, as must every byte of C. Each test picks its array clock
from ARRAY_CLOCKS (logged); test_clock_ratios runs them all, edge-sharing
ones included. With ARRAY_CDC = 0 the same tests show clk_array_i changes
nothing.

The weight-transform hook (wx_*, contract in gemm_accel_seq.sv): the bench
drives wx_w_i at every falling edge of clk_i from that cycle's wx_w_o, which
is how a combinational hook behaves (the beat is stable from one rising edge
to the next, where it is taken). Built with WX_EXT = 1 (*_wx) every test
runs through it, identity unless one sets a transform; built without, the
bench drives garbage there, which must change nothing. test_weight_order
checks every beat against weight_beats(), the documented load order (P5's
request 0010); test_weight_transform, C of the transformed W (0009).
"""

import os
from pathlib import Path
import random
import sys

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

from axil import OKAY, SLVERR, axi_read, axi_write

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import accel_model as am  # noqa: E402
import accel_cdc_model as acm  # noqa: E402

CLK_PERIOD_NS = 10
CORE_PS = CLK_PERIOD_NS * 1000
# clk_array_i: (period, offset of its first rising edge from the core's), ps.
# Offset 0 shares edges with the core clock (every one at 10 ns, every
# other at 20 ns); 10.03 ns drifts through every phase; at 97 ns the input
# FIFO fills while the weights load.
ARRAY_CLOCKS = [(10_000, 0), (10_000, 5_000), (10_030, 1_234), (13_700, 3_000),
                (7_300, 1_000), (31_000, 17_000), (3_100, 700), (20_000, 0),
                (97_000, 41_000)]
# test_reset_slow_array: an array clock whose first edge after a reset comes
# later than a START written at once (four register writes).
SLOW_RESET_CLOCK = (403_000, 41_000)
_clocks = []      # running clock tasks
_cdc = {}         # array clock: period "ta", a rising edge "a0"; "rises" of busy_o
MAX_BEATS = 16
# the hook: "fn" maps wx_w_o (an int, lane j at bits 8j) to wx_w_i, None is
# the identity; "log" records start pulses and beats when it is a list
_hook = {"fn": None, "log": None}


def shape_of(dut):
    rows = int(dut.ROWS.value)
    cols = int(dut.COLS.value)
    buf = int(dut.BUF_BYTES.value)
    return rows, cols, buf


class Bench:
    def __init__(self, dut, rng):
        self.dut = dut
        self.rng = rng
        self.rows, self.cols, self.buf = shape_of(dut)
        self.model = am.Accel(self.rows, self.cols, self.buf)
        self.np_rng = np.random.default_rng(rng.randrange(2**32))
        self.delay = 0.3   # chance a VALID or READY waits a cycle
        self.cdc = bool(int(dut.ARRAY_CDC.value))

    def wait(self):
        return self.rng.random() < self.delay

    # ---- AXI4 buffer port: bursts, one at a time ----
    async def burst_write(self, addr, words):
        d = self.dut
        d.d_awaddr_i.value = addr
        d.d_awlen_i.value = len(words) - 1
        d.d_awsize_i.value = 2
        d.d_awburst_i.value = 1
        for _ in range(200_000):
            v = not self.wait()
            d.d_awvalid_i.value = int(v)
            hs = v and d.d_awready_o.value
            await FallingEdge(d.clk_i)
            if hs:
                break
        else:
            raise AssertionError("AW never accepted")
        d.d_awvalid_i.value = 0
        i = cyc = 0
        while i < len(words):
            v = not self.wait()
            d.d_wvalid_i.value = int(v)
            d.d_wdata_i.value = words[i]
            d.d_wstrb_i.value = 0xF
            d.d_wlast_i.value = int(i == len(words) - 1)
            hs = v and d.d_wready_o.value
            assert not d.d_bvalid_o.value, "BVALID before WLAST"
            await FallingEdge(d.clk_i)
            if hs:
                i += 1
            cyc += 1
            assert cyc < 200_000, "W never accepted"
        d.d_wvalid_i.value = 0
        cyc = 0
        while True:
            r = not self.wait()
            d.d_bready_i.value = int(r)
            if d.d_bvalid_o.value and r:
                assert int(d.d_bresp_o.value) == OKAY
                await FallingEdge(d.clk_i)
                d.d_bready_i.value = 0
                return
            await FallingEdge(d.clk_i)
            cyc += 1
            assert cyc < 200_000, "no write response"

    async def burst_read(self, addr, beats):
        d = self.dut
        d.d_araddr_i.value = addr
        d.d_arlen_i.value = beats - 1
        d.d_arsize_i.value = 2
        d.d_arburst_i.value = 1
        for _ in range(200_000):
            v = not self.wait()
            d.d_arvalid_i.value = int(v)
            hs = v and d.d_arready_o.value
            await FallingEdge(d.clk_i)
            if hs:
                break
        else:
            raise AssertionError("AR never accepted")
        d.d_arvalid_i.value = 0
        out = []
        cyc = 0
        while len(out) < beats:
            r = not self.wait()
            d.d_rready_i.value = int(r)
            if d.d_rvalid_o.value and r:
                assert int(d.d_rresp_o.value) == OKAY
                assert int(d.d_rlast_o.value) == (len(out) == beats - 1), "RLAST"
                out.append(int(d.d_rdata_o.value))
            await FallingEdge(d.clk_i)
            cyc += 1
            assert cyc < 200_000, "no read data"
        d.d_rready_i.value = 0
        return out

    async def write_bytes(self, off, data):
        """Bytes to the buffers at a word-aligned offset, padded to words."""
        data = bytes(data) + bytes(-len(data) % 4)
        self.model.buf_write(off, data)
        words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
        i = 0
        while i < len(words):
            n = min(self.rng.randint(1, MAX_BEATS), len(words) - i)
            await self.burst_write(off + 4 * i, words[i:i + n])
            i += n

    async def read_bytes(self, off, length):
        words = []
        while 4 * len(words) < length:
            n = min(self.rng.randint(1, MAX_BEATS), (length - 4 * len(words) + 3) // 4)
            words += await self.burst_read(off + 4 * len(words), n)
        return b"".join(w.to_bytes(4, "little") for w in words)[:length]

    # ---- registers ----
    async def reg_write(self, off, val):
        self.model.reg_write(off, val)
        assert await axi_write(self.dut, off, val) == OKAY

    async def reg_read(self, off):
        val, resp = await axi_read(self.dut, off)
        assert resp == OKAY
        return val

    async def wait_idle(self):
        for _ in range(100_000):
            st = await self.reg_read(am.REG_STATUS)
            if not st & am.ST_BUSY:
                return st
        raise AssertionError("job never finished")

    # ---- a job ----
    async def load(self, a, w, garbage=True):
        r, c = self.rows, self.cols
        pa, pw = bytearray(am.pack_a(a, r)), bytearray(am.pack_w(w, c))
        if garbage:
            m, k = a.shape
            n = w.shape[1]
            ka, nw = am.ceil_div(k, r) * r, am.ceil_div(n, c) * c
            for mm in range(m):
                for j in range(k, ka):
                    pa[mm * ka + j] = self.rng.randrange(256)
            for kk in range(k):
                for j in range(n, nw):
                    pw[kk * nw + j] = self.rng.randrange(256)
        await self.write_bytes(0, pa)
        await self.write_bytes(self.buf, pw)

    async def start(self, m, k, n):
        await self.reg_write(am.REG_M, m)
        await self.reg_write(am.REG_K, k)
        await self.reg_write(am.REG_N, n)
        if not self.cdc:
            await self.reg_write(am.REG_CTRL, am.CTRL_START)
            return
        # the model runs the job at the phase between the core edge that
        # took START and the array's edges
        n0 = len(_cdc["rises"])
        assert await axi_write(self.dut, am.REG_CTRL, am.CTRL_START) == OKAY
        for _ in range(10):
            if len(_cdc["rises"]) > n0:
                break
            await RisingEdge(self.dut.clk_i)
        assert len(_cdc["rises"]) == n0 + 1, "START did not start one job"
        e0 = _cdc["rises"][n0]
        phase = (_cdc["a0"] - e0) % _cdc["ta"]
        acm.stream_job(self.model, CORE_PS, _cdc["ta"], phase,
                       in_depth=int(self.dut.ARRAY_IN_DEPTH.value),
                       out_depth=int(self.dut.ARRAY_OUT_DEPTH.value))

    async def check(self, label):
        """Registers, then the whole C buffer, against the model."""
        st = await self.wait_idle()
        assert st == self.model.status, f"{label}: STATUS {st}, model {self.model.status}"
        for off in (am.REG_M, am.REG_K, am.REG_N, am.REG_CYCLES):
            got = await self.reg_read(off)
            want = self.model.reg_read(off)
            assert got == want, f"{label}: reg {off:#x} = {got}, model {want}"
        got = await self.read_bytes(2 * self.buf, self.buf)
        if got != bytes(self.model.c):
            g = np.frombuffer(got, dtype="<i4")
            w = np.frombuffer(bytes(self.model.c), dtype="<i4")
            bad = np.nonzero(g != w)[0]
            raise AssertionError(f"{label}: C differs at {len(bad)} words, first word {bad[0]}: "
                                 f"{g[bad[0]]} vs model {w[bad[0]]}")

    async def fill_c(self):
        await self.write_bytes(2 * self.buf, self.np_rng.integers(0, 256, self.buf, dtype=np.uint8))

    def i8(self, *shape):
        return self.np_rng.integers(-128, 128, size=shape)

    def fits(self, m, k, n):
        kt, nt = am.ceil_div(k, self.rows), am.ceil_div(n, self.cols)
        return (m * kt <= self.buf // self.rows and k * nt <= self.buf // self.cols
                and m * nt <= self.buf // (4 * self.cols))


def rng_for(dut):
    seed = int(os.environ.get("SEED", "1"))
    dut._log.info(f"SEED={seed}")
    return random.Random(seed)


async def watch_busy(dut, rises):
    while True:
        await RisingEdge(dut.u_seq.busy_o)
        rises.append(get_sim_time("ps"))


async def drive_hook(dut, rng):
    """At each falling edge of clk_i: wx_w_i from this cycle's beat, and the
    record, if one is kept."""
    ext = bool(int(dut.WX_EXT.value))
    cols = int(dut.COLS.value)
    while True:
        await FallingEdge(dut.clk_i)
        w = int(dut.wx_w_o.value)
        if ext:
            dut.wx_w_i.value = w if _hook["fn"] is None else _hook["fn"](w)
        else:
            dut.wx_w_i.value = rng.getrandbits(8 * cols)
        log = _hook["log"]
        if log is not None:
            if int(dut.wx_start_o.value):
                log.append("start")
            if int(dut.wx_valid_o.value):
                pad = int(dut.wx_pad_o.value)
                log.append((int(dut.wx_kt_o.value), int(dut.wx_nt_o.value), int(dut.wx_row_o.value),
                            tuple(bool(pad >> j & 1) for j in range(cols)),
                            tuple((((w >> 8 * j) & 0xFF) ^ 0x80) - 0x80 for j in range(cols))))


async def reset(dut, array_clock=None):
    """Both clocks (the array's from ARRAY_CLOCKS: the one given, or one at
    random), then a reset of a few core cycles."""
    while _clocks:
        _clocks.pop().cancel()
    ta, off = array_clock or random.Random(int(os.environ.get("SEED", "1")) * 7919
                                           + len(_cdc.get("used", []))).choice(ARRAY_CLOCKS)
    _cdc.setdefault("used", []).append((ta, off))
    dut._log.info(f"clk_array_i: {ta} ps, first edge {off} ps after the core's")
    dut.clk_i.value = 0
    dut.clk_array_i.value = 0
    await Timer(1, unit="ns")
    _clocks.append(cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start()))
    if off:
        await Timer(off, unit="ps")
    _clocks.append(cocotb.start_soon(Clock(dut.clk_array_i, ta, unit="ps").start()))
    await RisingEdge(dut.clk_array_i)
    _cdc.update(ta=ta, a0=get_sim_time("ps"), rises=[])
    _clocks.append(cocotb.start_soon(watch_busy(dut, _cdc["rises"])))
    _hook.update(fn=None, log=None)
    _clocks.append(cocotb.start_soon(drive_hook(dut, random.Random(ta + off))))
    for name in ("s_awvalid_i", "s_wvalid_i", "s_bready_i", "s_arvalid_i", "s_rready_i",
                 "d_awvalid_i", "d_wvalid_i", "d_bready_i", "d_arvalid_i", "d_rready_i",
                 "d_wlast_i"):
        getattr(dut, name).value = 0
    for name in ("s_awaddr_i", "s_araddr_i", "s_wdata_i", "s_wstrb_i", "d_awaddr_i",
                 "d_araddr_i", "d_awlen_i", "d_arlen_i", "d_awsize_i", "d_arsize_i",
                 "d_awburst_i", "d_arburst_i", "d_wdata_i", "d_wstrb_i"):
        getattr(dut, name).value = 0
    dut.rst_i.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0


@cocotb.test()
async def test_jobs(dut):
    """Random shapes up to three tiles each way, then the tile edges; each
    job on a C buffer full of garbage, with garbage in A's and W's padding."""
    await reset(dut)
    b = Bench(dut, rng_for(dut))
    r, c = b.rows, b.cols
    shapes = [(1, 1, 1), (1, r, c), (r, r, c), (r + 1, r + 1, c + 1), (2, r - 1, c - 1),
              (3, 2 * r, 1), (1, 3 * r + 1, 2 * c + 1)]
    jobs = int(os.environ.get("ACCEL_JOBS", "30" if r <= 4 else "8"))
    while len(shapes) < jobs + 7:
        m, k, n = (b.rng.randint(1, 3 * max(r, c)) for _ in range(3))
        if b.fits(m, k, n):
            shapes.append((m, k, n))
    for m, k, n in shapes:
        await b.fill_c()
        a, w = b.i8(m, k), b.i8(k, n)
        await b.load(a, w)
        await b.start(m, k, n)
        await b.check(f"{m}x{k}x{n}")
        assert b.model.status == am.ST_DONE
        assert np.array_equal(am.unpack_c(b.model.c, m, n, c), am.gemm(a, w))
    dut._log.info(f"{len(shapes)} jobs exact, cycles as the model")


@cocotb.test()
async def test_saturation(dut):
    """Every product at an extreme, K over several tiles: INT32 sums."""
    await reset(dut)
    b = Bench(dut, rng_for(dut))
    await b.fill_c()   # the buffers outlive a reset; the model starts empty
    m, k, n = 3, 3 * b.rows + 1, b.cols + 1
    for av, wv in ((-128, -128), (-128, 127), (127, -128), (127, 127)):
        a, w = np.full((m, k), av), np.full((k, n), wv)
        await b.load(a, w, garbage=False)
        await b.start(m, k, n)
        await b.check(f"saturation {av} x {wv}")
        assert np.array_equal(am.unpack_c(b.model.c, m, n, b.cols), np.full((m, n), k * av * wv))


@cocotb.test()
async def test_refused(dut):
    """Zero dimensions and each buffer over its limit alone: ERROR, three
    cycles, nothing written; then a job at exactly each limit runs."""
    await reset(dut)
    b = Bench(dut, rng_for(dut))
    r, c, buf = b.rows, b.cols, b.buf
    a_l, w_l, c_l = buf // r, buf // c, buf // (4 * c)
    use = {"A": lambda m, kt, nt: m * kt - a_l,
           "W": lambda m, kt, nt: kt * r * nt - w_l,
           "C": lambda m, kt, nt: m * nt - c_l}
    grid = [(m, kt, nt) for m in range(1, c_l + 2) for kt in range(1, 40) for nt in range(1, 9)]
    cases = [(0, 1, 1), (1, 0, 1), (1, 1, 0)]
    exact = []
    for name, f in use.items():
        ok = [g for g in grid if all(o(*g) <= 0 for x, o in use.items() if x != name)]
        over = min((g for g in ok if f(*g) > 0), key=lambda g: f(*g))
        cases.append((over[0], over[1] * r, over[2] * c))
        exact.append(next(g for g in ok if f(*g) == 0))
    await b.fill_c()
    for m, k, n in cases:
        await b.start(m, k, n)
        await b.check(f"refused {m}x{k}x{n}")
        assert b.model.status == am.ST_ERROR, (m, k, n)
    for m, kt, nt in exact:
        k, n = kt * r, nt * c
        a, w = b.i8(m, k), b.i8(k, n)
        await b.load(a, w, garbage=False)
        await b.start(m, k, n)
        await b.check(f"exactly full {m}x{k}x{n}")
        assert b.model.status == am.ST_DONE
    dut._log.info(f"{len(cases)} refused, {len(exact)} at a limit exactly")


@cocotb.test()
async def test_busy(dut):
    """While a job runs: a buffer read waits and returns the result; a
    buffer write waits and lands after it; START does nothing; STATUS says
    BUSY. Registers: 16-bit dimensions, unmapped reads 0, a partial write
    is refused."""
    await reset(dut)
    b = Bench(dut, rng_for(dut))
    b.delay = 0.0
    await b.fill_c()   # the buffers outlive a reset; the model starts empty
    m, k, n = 2 * b.rows, 2 * b.rows, b.cols
    a, w = b.i8(m, k), b.i8(k, n)
    await b.load(a, w)
    await b.start(m, k, n)
    assert await b.reg_read(am.REG_STATUS) == am.ST_BUSY
    # START again: ignored (the model's job already ran once)
    assert await axi_write(dut, am.REG_CTRL, am.CTRL_START) == OKAY
    t0 = cocotb.utils.get_sim_time("ns")
    words = await b.burst_read(2 * b.buf, 4)
    t1 = cocotb.utils.get_sim_time("ns")
    want = [int.from_bytes(bytes(b.model.c[4 * i:4 * i + 4]), "little") for i in range(4)]
    assert words == want, "a read during the job must see its result"
    cyc = b.model.cycles    # job_cycles() with ARRAY_CDC = 0
    assert (t1 - t0) / CLK_PERIOD_NS > cyc / 2, "the read did not wait for the job"
    assert await b.reg_read(am.REG_STATUS) == am.ST_DONE
    assert await b.reg_read(am.REG_CYCLES) == cyc, "START during the job touched CYCLES"
    # a write during a job lands after it, so the job's C is overwritten
    await b.start(m, k, n)
    await b.write_bytes(2 * b.buf, b"\x11\x22\x33\x44")
    await b.check("write during a job")

    # registers
    await b.reg_write(am.REG_M, 0x12345)
    assert await b.reg_read(am.REG_M) == 0x2345
    for off in (0x00, 0x18, 0x7FC, 0xFFC):
        assert await b.reg_read(off) == 0, f"offset {off:#x}"
    assert await axi_write(dut, am.REG_K, 7, strb=0x3) == SLVERR
    assert await b.reg_read(am.REG_K) == b.model.k
    # the fourth slot of the buffer window reads 0
    assert await b.burst_read(3 * b.buf, 2) == [0, 0]


@cocotb.test()
async def test_clock_ratios(dut):
    """Every clock in ARRAY_CLOCKS in turn: the array faster, slower, equal
    (edges shared and apart), drifting, far off. One-tile jobs with many
    rows (the slow array then sets the pace, the input FIFO fills and the
    credits run out) and multi-tile ones; CYCLES and C exact against the
    model at each. With ARRAY_CDC = 0: identical to job_cycles() whatever
    clk_array_i does."""
    rng = rng_for(dut)
    for clk in ARRAY_CLOCKS:
        await reset(dut, clk)
        b = Bench(dut, rng)
        r, c = b.rows, b.cols
        m_max = b.buf // (4 * c)                      # C lines: one column tile
        shapes = [(m_max, r, c), (m_max // 2 + 1, r - 1, c), (r + 3, 2 * r + 1, c + 1),
                  (1, 1, 1)]
        for m, k, n in shapes:
            await b.fill_c()
            a, w = b.i8(m, k), b.i8(k, n)
            await b.load(a, w)
            await b.start(m, k, n)
            await b.check(f"{m}x{k}x{n} at {clk}")
            assert b.model.status == am.ST_DONE
            assert np.array_equal(am.unpack_c(b.model.c, m, n, c), am.gemm(a, w))
            if not b.cdc:
                assert b.model.cycles == am.job_cycles(m, k, n, r, c)
            dut._log.info(f"{clk}: {m}x{k}x{n} {b.model.cycles} cycles "
                          f"(ARRAY_CDC=0: {am.job_cycles(m, k, n, r, c)})")


@cocotb.test()
async def test_reset_slow_array(dut):
    """START at once after a reset, with the array clock forty times slower
    than the core's (so its first edge comes after the registers are
    written) and rst_i only three core cycles long: the array side has not
    ticked when rst_i falls. The buffers outlive a reset, so the job
    before it is simply run again. Each job leaves the FIFO pointers away
    from zero (an odd number of rows): a core side that left reset before the
    array side took its own would pop the old write pointer's entries into
    the new job's C. With ARRAY_CDC the bus must wait out the reset."""
    rng = rng_for(dut)
    await reset(dut, SLOW_RESET_CLOCK)
    b = Bench(dut, rng)
    await b.fill_c()
    for m in (1, 3, 5, 7):
        a, w = b.i8(m, b.rows), b.i8(b.rows, b.cols)
        await b.load(a, w)
        await b.start(m, b.rows, b.cols)
        await b.check(f"{m} rows")
        await reset(dut, SLOW_RESET_CLOCK)
        await b.start(m, b.rows, b.cols)
        await b.check(f"{m} rows, started at once after a reset")
        assert np.array_equal(am.unpack_c(b.model.c, m, b.cols, b.cols), am.gemm(a, w))


def expected_beats(model, k, n):
    """The record weight_beats() says one job leaves."""
    out = ["start"]
    for bt in am.weight_beats(model.w, k, n, model.rows, model.cols):
        out.append((bt.kt, bt.nt, bt.row, tuple(bool(p) for p in bt.pad),
                    tuple(int(x) for x in bt.w)))
    return out


@cocotb.test()
async def test_weight_order(dut):
    """Every beat at the hook against weight_beats(): tile, row, pad flag and
    weight on every lane, in order, one start pulse before the first. K and
    N off the tile edges, M over several array heights (M never repeats a
    load), every weight seen exactly once; a refused shape sends neither a
    start nor a beat."""
    await reset(dut)
    b = Bench(dut, rng_for(dut))
    r, c = b.rows, b.cols
    shapes = [(1, 1, 1), (3 * r + 1, 2 * r + 3, c + 1), (2 * r, r - 1, 2 * c + 3), (5, 3 * r, c)]
    shapes = [s_ for s_ in shapes if b.fits(*s_)]
    for m, k, n in shapes:
        await b.fill_c()
        a, w = b.i8(m, k), b.i8(k, n)
        await b.load(a, w)
        _hook["log"] = []
        await b.start(m, k, n)
        await b.check(f"{m}x{k}x{n}")
        got, want = _hook["log"], expected_beats(b.model, k, n)
        _hook["log"] = None
        assert len(got) == len(want), f"{m}x{k}x{n}: {len(got)} records, want {len(want)}"
        for i, (g, x) in enumerate(zip(got, want)):
            assert g == x, f"{m}x{k}x{n}: record {i} is {g}, want {x}"
        # independently of weight_beats: each weight of W once, at its lane
        seen = {}
        for kt, nt, row, pad, lanes in got[1:]:
            for j in range(c):
                kk, nn = kt * r + row, nt * c + j
                assert pad[j] == (kk >= k or nn >= n), f"pad flag at ({kk}, {nn})"
                if not pad[j]:
                    assert (kk, nn) not in seen and lanes[j] == w[kk, nn], f"weight ({kk}, {nn})"
                    seen[(kk, nn)] = 1
        assert len(seen) == k * n
    _hook["log"] = []
    await b.start(0, 1, 1)
    await b.check("refused")
    assert _hook["log"] == [], f"a refused shape sent {_hook['log'][:3]}"
    _hook["log"] = None
    dut._log.info(f"{len(shapes)} jobs, every beat as weight_beats()")


@cocotb.test()
async def test_weight_transform(dut):
    """With WX_EXT = 1, a transform on every lane (w XOR 1, pad lanes too):
    C is the GEMM of the transformed W and pad lanes still go in as 0, at
    every clock of ARRAY_CLOCKS with ARRAY_CDC, so the transform is applied
    before the crossing (the beats are only on clk_i). CYCLES as the
    model's, unchanged by the transform. With WX_EXT = 0 the bench drives
    garbage on wx_w_i and C is the plain GEMM."""
    rng = rng_for(dut)
    ext = bool(int(dut.WX_EXT.value))
    for clk in ARRAY_CLOCKS if ext else ARRAY_CLOCKS[:2]:
        await reset(dut, clk)
        b = Bench(dut, rng)
        r, c = b.rows, b.cols
        if ext:
            ones = int.from_bytes(bytes([1] * c), "little")
            _hook["fn"] = lambda w: w ^ ones
            b.model.wx = lambda bt: bt.w ^ 1
        for m, k, n in ((1, 1, 1), (r + 3, 2 * r + 1, c + 1), (2, r - 1, 2 * c - 1)):
            await b.fill_c()
            a, w = b.i8(m, k), b.i8(k, n)
            await b.load(a, w)
            await b.start(m, k, n)
            await b.check(f"{m}x{k}x{n} at {clk}")
            want = am.gemm(a, w ^ 1) if ext else am.gemm(a, w)
            assert np.array_equal(am.unpack_c(b.model.c, m, n, c), want)
    dut._log.info("transform applied" if ext else "wx_w_i ignored")
