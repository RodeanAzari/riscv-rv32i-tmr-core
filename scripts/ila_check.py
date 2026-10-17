#!/usr/bin/env python3
"""Check an ILA capture of the core's pipeline registers (syn/ila_capture.tcl).

Usage: scripts/ila_check.py <ila_capture.csv> [summary.txt]

The stages after ID always advance (docs/PROGRESS.md; riscv_core.sv), so in
consecutive samples EX/MEM must hold what ID/EX held, and MEM/WB what EX/MEM
held -- pc and instruction both. A capture that breaks that is either wired
to the wrong nets or not sampling on the core clock. Every pc must also be
word-aligned. Then, as information, the cycles the capture shows stalled
(IF/ID held, a bubble in ID/EX) and flushed (a NOP bubble entering ID/EX
behind a redirect).
"""
import csv
import sys

NOP = 0x0000_0013
STAGES = ("if_id", "id_ex", "ex_mem", "mem_wb")


def load(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    header, data = rows[0], rows[2:]          # rows[1] is the radix line
    cols = {}
    for i, name in enumerate(header):
        # g_ila.ex_mem_pc_p[31:0] -> ex_mem_pc
        short = name.split(".")[-1].split("[")[0]
        cols[short[:-2] if short.endswith("_p") else short] = i
    return [{k: int(r[i], 16) for k, i in cols.items()
             if k not in ("Sample in Buffer", "Sample in Window", "TRIGGER")}
            for r in data]


def main():
    samples = load(sys.argv[1])
    errors = []
    for t in range(len(samples) - 1):
        a, b = samples[t], samples[t + 1]
        for src, dst in (("id_ex", "ex_mem"), ("ex_mem", "mem_wb")):
            for field in ("pc", "instr"):
                if b[f"{dst}_{field}"] != a[f"{src}_{field}"]:
                    errors.append(f"sample {t + 1}: {dst}_{field} {b[f'{dst}_{field}']:08x}"
                                  f" != {src}_{field} {a[f'{src}_{field}']:08x} a cycle before")
    for t, s in enumerate(samples):
        for st in STAGES:
            if s[f"{st}_pc"] & 3:
                errors.append(f"sample {t}: {st}_pc {s[f'{st}_pc']:08x} misaligned")

    stalls = sum(1 for a, b in zip(samples, samples[1:])
                 if b["if_id_pc"] == a["if_id_pc"] and b["id_ex_pc"] == a["if_id_pc"]
                 and b["if_id_instr"] == a["if_id_instr"])
    flushes = sum(1 for s in samples
                  if s["id_ex_instr"] == NOP and s["id_ex_pc"] == 0)
    writes = sum(s["wb_rd_we"] for s in samples)

    lines = [f"ILA capture: {len(samples)} samples on the core clock",
             f"stage advance EX->MEM->WB (pc, instr): "
             f"{'OK' if not errors else f'{len(errors)} violations'}",
             f"cycles holding a stall: {stalls}; flush bubbles in ID/EX: {flushes}; "
             f"register writes: {writes}",
             f"pc range in WB: {min(s['mem_wb_pc'] for s in samples):08x}"
             f"-{max(s['mem_wb_pc'] for s in samples):08x}"]
    text = "\n".join(lines + errors[:20]) + "\n"
    print(text, end="")
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as f:
            f.write(text)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
