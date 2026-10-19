#!/usr/bin/env python3
"""Golden model of the INT8 systolic array (Phase F, buildplan 6.1).

Written before the RTL: every array test compares against these functions.
`python3 sw/model/gemm_model.py` checks the model against itself and against
independent references (plain Python integers, exact fractions).

The operation is C = A @ W with A (M x K) and W (K x N) signed INT8, products
summed in INT32. An INT32 sum wraps around (two's complement), as the
hardware adders do; it never comes close for K below 131072 (16384 per term).

Dataflow, weight-stationary, on an array of ROWS x COLS PEs:
  - PE (r, c) holds w = W[k0 + r][n0 + c] for one tile; positions past the
    edge of W hold 0.
  - Activations enter row r from the left, skewed by r cycles: in cycle t the
    feeder gives row r A[t - r][k0 + r], or 0 outside A (the feeder pads
    zeros, so the array always runs full tiles). Each PE registers the
    activation and passes it right.
  - Partial sums flow down: PE (r, c) registers psum_in + w * a_in, with
    psum_in = 0 in row 0. Row m of A reaches PE (r, c) in cycle m + r + c, so
    its sum for column c leaves the bottom row at the end of cycle
    m + (ROWS - 1) + c. A tile takes M + ROWS + COLS - 2 cycles.
  - Results outside C are not written; tiles along K are summed (INT32).

Requantization to INT8, per output column n, with mult[n] in [0, 2^31) and
shift[n] in [0, 31]:
  y = acc * mult / 2^(31 + shift), rounded half away from zero, saturated to
  [-128, 127]. Symmetric: no zero points.
"""

from fractions import Fraction
import math
import sys

import numpy as np


def wrap32(x):
    """Wrap integers to INT32, two's complement."""
    return ((np.asarray(x, dtype=np.int64) + 2**31) % 2**32 - 2**31).astype(np.int64)


def pe(a, w, psum):
    """One PE: psum + w * a, wrapped to INT32."""
    return int(wrap32(psum + w * a))


def gemm(a, w):
    """C = A @ W, INT8 inputs, INT32 result with wraparound."""
    return wrap32(np.asarray(a, dtype=np.int64) @ np.asarray(w, dtype=np.int64))


def requant(acc, mult, shift):
    """INT32 (M x N) to INT8, per column: see the module docstring."""
    p = np.asarray(acc, dtype=np.int64) * np.asarray(mult, dtype=np.int64)
    t = 31 + np.asarray(shift, dtype=np.int64)
    mag = (np.abs(p) + (np.int64(1) << (t - 1))) >> t
    return np.clip(np.where(p < 0, -mag, mag), -128, 127)


def systolic(a, w, rows=16, cols=16):
    """C = A @ W computed cycle by cycle the way the array does it."""
    a = np.asarray(a, dtype=np.int64)
    w = np.asarray(w, dtype=np.int64)
    m, k = a.shape
    n = w.shape[1]
    out = np.zeros((m, n), dtype=np.int64)
    r_idx = np.arange(rows)
    c_idx = np.arange(cols)
    for k0 in range(0, k, rows):
        kk = min(rows, k - k0)
        for n0 in range(0, n, cols):
            nn = min(cols, n - n0)
            wt = np.zeros((rows, cols), dtype=np.int64)
            wt[:kk, :nn] = w[k0:k0 + kk, n0:n0 + nn]
            a_reg = np.zeros((rows, cols), dtype=np.int64)
            p_reg = np.zeros((rows, cols), dtype=np.int64)
            for t in range(m + rows + cols - 2):
                feed = np.zeros(rows, dtype=np.int64)
                mm = t - r_idx
                ok = (mm >= 0) & (mm < m) & (r_idx < kk)
                feed[ok] = a[mm[ok], k0 + r_idx[ok]]
                a_in = np.empty_like(a_reg)
                a_in[:, 0] = feed
                a_in[:, 1:] = a_reg[:, :-1]
                p_in = np.zeros_like(p_reg)
                p_in[1:] = p_reg[:-1]
                p_reg = wrap32(p_in + wt * a_in)
                a_reg = a_in
                mm = t - (rows - 1) - c_idx
                ok = (mm >= 0) & (mm < m) & (c_idx < nn)
                out[mm[ok], n0 + c_idx[ok]] += p_reg[rows - 1, ok]
    return wrap32(out)


# --- self-check ---------------------------------------------------------------

def gemm_exact(a, w):
    """Plain Python integers, wrapped to INT32: independent of NumPy dtypes."""
    m, k = len(a), len(a[0])
    n = len(w[0])
    res = [[sum(int(a[i][j]) * int(w[j][l]) for j in range(k)) for l in range(n)]
           for i in range(m)]
    return [[(v + 2**31) % 2**32 - 2**31 for v in row] for row in res]


def requant_exact(x, mult, shift):
    """Exact fractions: independent of the shift-and-add formulation."""
    v = Fraction(int(x) * int(mult), 2**(31 + int(shift)))
    mag = math.floor(abs(v) + Fraction(1, 2))
    return max(-128, min(127, mag if v >= 0 else -mag))


def check(name, got, want, cases):
    if not np.array_equal(np.asarray(got), np.asarray(want)):
        sys.exit(f"FAIL {name}\n got  {got}\n want {want}")
    cases[name] = cases.get(name, 0) + 1


def main():
    rng = np.random.default_rng(1)
    cases = {}
    i8 = lambda *s: rng.integers(-128, 128, size=s)

    # PE: every activation and weight, with psums at both INT32 limits.
    av, wv = np.meshgrid(np.arange(-128, 128), np.arange(-128, 128))
    for psum in (0, 2**31 - 1, -2**31, 12345):
        check("pe exhaustive", wrap32(psum + av * wv),
              [[(psum + x * y + 2**31) % 2**32 - 2**31 for x, y in zip(ra, rw)]
               for ra, rw in zip(av.tolist(), wv.tolist())], cases)
    check("pe exhaustive", [pe(-128, -128, 2**31 - 1), pe(127, -128, -2**31)],
          [-2**31 + 16383, 2**31 - 16256], cases)

    # gemm against plain Python integers.
    for _ in range(200):
        m, k, n = rng.integers(1, 12, size=3)
        a, w = i8(m, k), i8(k, n)
        check("gemm vs python ints", gemm(a, w), gemm_exact(a.tolist(), w.tolist()), cases)

    # The cycle-level array against gemm: random shapes, sizes that are and
    # are not multiples of the array, several array shapes.
    for rows, cols, trials in ((4, 4, 400), (8, 8, 300), (16, 16, 300), (4, 8, 100), (8, 4, 100)):
        for _ in range(trials):
            m, k, n = rng.integers(1, 41, size=3)
            a, w = i8(m, k), i8(k, n)
            check(f"systolic {rows}x{cols} vs gemm", systolic(a, w, rows, cols), gemm(a, w), cases)
        for m, k, n in ((1, 1, 1), (rows, rows, cols), (rows + 1, rows + 1, cols + 1),
                        (2 * rows, 3 * rows, 2 * cols), (1, rows - 1, cols - 1)):
            a, w = i8(m, k), i8(k, n)
            check(f"systolic {rows}x{cols} vs gemm", systolic(a, w, rows, cols), gemm(a, w), cases)

    # Saturation boundaries: the largest positive and negative products in
    # every term, and a K long enough to wrap INT32 (-128 * -128 = 16384 per
    # term; 131072 terms reach 2^31).
    for av_, wv_ in ((-128, -128), (-128, 127), (127, 127), (127, -128)):
        a = np.full((20, 37), av_)
        w = np.full((37, 19), wv_)
        check("systolic saturation boundaries", systolic(a, w), gemm(a, w), cases)
        check("systolic saturation boundaries", gemm(a, w), np.full((20, 19), 37 * av_ * wv_), cases)
    k = 131073
    a = np.full((1, k), -128)
    w = np.full((k, 1), -128)
    check("int32 wraparound", gemm(a, w), [[k * 16384 - 2**32]], cases)
    check("int32 wraparound", systolic(a, w), [[k * 16384 - 2**32]], cases)

    # Requantization against exact fractions: random, ties, extremes.
    acc = rng.integers(-2**31, 2**31, size=(400, 16))
    mult = rng.integers(0, 2**31, size=16)
    shift = rng.integers(0, 32, size=16)
    want = [[requant_exact(x, mult[j], shift[j]) for j, x in enumerate(row)] for row in acc]
    check("requant vs fractions", requant(acc, mult, shift), want, cases)
    small = rng.integers(-2**20, 2**20, size=(400, 16))
    mult = rng.integers(2**30, 2**31, size=16)
    shift = rng.integers(0, 12, size=16)
    want = [[requant_exact(x, mult[j], shift[j]) for j, x in enumerate(row)] for row in small]
    check("requant vs fractions", requant(small, mult, shift), want, cases)
    # mult = 2^30, shift s: y = acc / 2^(s+1). Odd acc with s = 0 lands on .5.
    ties = np.array([[1, -1, 3, -3, 5, -5, 255, -255, 257, -257]])
    m30 = np.full(10, 2**30)
    check("requant ties (half away from zero)", requant(ties, m30, np.zeros(10, dtype=int)),
          [[1, -1, 2, -2, 3, -3, 127, -128, 127, -128]], cases)
    ext = np.array([[2**31 - 1, -2**31, 0, 1, -1]])
    for mlt in (0, 1, 2**31 - 1):
        for s in (0, 31):
            got = requant(ext, np.full(5, mlt), np.full(5, s))
            check("requant extremes", got, [[requant_exact(x, mlt, s) for x in ext[0]]], cases)

    for name, count in cases.items():
        print(f"  {count:5d}  {name}")
    print(f"gemm model: {sum(cases.values())} checks passed")


if __name__ == "__main__":
    main()
