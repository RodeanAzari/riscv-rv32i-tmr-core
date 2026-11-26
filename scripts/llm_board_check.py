#!/usr/bin/env python3
"""Check a board transcript of the tiny-LLM demo (sw/llm/llm_app.c) against
the golden model's vectors, and turn its cycle counts into tokens/s.

Every "llm: <sw|array> <pos> <token> <crc> <cycles>" line must match
llm_vectors.txt's position (next token and CRC-32 of the logits), both runs
must cover every position, and the summary must say done without failure.
Speed is forward-pass cycles of the core clock (the CYCLE register around
llm_forward; UART printing excluded) at the clock given, 100 MHz on the
Arty. Prints a report; exits 1 on any mismatch.

  scripts/llm_board_check.py <transcript> <llm_vectors.txt> [clock MHz]
"""

from pathlib import Path
import re
import sys


def main() -> int:
    text = Path(sys.argv[1]).read_text()
    vectors = Path(sys.argv[2]).read_text()
    mhz = float(sys.argv[3]) if len(sys.argv) > 3 else 100.0
    want = {}
    for line in vectors.splitlines():
        f = line.split()
        if f and f[0].isdigit():
            want[int(f[0])] = (int(f[1]), f[2])

    runs = {"sw": {}, "array": {}}
    for mode, pos, tok, crc, cyc in re.findall(
            r"llm: (sw|array) (\d+) (\d+) ([0-9a-f]{8}) (\d+)", text):
        runs[mode][int(pos)] = (int(tok), crc, int(cyc))

    bad = 0
    for mode, got in runs.items():
        if sorted(got) != sorted(want):
            print(f"FAIL {mode}: positions {len(got)}, model has {len(want)}")
            bad += 1
        for pos, (tok, crc, _) in sorted(got.items()):
            if want.get(pos) != (tok, crc):
                print(f"FAIL {mode} position {pos}: {tok} {crc}, model {want.get(pos)}")
                bad += 1
    if not re.search(r"llm: done\r?$", text, re.M) or "FAIL" in text:
        print("FAIL the run did not finish cleanly")
        bad += 1

    print(f"positions per run  {len(want)} (prompt included; "
          f"cycles of the {mhz:g} MHz core clock, forward pass only)")
    totals = {}
    for mode, got in runs.items():
        if not got:
            continue
        cyc = [c for _, _, c in got.values()]
        totals[mode] = sum(cyc)
        print(f"{mode:<6} total {sum(cyc):>11,} cycles, per position "
              f"min {min(cyc):,} max {max(cyc):,}, "
              f"{len(cyc) * mhz * 1e6 / sum(cyc):.2f} tokens/s")
    if len(totals) == 2:
        print(f"speedup (array over sw) {totals['sw'] / totals['array']:.2f}x")
    print(f"tokens and logits equal to the golden model: {'yes' if not bad else 'NO'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
