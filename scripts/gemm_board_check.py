#!/usr/bin/env python3
"""Check a board transcript of gemmtest built with ARRAY_CDC against the
golden model (sw/model/accel_cdc_model.py).

On the board the core runs at 100 MHz and the array at 800 MHz / d, d set
by gemmtest through the DRP ("array clock /d" lines; 8 at configuration).
Both MMCMs are deskewed to the one 100 MHz oscillator, so the array's
edges sit at fixed offsets from the core's: with d = 8 they coincide
(phase 0); with d = 10 (12.5 ns) an edge coincides with a core edge every
50 ns, so a job can start at any of the phases {0, 2.5, 5, 7.5, 10} ns,
which one depending on where the MMCM's counters started. Each job's
CYCLES must equal the model's at one of the phases its clock allows; the
transcript's summary must be all passes.

  scripts/gemm_board_check.py docs/reports/gemmtest_board_cdc.txt
"""

from math import gcd
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "sw" / "model"))
import accel_model as am  # noqa: E402
import accel_cdc_model as acm  # noqa: E402

T_CORE = 10_000                 # ps
VCO_PS = 1_250                  # 800 MHz
START_DIV = 8


def phases(t_array: int) -> list[int]:
    """Every offset of an array edge from a core edge, both locked to one
    reference: the multiples of gcd(t_core, t_array) below t_array."""
    g = gcd(T_CORE, t_array)
    return list(range(0, t_array, g))


def main() -> int:
    text = Path(sys.argv[1]).read_text()
    div, bad, n = START_DIV, 0, 0
    for line in text.splitlines():
        if m := re.search(r"gemmtest: array clock /(\d+), rc (-?\d+)", line):
            if m[2] != "0":
                print(f"FAIL clock change to /{m[1]}: rc {m[2]}")
                bad += 1
            div = int(m[1])
            continue
        m = re.search(r"gemmtest: (\d+)x(\d+)x(\d+) ok, job (\d+) cycles", line)
        if not m:
            continue
        mm, k, nn, cyc = (int(x) for x in m.groups())
        t_array = VCO_PS * div
        allowed = {}
        for ph in phases(t_array):
            acc = am.Accel()
            acc.m, acc.k, acc.n = mm, k, nn
            allowed.setdefault(acm.stream_job(acc, T_CORE, t_array, ph), []).append(ph)
        n += 1
        ok = cyc in allowed
        bad += not ok
        where = f"phase {allowed[cyc]} ps" if ok else f"model {sorted(allowed)}"
        print(f"{'ok  ' if ok else 'FAIL'} /{div:<2} {mm}x{k}x{nn}: {cyc} cycles, {where}")
    summary = re.search(r"gemmtest: (\d+)/(\d+) ok", text)
    if not summary or summary[1] != summary[2]:
        print("FAIL summary:", summary[0] if summary else "missing")
        bad += 1
    if n == 0:
        print("FAIL no jobs in the transcript")
        bad += 1
    print(f"{n} jobs, {bad} failures")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
