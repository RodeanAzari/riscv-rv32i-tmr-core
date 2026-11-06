#!/usr/bin/env python3
"""Generate the M-extension reference vectors from spike.

    scripts/m_vectors.py <out.txt>

Every pair of edge values (zero, one, the extremes, powers of two either side
of the 16-bit split the multiplier will use) and a seeded set of random pairs,
through all 8 M instructions, run on spike --isa=rv32im. The results are read
back from spike's commit log, so the reference is spike's arithmetic, not ours.
The output is committed (sw/model/m_vectors.txt) so the checks run without
spike, in CI. Each line: op a b result, in hex.
"""
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
EDGES = [0x0000_0000, 0x0000_0001, 0x0000_0002, 0x0000_0003, 0xFFFF_FFFF,
         0xFFFF_FFFE, 0x8000_0000, 0x8000_0001, 0x7FFF_FFFF, 0x7FFF_FFFE,
         0x0000_7FFF, 0x0000_8000, 0x0000_FFFF, 0x0001_0000, 0xFFFF_0000,
         0xFFFF_8000, 0x1234_5678, 0xDEAD_BEEF]
N_RANDOM = 1000
SEED = 20261106

TOOLS = Path.home() / "riscv-toolchain/bin"
COMMIT = re.compile(r"core\s+0: \d+ 0x[0-9a-f]+ \((0x[0-9a-f]+)\) x12\s+(0x[0-9a-f]+)")


def operands():
    rng = random.Random(SEED)
    pairs = [(a, b) for a in EDGES for b in EDGES]
    for _ in range(N_RANDOM):
        # Half fully random, half with small divisors so DIV/REM see small
        # quotients and remainders as well as 0 and 1.
        a = rng.getrandbits(32)
        b = rng.getrandbits(32) if rng.random() < 0.5 else rng.getrandbits(rng.randint(1, 16))
        if rng.random() < 0.25:
            b = (-b) & 0xFFFF_FFFF
        pairs.append((a, b))
    return pairs


def main(out):
    vectors = [(op, a, b) for a, b in operands() for op in OPS]
    asm = [".section .text.init", ".globl _start", "_start:"]
    for op, a, b in vectors:
        asm += [f"li a0, {a:#x}", f"li a1, {b:#x}", f"{op} a2, a0, a1"]
    asm += ["li t0, 1", "la t1, tohost", "sw t0, 0(t1)", "1: j 1b",
            '.section .tohost, "aw", @progbits', ".align 6",
            ".globl tohost", "tohost: .dword 0", ".globl fromhost", "fromhost: .dword 0"]
    with tempfile.TemporaryDirectory() as d:
        src, ld, elf = Path(d, "m.S"), Path(d, "m.ld"), Path(d, "m.elf")
        src.write_text("\n".join(asm) + "\n")
        # spike's RAM starts at 0x80000000 and its exit is a store to tohost.
        ld.write_text("SECTIONS { . = 0x80000000; .text : { *(.text.init) }"
                      " .tohost : { *(.tohost) } }\n")
        subprocess.run([TOOLS / "riscv32-unknown-elf-gcc", "-march=rv32im", "-mabi=ilp32",
                        "-nostdlib", "-nostartfiles", "-static", "-Wl,--no-warn-rwx-segments",
                        "-T", ld, "-o", elf, src], check=True)
        log = subprocess.run([TOOLS / "spike", "--isa=rv32im", "--log-commits", elf],
                             check=True, capture_output=True, text=True).stderr
    # The M instructions are the x12 writes with opcode OP and funct7 1.
    results = [int(v, 16) for insn, v in COMMIT.findall(log)
               if int(insn, 16) & 0xFE00_007F == 0x0200_0033]
    if len(results) != len(vectors):
        sys.exit(f"spike: {len(results)} M results for {len(vectors)} vectors")
    with open(out, "w") as f:
        f.write(f"# M-extension reference vectors from spike --isa=rv32im "
                f"(scripts/m_vectors.py, seed {SEED}): op a b result\n")
        for (op, a, b), r in zip(vectors, results):
            f.write(f"{op} {a:08x} {b:08x} {r:08x}\n")
    print(f"{len(vectors)} vectors -> {out}")


if __name__ == "__main__":
    main(sys.argv[1])
