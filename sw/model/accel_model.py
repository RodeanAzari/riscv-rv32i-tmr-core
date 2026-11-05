#!/usr/bin/env python3
"""Golden model of the GEMM accelerator (Phase G: software launches a job).

Written before the RTL (rtl/accel/gemm_accel*.sv). The array's arithmetic is
gemm_model's; this model adds what the accelerator around it decides: the
buffer layouts, the registers, the job's tiling, which shapes it refuses, and
how many cycles a job takes. `python3 sw/model/accel_model.py` checks it
against gemm_model.gemm() on the unpacked matrices.

Decided with the user (2026-11-05): the accelerator has its own buffers for
A, W and C, which the DMA fills and empties (the bus is 4 bytes a cycle, the
array eats ROWS a cycle); C comes out as INT32 (requantization stays in
software for now); one job is a whole GEMM, C = A @ W, tiled in hardware.

Buffers, each BUF_BYTES, in one window on the bus (byte offsets):
  A at 0             line (m * KT + kt), ROWS bytes: A[m][kt*ROWS + j]
  W at BUF_BYTES     line (k * NT + nt), COLS bytes: W[k][nt*COLS + j]
  C at 2 * BUF_BYTES line (m * NT + nt), COLS INT32 words, little-endian:
                     C[m][nt*COLS + j]
  (KT = ceil(K / ROWS), NT = ceil(N / COLS).) That is, each matrix row-major
  with its row padded to whole lines. The window's fourth slot reads 0 and
  ignores writes.
Padding: A's bytes past K are read but meet zero weights; W's columns past N
and rows past K are fed as zeros whatever the buffer holds; C's words past N
in a line are written with 0. C lines past M * NT are untouched.

Registers (AXI4-Lite, 32-bit words; anything else reads 0):
  0x00 CTRL    W: bit 0 START (ignored while busy)      R: 0
  0x04 STATUS  R: bit 0 BUSY, bit 1 DONE, bit 2 ERROR    W: ignored
               DONE and ERROR are cleared by START; ERROR means the shape
               was refused (a dimension 0, or a matrix larger than its
               buffer) and nothing was computed or written.
  0x08 M, 0x0C K, 0x10 N   R/W, 16 bits
  0x14 CYCLES  R: the last job's busy cycles, START to idle
The buffers belong to the engine while BUSY: a bus access waits until the
job ends.

Schedule (the cycle count is part of the contract; a change to it is a
measured change): 3 cycles of shape check, then per tile, N outer and K
inner, ROWS cycles shifting the weights in, one swap cycle, M rows streamed,
and LATENCY + 2 cycles until the last row's sum is in C, one tile after the
other with no overlap. LATENCY = ROWS + COLS/2 - 1 (systolic_array.sv).
"""

from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gemm_model import gemm, wrap32  # noqa: E402

REG_CTRL, REG_STATUS, REG_M, REG_K, REG_N, REG_CYCLES = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14
CTRL_START = 1
ST_BUSY, ST_DONE, ST_ERROR = 1, 2, 4
DIM_MASK = 0xFFFF
CHECK_CYCLES = 3


def ceil_div(a, b):
    return -(-a // b)


def latency(rows, cols):
    return rows + cols // 2 - 1


def job_cycles(m, k, n, rows, cols):
    tiles = ceil_div(k, rows) * ceil_div(n, cols)
    return CHECK_CYCLES + tiles * (rows + 1 + m + latency(rows, cols) + 2)


# --- layouts: what software (or the test) puts in the buffers ----------------

def pack_a(a, rows):
    """A (M x K) to A-buffer bytes; padding bytes are left 0."""
    a = np.asarray(a, dtype=np.int64)
    m, k = a.shape
    out = np.zeros((m, ceil_div(k, rows) * rows), dtype=np.uint8)
    out[:, :k] = a & 0xFF
    return out.tobytes()


def pack_w(w, cols):
    w = np.asarray(w, dtype=np.int64)
    k, n = w.shape
    out = np.zeros((k, ceil_div(n, cols) * cols), dtype=np.uint8)
    out[:, :n] = w & 0xFF
    return out.tobytes()


def unpack_c(buf, m, n, cols):
    """C-buffer bytes to C (M x N), INT32."""
    nt = ceil_div(n, cols)
    words = np.frombuffer(bytes(buf[:m * nt * cols * 4]), dtype="<i4")
    return words.reshape(m, nt * cols)[:, :n].astype(np.int64)


# --- the device ---------------------------------------------------------------

class Accel:
    def __init__(self, rows=16, cols=16, buf_bytes=16384):
        self.rows, self.cols, self.buf_bytes = rows, cols, buf_bytes
        self.a = bytearray(buf_bytes)
        self.w = bytearray(buf_bytes)
        self.c = bytearray(buf_bytes)
        self.m = self.k = self.n = 0
        self.status = 0
        self.cycles = 0

    # bus side
    def buf_write(self, off, data):
        slot, o = divmod(off, self.buf_bytes)
        if slot < 3:
            (self.a, self.w, self.c)[slot][o:o + len(data)] = data

    def buf_read(self, off, length):
        slot, o = divmod(off, self.buf_bytes)
        if slot < 3:
            return bytes((self.a, self.w, self.c)[slot][o:o + length])
        return bytes(length)

    def reg_write(self, off, val):
        if off == REG_M:
            self.m = val & DIM_MASK
        elif off == REG_K:
            self.k = val & DIM_MASK
        elif off == REG_N:
            self.n = val & DIM_MASK
        elif off == REG_CTRL and val & CTRL_START:
            self.run()

    def reg_read(self, off):
        return {REG_STATUS: self.status, REG_M: self.m, REG_K: self.k,
                REG_N: self.n, REG_CYCLES: self.cycles}.get(off, 0)

    def shape_ok(self):
        r, c, b = self.rows, self.cols, self.buf_bytes
        m, k, n = self.m, self.k, self.n
        if 0 in (m, k, n):
            return False
        kt, nt = ceil_div(k, r), ceil_div(n, c)
        return m * kt <= b // r and k * nt <= b // c and m * nt <= b // (4 * c)

    def run(self):
        """A whole job; the model completes it at once (the RTL reports BUSY
        meanwhile)."""
        r, c = self.rows, self.cols
        m, k, n = self.m, self.k, self.n
        if not self.shape_ok():
            self.status = ST_ERROR
            self.cycles = CHECK_CYCLES
            return
        kt_n, nt_n = ceil_div(k, r), ceil_div(n, c)
        abuf = np.frombuffer(bytes(self.a), dtype=np.int8).astype(np.int64)
        wbuf = np.frombuffer(bytes(self.w), dtype=np.int8).astype(np.int64)
        for nt in range(nt_n):
            col_ok = (nt * c + np.arange(c)) < n
            for kt in range(kt_n):
                # the tile of weights the array holds: rows past K and
                # columns past N are zeros
                tile = np.zeros((r, c), dtype=np.int64)
                for i in range(r):
                    kk = kt * r + i
                    if kk < k:
                        line = kk * nt_n + nt
                        tile[i] = np.where(col_ok, wbuf[line * c:(line + 1) * c], 0)
                for mm in range(m):
                    line = mm * kt_n + kt
                    arow = abuf[line * r:(line + 1) * r]
                    psum = wrap32(arow @ tile)
                    cl = (mm * nt_n + nt) * c * 4
                    if kt > 0:
                        old = np.frombuffer(bytes(self.c[cl:cl + 4 * c]), dtype="<i4")
                        psum = wrap32(psum + old)
                    self.c[cl:cl + 4 * c] = psum.astype("<i4").tobytes()
        self.status = ST_DONE
        self.cycles = job_cycles(m, k, n, r, c)


# --- self-check ---------------------------------------------------------------

def run_job(acc, a, w, rng=None):
    """Load A and W the way software would (padding random if rng), start,
    return C."""
    r, c = acc.rows, acc.cols
    m, k = a.shape
    n = w.shape[1]
    pa, pw = bytearray(pack_a(a, r)), bytearray(pack_w(w, c))
    if rng is not None:
        # garbage in every padding byte: the accelerator must not read it
        # as data
        ka, nw = ceil_div(k, r) * r, ceil_div(n, c) * c
        for mm in range(m):
            for j in range(k, ka):
                pa[mm * ka + j] = int(rng.integers(256))
        for kk in range(k):
            for j in range(n, nw):
                pw[kk * nw + j] = int(rng.integers(256))
    acc.buf_write(0, pa)
    acc.buf_write(acc.buf_bytes, pw)
    acc.reg_write(REG_M, m)
    acc.reg_write(REG_K, k)
    acc.reg_write(REG_N, n)
    acc.reg_write(REG_CTRL, CTRL_START)
    return acc


def fail(msg):
    sys.exit(f"FAIL {msg}")


def main():
    rng = np.random.default_rng(1)
    cases = {}

    def count(name):
        cases[name] = cases.get(name, 0) + 1

    i8 = lambda *s: rng.integers(-128, 128, size=s)

    for rows, cols, buf in ((4, 4, 1024), (16, 16, 16384), (4, 8, 4096)):
        acc = Accel(rows, cols, buf)
        shapes = [tuple(rng.integers(1, 3 * max(rows, cols) + 1, size=3)) for _ in range(150)]
        shapes += [(1, 1, 1), (1, rows, cols), (rows, rows + 1, cols - 1), (2, rows - 1, cols + 1)]
        for m, k, n in shapes:
            a, w = i8(m, k), i8(k, n)
            acc.c[:] = rng.integers(0, 256, size=buf, dtype=np.uint8).tobytes()
            before = bytes(acc.c)
            run_job(acc, a, w, rng)
            name = f"{rows}x{cols} job vs gemm"
            if acc.reg_read(REG_STATUS) != ST_DONE:
                fail(f"{name}: status {acc.status} for {m}x{k}x{n}")
            if not np.array_equal(unpack_c(acc.c, m, n, cols), gemm(a, w)):
                fail(f"{name}: {m}x{k}x{n}")
            nt = ceil_div(n, cols)
            words = np.frombuffer(bytes(acc.c[:m * nt * cols * 4]), dtype="<i4").reshape(m, -1)
            if np.any(words[:, n:]):
                fail(f"{name}: C padding not zero, {m}x{k}x{n}")
            if bytes(acc.c[m * nt * cols * 4:]) != before[m * nt * cols * 4:]:
                fail(f"{name}: wrote past C, {m}x{k}x{n}")
            if acc.reg_read(REG_CYCLES) != job_cycles(m, k, n, rows, cols):
                fail(f"{name}: cycles")
            count(name)

        # Refused shapes: zero dimensions, and each buffer one line over.
        # Nothing may be written.
        a_lines, w_lines, c_lines = buf // rows, buf // cols, buf // (4 * cols)
        refused = [(0, 1, 1), (1, 0, 1), (1, 1, 0),
                   (a_lines + 1, 1, 1),                 # A: M * KT
                   (1, w_lines + 1, 1),                 # W: K * NT (and A)
                   (c_lines + 1, 1, 1)]                 # C: M * NT
        for m, k, n in refused:
            acc.reg_write(REG_M, m)
            acc.reg_write(REG_K, k)
            acc.reg_write(REG_N, n)
            before = bytes(acc.c)
            acc.reg_write(REG_CTRL, CTRL_START)
            if acc.status != ST_ERROR or acc.cycles != CHECK_CYCLES or bytes(acc.c) != before:
                fail(f"{rows}x{cols} refuses {m}x{k}x{n}")
            count(f"{rows}x{cols} refused shapes")
        # Each buffer's limit alone: a shape that fills that buffer exactly
        # (the others with room) is accepted and computed, and the smallest
        # shape found over it alone is refused.
        limits = {"A": lambda m, kt, nt: m * kt <= a_lines,
                  "W": lambda m, kt, nt: kt * rows * nt <= w_lines,
                  "C": lambda m, kt, nt: m * nt <= c_lines}
        use = {"A": lambda m, kt, nt: m * kt - a_lines,
               "W": lambda m, kt, nt: kt * rows * nt - w_lines,
               "C": lambda m, kt, nt: m * nt - c_lines}
        grid = [(m, kt, nt) for m in range(1, c_lines + 2) for kt in range(1, 40)
                for nt in range(1, 9)]
        for name in limits:
            others = [f for o, f in limits.items() if o != name]
            ok_all = [g for g in grid if all(f(*g) for f in others)]
            exact = next(g for g in ok_all if use[name](*g) == 0)
            over = min((g for g in ok_all if use[name](*g) > 0), key=lambda g: use[name](*g))
            m, kt, nt = exact
            a, w = i8(m, kt * rows), i8(kt * rows, nt * cols)
            run_job(acc, a, w)
            if acc.status != ST_DONE or not np.array_equal(unpack_c(acc.c, m, nt * cols, cols), gemm(a, w)):
                fail(f"{rows}x{cols} {name} buffer exactly full, {exact}")
            m, kt, nt = over
            acc.reg_write(REG_M, m)
            acc.reg_write(REG_K, kt * rows)
            acc.reg_write(REG_N, nt * cols)
            acc.reg_write(REG_CTRL, CTRL_START)
            if acc.status != ST_ERROR:
                fail(f"{rows}x{cols} {name} buffer over by {use[name](*over)}, {over}")
            count(f"{rows}x{cols} buffer limits, each alone")

        # The largest accepted: exactly fills a buffer.
        m = min(a_lines, c_lines)
        a, w = i8(m, rows), i8(rows, cols)
        run_job(acc, a, w)
        if acc.status != ST_DONE or not np.array_equal(unpack_c(acc.c, m, cols, cols), gemm(a, w)):
            fail(f"{rows}x{cols} full buffer")
        count(f"{rows}x{cols} full buffer")

    # Saturation: every product at an extreme, K over several tiles.
    acc = Accel()
    for av, wv in ((-128, -128), (-128, 127), (127, -128), (127, 127)):
        a, w = np.full((20, 100), av), np.full((100, 19), wv)
        run_job(acc, a, w)
        if not np.array_equal(unpack_c(acc.c, 20, 19, 16), np.full((20, 19), 100 * av * wv)):
            fail("saturation")
        count("16x16 saturation")

    for name, n in cases.items():
        print(f"  {n:5d}  {name}")
    print(f"accel model: {sum(cases.values())} checks passed")


if __name__ == "__main__":
    main()
