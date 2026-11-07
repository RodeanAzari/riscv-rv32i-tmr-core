#!/usr/bin/env python3
"""Golden model of the GEMM accelerator with the array on its own clock
(Phase H box 2, slice 2), written before the RTL (slice 3).

accel_model.py stays the contract for ARRAY_CDC = 0: the same buffers,
registers and refused shapes, and CYCLES = job_cycles(). With the array on
clk_array, CYCLES depends on the two clocks and their phase, so this model
runs the job edge by edge on both clocks and returns the CYCLES the RTL must
report for those clocks; results stay bit-exact, and the model computes C
from the stream it schedules (not from gemm()), so a lost, duplicated or
misordered entry shows up as a wrong C.

The design (docs/design-notes.md, "Array clock domain", slice 3):
  - The sequencer stays on the core clock and issues, per tile, exactly the
    entries it drives today: ROWS weight shifts, one swap, M rows of A. Each
    is read from the buffers one cycle and pushed into the input FIFO
    (cdc_async_fifo) at the next core edge. Only these entries are pushed:
    the array side feeds a bubble whenever the FIFO is empty, so CHECK and
    DRAIN cycles need no entries.
  - The sequencer issues an entry only if the FIFO has room for it and for
    the one read in flight (wr_used + in flight < IN_DEPTH), and a row of A
    only if it holds a credit (rows sent - rows received < OUT_DEPTH): the
    array cannot be stalled, so the output FIFO must never be full.
  - The array pops one entry per clk_array edge while the FIFO is not empty;
    a row's sums leave LATENCY array edges later into the output FIFO.
  - The core pops a row of sums per core edge while that FIFO is not empty,
    and writes C one cycle later (read old C on the pop, add, write). As
    today, the next tile's first entry waits for the last row's write, which
    is also what keeps the shadow weights still until a swap has reached the
    last pair (checked here at every shift).
  - Synchronizers sample ideally: a pointer change at time t is seen by the
    first flop at the first edge strictly after t, as in simulation (a
    coincident edge samples the old value), and the receiving side acts on
    it SYNC_STAGES edges later (tb/cocotb/test_cdc_async_fifo.py,
    test_latency).

`python3 sw/model/accel_cdc_model.py` checks the model: in direct mode
(no FIFOs, one clock) it must equal accel_model exactly, cycles and C; with
FIFOs, C must equal gemm() and CYCLES must respect a lower bound derived
independently below, over many clock ratios and phases. `--costs` prints
what clk_array's frequency costs, and the output FIFO depth it needs.
"""

import bisect
from collections import deque
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import accel_model as am  # noqa: E402
from gemm_model import gemm, wrap32  # noqa: E402

SYNC_STAGES = 2
IN_DEPTH = 16
OUT_DEPTH = 32
MAX_EDGES = 10_000_000


class ModelError(Exception):
    pass


class Sync:
    """SYNC_STAGES flops sampling a count the other domain keeps, as the
    times of its events (sorted, appended as they happen)."""

    def __init__(self, stages, times):
        self.chain = deque([0] * stages, maxlen=stages)
        self.times = times

    def value(self):
        """The last flop: what this domain acts on before its edge."""
        return self.chain[-1]

    def clock(self, t):
        # events strictly before t
        self.chain.appendleft(bisect.bisect_left(self.times, t))


def tiles(acc):
    """The entries the sequencer issues, tile by tile (N outer, K inner),
    with the data read from the buffers: ('shift', W row), ('swap',),
    ('row', A row). Returns [(nt, kt, entries)]."""
    r, c = acc.rows, acc.cols
    m, k, n = acc.m, acc.k, acc.n
    kt_n, nt_n = am.ceil_div(k, r), am.ceil_div(n, c)
    abuf = np.frombuffer(bytes(acc.a), dtype=np.int8).astype(np.int64)
    wbuf = np.frombuffer(bytes(acc.w), dtype=np.int8).astype(np.int64)
    out = []
    for nt in range(nt_n):
        col_ok = (nt * c + np.arange(c)) < n
        for kt in range(kt_n):
            ent = []
            for i in range(r - 1, -1, -1):          # row ROWS - 1 first
                kk = kt * r + i
                row = np.zeros(c, dtype=np.int64)
                if kk < k:
                    line = kk * nt_n + nt
                    row = np.where(col_ok, wbuf[line * c:(line + 1) * c], 0)
                ent.append(("shift", row))
            ent.append(("swap", None))
            for mm in range(m):
                line = mm * kt_n + kt
                ent.append(("row", abuf[line * r:(line + 1) * r]))
            out.append((nt, kt, ent))
    return out


class Array:
    """The array's behaviour at its ports: weights shift into the shadows,
    a swap makes them active for the rows after it, a row's sums leave
    LATENCY edges after the row went in."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.lat = am.latency(rows, cols)
        self.shadow = np.zeros((rows, cols), dtype=np.int64)
        self.active = np.zeros((rows, cols), dtype=np.int64)
        self.last_swap = None
        self.pipe = deque()        # (edge the sums leave at, sums)

    def take(self, entry, j):
        """Entry captured at array edge j."""
        kind, data = entry
        if kind == "shift":
            # the shadows may move only once the last swap has passed the
            # last pair, ROWS + COLS/2 - 2 edges after it went in
            if self.last_swap is not None and j - self.last_swap <= self.rows + self.cols // 2 - 2:
                raise ModelError(f"shift at array edge {j}, {j - self.last_swap} after a swap")
            self.shadow = np.vstack([data[None, :], self.shadow[:-1]])
        elif kind == "swap":
            self.active = self.shadow.copy()
            self.last_swap = j
        else:
            self.pipe.append((j + self.lat, wrap32(data @ self.active)))

    def leaving(self, j):
        """Sums that leave at edge j (at most one row)."""
        if self.pipe and self.pipe[0][0] == j:
            return self.pipe.popleft()[1]
        return None



def stream_job(acc, t_core=10_000, t_array=10_000, phase=0, sync=SYNC_STAGES,
               in_depth=IN_DEPTH, out_depth=OUT_DEPTH, direct=False):
    """Run the job in acc's registers and buffers, edge by edge. Times in
    integer ps: core edge e at e * t_core (cycle e - 1 ends at edge e; START
    is taken before edge 1), array edge j at phase + j * t_array.
    direct=True is ARRAY_CDC = 0: one clock, no FIFOs, the array taking
    each entry at the edge it would be pushed. Writes C and STATUS like
    Accel.run(); returns CYCLES (also left in acc.cycles)."""
    r, c = acc.rows, acc.cols
    if not acc.shape_ok():
        acc.status, acc.cycles = am.ST_ERROR, am.CHECK_CYCLES
        return acc.cycles
    nt_n = am.ceil_div(acc.n, c)
    m = acc.m
    work = tiles(acc)
    arr = Array(r, c)

    in_q, in_push_t, in_pop_t = [], [], []       # input FIFO
    out_q, out_push_t, out_pop_t = [], [], []    # output FIFO
    core_in_sync = Sync(sync, in_pop_t)          # the writer's view of pops
    core_out_sync = Sync(sync, out_push_t)       # the reader's view of pushes
    arr_in_sync = Sync(sync, in_push_t)
    arr_out_sync = Sync(sync, out_pop_t)

    st = {"tile": -1, "idx": 0, "from": 0, "sent": 0, "recv": 0, "written": 0}
    pending = None                # entry read this cycle, pushed at the edge
    o2 = None                     # sums popped at the last edge, written now

    def start_tile(edge):
        st.update(tile=st["tile"] + 1, idx=0, sent=0, recv=0, written=0, **{"from": edge + 1})

    def write_c(sums):
        nt, kt, _ = work[st["tile"]]
        cl = (st["written"] * nt_n + nt) * c * 4
        if kt > 0:
            sums = wrap32(sums + np.frombuffer(bytes(acc.c[cl:cl + 4 * c]), dtype="<i4"))
        acc.c[cl:cl + 4 * c] = sums.astype("<i4").tobytes()
        st["written"] += 1

    def core_edge(e, tc):
        nonlocal pending, o2
        # what the logic sees before the edge
        used = len(in_push_t) - core_in_sync.value()
        seen = core_out_sync.value() - len(out_pop_t)
        sent, recv, had = st["sent"], st["recv"], pending is not None
        # o2: the row popped last edge is written to C now
        if o2 is not None:
            write_c(o2)
            o2 = None
            if st["written"] == m:
                if st["tile"] + 1 == len(work):
                    return True
                start_tile(e)
        # pop a row of sums
        if direct:
            o2 = arr.leaving(e)
        elif seen > 0:
            o2 = out_q[len(out_pop_t)]
            out_pop_t.append(tc)
        if o2 is not None:
            st["recv"] += 1
        # push the entry read last cycle
        if pending is not None:
            if direct:
                arr.take(pending, e)
            else:
                if used >= in_depth:
                    raise ModelError(f"input FIFO full at a push (core edge {e})")
                in_q.append(pending)
                in_push_t.append(tc)
            pending = None
        # read the next entry
        if e == am.CHECK_CYCLES:
            start_tile(e)
        elif st["tile"] >= 0 and e >= st["from"] and st["idx"] < len(work[st["tile"]][2]):
            ent = work[st["tile"]][2][st["idx"]]
            room = direct or used + had < in_depth
            credit = direct or ent[0] != "row" or sent - recv < out_depth
            if room and credit:
                pending = ent
                st["idx"] += 1
                st["sent"] += ent[0] == "row"
        if not direct:
            core_in_sync.clock(tc)
            core_out_sync.clock(tc)
        return False

    def array_edge(j, ta):
        seen = arr_in_sync.value() - len(in_pop_t)
        sums = arr.leaving(j)
        if sums is not None:
            if len(out_push_t) - arr_out_sync.value() >= out_depth:
                raise ModelError(f"output FIFO full when a row left the array (array edge {j})")
            out_q.append(sums)
            out_push_t.append(ta)
        if seen > 0:
            arr.take(in_q[len(in_pop_t)], j)
            in_pop_t.append(ta)
        arr_in_sync.clock(ta)
        arr_out_sync.clock(ta)

    e, j = 1, 0
    for _ in range(MAX_EDGES):
        tc, ta = e * t_core, phase + j * t_array
        if direct or tc <= ta:
            if core_edge(e, tc):
                acc.status, acc.cycles = am.ST_DONE, e
                return e
            e += 1
        if not direct and ta <= tc:
            array_edge(j, ta)
            j += 1
    raise ModelError(f"job not done after {MAX_EDGES} edges")


def cycles_lower_bound(m, k, n, rows, cols, t_core, t_array, sync=SYNC_STAGES):
    """CYCLES can be no lower than this, whatever the phase and the FIFO
    depths. Derived from the design, not from stream_job(): per tile, from
    the edge t0 that starts it, entry i is pushed no earlier than
    t0 + (i + 2) * t_core; the array takes it more than sync * t_array after
    its push and one entry per edge, so the last of the P = ROWS + 1 + M
    entries goes in later than max((P + 1) * t_core, 2 * t_core +
    (P - 1) * t_array) + sync * t_array after t0; its sums leave LATENCY
    array periods later, reach the core more than sync * t_core after that,
    and are written one core cycle later, which ends the tile."""
    p = rows + 1 + m
    b = (max((p + 1) * t_core, 2 * t_core + (p - 1) * t_array)
         + (sync + am.latency(rows, cols)) * t_array + (sync + 1) * t_core)
    per_tile = b // t_core + 1            # whole core cycles, strictly more than b
    return am.CHECK_CYCLES + am.ceil_div(k, rows) * am.ceil_div(n, cols) * per_tile


# --- self-check ---------------------------------------------------------------

def load(acc, a, w, rng):
    """Shape in the registers, A and W in the buffers (padding random), C
    random: what run_job() does, without starting."""
    am.run_job(acc, a, w, rng)                  # loads, then runs the direct model
    acc.c[:] = rng.integers(0, 256, size=acc.buf_bytes, dtype=np.uint8).tobytes()


def fail(msg):
    sys.exit(f"FAIL {msg}")


def clone(acc):
    b = am.Accel(acc.rows, acc.cols, acc.buf_bytes)
    b.a[:], b.w[:], b.c[:] = acc.a, acc.w, acc.c
    b.m, b.k, b.n = acc.m, acc.k, acc.n
    return b


# Clock pairs (core, array) in ps, with the array's phases to try: equal,
# nearly equal, both ways faster, far apart, and an edge-sharing pair.
CLOCKS = [(10_000, 10_000), (10_000, 10_030), (10_000, 13_700), (10_000, 7_300),
          (10_000, 31_000), (10_000, 3_100), (10_000, 20_000), (10_000, 5_000)]


def check_c(acc, a, w, before, name):
    m, n = a.shape[0], w.shape[1]
    cols = acc.cols
    nt = am.ceil_div(n, cols)
    if acc.status != am.ST_DONE:
        fail(f"{name}: status {acc.status}")
    if not np.array_equal(am.unpack_c(acc.c, m, n, cols), gemm(a, w)):
        fail(f"{name}: C")
    words = np.frombuffer(bytes(acc.c[:m * nt * cols * 4]), dtype="<i4").reshape(m, -1)
    if np.any(words[:, n:]):
        fail(f"{name}: C padding not zero")
    if bytes(acc.c[m * nt * cols * 4:]) != before[m * nt * cols * 4:]:
        fail(f"{name}: wrote past C")


def main():
    rng = np.random.default_rng(2)
    cases = {}

    def count(name):
        cases[name] = cases.get(name, 0) + 1

    i8 = lambda *s: rng.integers(-128, 128, size=s)

    for rows, cols, buf in ((4, 4, 1024), (16, 16, 16384), (4, 8, 4096)):
        shapes = [tuple(int(x) for x in rng.integers(1, 3 * max(rows, cols) + 1, size=3))
                  for _ in range(40)]
        shapes += [(1, 1, 1), (1, rows, cols), (rows, rows + 1, cols - 1), (2, rows - 1, cols + 1)]
        for m, k, n in shapes:
            a, w = i8(m, k), i8(k, n)
            acc = am.Accel(rows, cols, buf)
            load(acc, a, w, rng)

            # ARRAY_CDC = 0: exactly accel_model, cycles and every byte of C
            ref, got = clone(acc), clone(acc)
            ref.run()
            stream_job(got, direct=True)
            if got.cycles != am.job_cycles(m, k, n, rows, cols) or got.status != am.ST_DONE:
                fail(f"{rows}x{cols} direct {m}x{k}x{n}: cycles {got.cycles}, "
                      f"want {am.job_cycles(m, k, n, rows, cols)}")
            if bytes(got.c) != bytes(ref.c):
                fail(f"{rows}x{cols} direct {m}x{k}x{n}: C differs from accel_model")
            count(f"{rows}x{cols} direct = accel_model")

            # through the FIFOs: C bit-exact, CYCLES above the bound
            for t_core, t_array in CLOCKS:
                for phase in (0, int(rng.integers(1, t_array))):
                    in_d = int(rng.choice([2, 4, 16]))
                    out_d = int(rng.choice([1, 2, 8, 32]))
                    got = clone(acc)
                    try:
                        cyc = stream_job(got, t_core, t_array, phase, in_depth=in_d, out_depth=out_d)
                    except ModelError as ex:
                        fail(f"{rows}x{cols} {m}x{k}x{n} at {t_core}/{t_array} ps "
                             f"phase {phase} depths {in_d}/{out_d}: {ex}")
                    name = f"{rows}x{cols} {m}x{k}x{n} at {t_core}/{t_array}+{phase}"
                    check_c(got, a, w, bytes(acc.c), name)
                    lo = cycles_lower_bound(m, k, n, rows, cols, t_core, t_array)
                    if cyc < lo:
                        fail(f"{name}: {cyc} cycles, below the bound {lo}")
                    count(f"{rows}x{cols} through the FIFOs, C exact, CYCLES >= bound")

        # refused shapes: nothing computed, CHECK_CYCLES, whatever the clocks
        for m, k, n in ((0, 1, 1), (1, 0, 1), (1, 1, 0), (buf // rows + 1, 1, 1)):
            acc = am.Accel(rows, cols, buf)
            acc.m, acc.k, acc.n = m, k, n
            before = bytes(acc.c)
            if stream_job(acc, 10_000, 31_000) != am.CHECK_CYCLES or acc.status != am.ST_ERROR \
                    or bytes(acc.c) != before:
                fail(f"{rows}x{cols} refuses {m}x{k}x{n}")
            count(f"{rows}x{cols} refused shapes")

    # Equal clocks, FIFOs deep enough not to throttle: every tile costs
    # 2 * SYNC_STAGES + 1 core cycles more than ARRAY_CDC = 0 with the edges
    # apart (each crossing waits SYNC_STAGES periods plus the fraction of one
    # to the next edge, the two fractions summing to one period), and
    # 2 * SYNC_STAGES + 2 with the edges together (a full period each).
    for m, k, n in ((1, 16, 16), (16, 16, 16), (40, 48, 33), (100, 16, 16)):
        a, w = i8(m, k), i8(k, n)
        t = am.ceil_div(k, 16) * am.ceil_div(n, 16)
        for phase, extra in ((0, 2 * SYNC_STAGES + 2), (2_500, 2 * SYNC_STAGES + 1),
                             (9_999, 2 * SYNC_STAGES + 1)):
            acc = am.Accel()
            load(acc, a, w, rng)
            cyc = stream_job(acc, 10_000, 10_000, phase, out_depth=1024)
            if cyc != am.job_cycles(m, k, n, 16, 16) + t * extra:
                fail(f"equal clocks {m}x{k}x{n} phase {phase}: {cyc}, want "
                     f"{am.job_cycles(m, k, n, 16, 16)} + {t} * {extra}")
            count("16x16 equal clocks: exact cost per tile")

    # Throughput: one row per cycle of the slower clock. Adding D rows to a
    # one-tile job adds D core cycles, or D * t_array / t_core when the array
    # is slower, within a cycle either way for the phase.
    for t_array in (5_000, 10_000, 13_700, 20_000, 31_000):
        for phase in (0, 3_333):
            cyc = []
            for m in (64, 64 + 96):
                acc = am.Accel()
                load(acc, i8(m, 16), i8(16, 16), rng)
                cyc.append(stream_job(acc, 10_000, t_array, phase % t_array))
            want = 96 * max(1.0, t_array / 10_000)
            if abs((cyc[1] - cyc[0]) - want) > 1.5:
                fail(f"rate at {t_array} ps: 96 rows cost {cyc[1] - cyc[0]} cycles, want {want:.0f}")
            count("16x16 throughput, one row per slower cycle")

    # The spacing check itself (the schedule never comes near it): a shift
    # ROWS + COLS/2 - 2 edges after a swap is refused, one edge later taken.
    for rows, cols in ((4, 4), (16, 16), (4, 8)):
        gap = rows + cols // 2 - 2
        for d, ok in ((gap, False), (gap + 1, True)):
            arr = Array(rows, cols)
            arr.take(("swap", None), 10)
            try:
                arr.take(("shift", np.zeros(cols, dtype=np.int64)), 10 + d)
                took = True
            except ModelError:
                took = False
            if took != ok:
                fail(f"{rows}x{cols}: shift {d} edges after a swap {'refused' if ok else 'taken'}")
            count("array: shift too soon after a swap refused")

    for name, nn in cases.items():
        print(f"  {nn:5d}  {name}")
    print(f"accel CDC model: {sum(cases.values())} checks passed")


def costs():
    """What clk_array's frequency costs a 16x16 job (core at 100 MHz),
    over PHASES phases, and the smallest output FIFO that costs nothing."""
    rng = np.random.default_rng(3)
    t_core, phases = 10_000, 20
    shapes = ((16, 16, 16), (64, 64, 64), (256, 16, 16))
    ratios = (2.0, 1.25, 1.0, 0.8, 0.5, 0.25)          # f_array / f_core
    depths = (8, 16, 24, 32, 48, 64)
    jobs = {}
    for m, k, n in shapes:
        acc = am.Accel()
        load(acc, rng.integers(-128, 128, size=(m, k)), rng.integers(-128, 128, size=(k, n)), rng)
        jobs[(m, k, n)] = acc

    def span(acc, t_array, out_depth):
        cyc = [stream_job(clone(acc), t_core, t_array, p * t_array // phases, out_depth=out_depth)
               for p in range(phases)]
        return min(cyc), max(cyc)

    print(f"16x16, core {1e6 / t_core:.0f} MHz, SYNC_STAGES {SYNC_STAGES}, input FIFO {IN_DEPTH}, "
          f"{phases} phases; CYCLES min-max (x ARRAY_CDC=0); smallest output FIFO costing nothing")
    print(f"{'f_array':>9} " + " ".join(f"{f'{m}x{k}x{n}':>22}" for m, k, n in shapes) + "   out FIFO")
    for ratio in ratios:
        t_array = round(t_core / ratio)
        cells, need = [], 0
        for shape, acc in jobs.items():
            base = am.job_cycles(*shape, 16, 16)
            best = span(acc, t_array, 1024)
            cells.append(f"{best[0]}-{best[1]} ({best[1] / base:.2f}x)")
            need = max(need, next((d for d in depths if span(acc, t_array, d) == best), 1024))
        print(f"{1e6 / t_array:6.0f} MHz " + " ".join(f"{c:>22}" for c in cells) + f"   {need:>8}")
    print("ARRAY_CDC=0: " + ", ".join(f"{m}x{k}x{n} {am.job_cycles(m, k, n, 16, 16)}"
                                       for m, k, n in shapes))


if __name__ == "__main__":
    costs() if "--costs" in sys.argv[1:] else main()
