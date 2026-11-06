#!/usr/bin/env python3
"""Check the Python golden model's M extension (tb/cocotb/rv32i_model.py)
against spike's reference vectors, as sw/model/m_check.c does for the C model.

    m_check.py <m_vectors.txt>

Each vector runs as a program: lui/addi load the operands, then the M
instruction. Every M encoding must also trap with M off. Exits non-zero on any
failure.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tb/cocotb"))
from rv32i_model import run_model  # noqa: E402

OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]


def li(rd, v):
    hi = (v + 0x800) & 0xFFFF_F000
    return [hi | rd << 7 | 0x37, ((v - hi) & 0xFFF) << 20 | rd << 15 | rd << 7 | 0x13]


def program(f3, a, b):
    """x3 = <op> x1, x2 with x1 = a, x2 = b."""
    return li(1, a) + li(2, b) + [0x01 << 25 | 2 << 20 | 1 << 15 | f3 << 12 | 3 << 7 | 0x33]


def main(path):
    fails, bad = [], 0
    for f3, op in enumerate(OPS):
        traces = []
        _, model = run_model(program(f3, 7, 3), traces=traces)
        if not (model.halted and traces[-1]["trap"] and traces[-1]["rd_addr"] == 0):
            fails.append(f"{op} with M off did not trap")
    n = 0
    for line in Path(path).read_text().splitlines():
        if line.startswith("#"):
            continue
        op, a, b, want = line.split()
        a, b, want = int(a, 16), int(b, 16), int(want, 16)
        traces = []
        wbs, model = run_model(program(OPS.index(op), a, b), traces=traces, m_ext=True)
        n += 1
        if model.halted or wbs[-1] != (3, want) or traces[-1]["rd_wdata"] != want:
            fails.append(f"{op} {a:08x} {b:08x}: got {wbs[-1]} want {want:08x}")
            bad += 1
    if n == 0:
        fails.append(f"no vectors in {path}")
    for f in fails[:20]:
        print("FAIL", f)
    print(f"{n - bad} / {n} M vectors match spike, {8 - (len(fails) - bad)} / 8 trap with M off: "
          f"{'FAIL' if fails else 'pass'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
