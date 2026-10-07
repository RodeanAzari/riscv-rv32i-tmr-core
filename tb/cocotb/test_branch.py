"""Branch comparator: all six conditions, and the two reserved funct3 values.

The reference uses Python's own signed comparison, not the sign-bit shortcut
the RTL takes, so a mistake in the shortcut cannot be repeated here and cancel
out.

Operands are chosen where comparators break: the ALU's corner values crossed
with each other, then random pairs that are equal, one apart (the carry chain's
whole length decides those), or of opposite sign (the shortcut decides those).
"""

import random

import cocotb
from cocotb.triggers import Timer

from test_alu import CORNERS, MASK32, signed

BEQ, BNE, BLT, BGE, BLTU, BGEU = 0b000, 0b001, 0b100, 0b101, 0b110, 0b111


def branch_model(a, b, funct3):
    return {
        BEQ: a == b,
        BNE: a != b,
        BLT: signed(a) < signed(b),
        BGE: signed(a) >= signed(b),
        BLTU: a < b,
        BGEU: a >= b,
    }.get(funct3, False)                    # 010, 011 reserved: never taken


async def check(dut, a, b):
    dut.a_i.value = a
    dut.b_i.value = b
    for funct3 in range(8):
        dut.funct3_i.value = funct3
        await Timer(1, unit="ns")
        got = int(dut.cond_o.value)
        want = int(branch_model(a, b, funct3))
        assert got == want, f"funct3={funct3:03b} a={a:#010x} b={b:#010x}: got {got}"


@cocotb.test()
async def test_corner_pairs(dut):
    """Every pair of corner values, both orders, all eight funct3."""
    for a in CORNERS:
        for b in CORNERS:
            await check(dut, a, b)


@cocotb.test()
async def test_random_near_pairs(dut):
    """Equal, adjacent and opposite-sign pairs drawn at random."""
    rng = random.Random(1)
    for _ in range(2000):
        a = rng.getrandbits(32)
        b = rng.choice([
            a,
            (a + 1) & MASK32,
            (a - 1) & MASK32,
            a ^ 0x8000_0000,                # same magnitude bits, other sign
            rng.getrandbits(32),
        ])
        await check(dut, a, b)
