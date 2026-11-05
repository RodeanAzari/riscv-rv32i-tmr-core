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
"""

import os
from pathlib import Path
import random
import sys

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from axil import OKAY, SLVERR, axi_read, axi_write

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import accel_model as am  # noqa: E402

CLK_PERIOD_NS = 10
MAX_BEATS = 16


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

    def wait(self):
        return self.rng.random() < self.delay

    # ---- AXI4 buffer port: bursts, one at a time ----
    async def burst_write(self, addr, words):
        d = self.dut
        d.d_awaddr_i.value = addr
        d.d_awlen_i.value = len(words) - 1
        d.d_awsize_i.value = 2
        d.d_awburst_i.value = 1
        while True:
            v = not self.wait()
            d.d_awvalid_i.value = int(v)
            hs = v and d.d_awready_o.value
            await FallingEdge(d.clk_i)
            if hs:
                break
        d.d_awvalid_i.value = 0
        i = 0
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
        while True:
            v = not self.wait()
            d.d_arvalid_i.value = int(v)
            hs = v and d.d_arready_o.value
            await FallingEdge(d.clk_i)
            if hs:
                break
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
        await self.reg_write(am.REG_CTRL, am.CTRL_START)

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


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
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
    cyc = am.job_cycles(m, k, n, b.rows, b.cols)
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
