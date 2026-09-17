"""ALU: every RV32I operation against an independent Python model.

The model is written from the ISA definition, not derived from the RTL, so a
misreading of the spec cannot cancel itself out. CLAUDE.md 11: golden model
before RTL.

Operand corners are chosen rather than sampled. Sign boundaries, shift-by-zero
and shift-by-31, and the INT32_MIN cases are where ALU bugs live; uniform
random 32-bit values hit almost none of them.
"""

import random

import cocotb
from cocotb.triggers import Timer

MASK32 = 0xFFFF_FFFF

F3_ADD_SUB = 0b000
F3_SLL     = 0b001
F3_SLT     = 0b010
F3_SLTU    = 0b011
F3_XOR     = 0b100
F3_SRL_SRA = 0b101
F3_OR      = 0b110
F3_AND     = 0b111

# Values that break ALUs: zero, one, all-ones (-1), INT32_MIN, INT32_MAX, the
# bit either side of the sign change, and a couple of arbitrary patterns.
CORNERS = [
    0x0000_0000, 0x0000_0001, 0xFFFF_FFFF, 0x8000_0000, 0x7FFF_FFFF,
    0x8000_0001, 0x7FFF_FFFE, 0x0000_001F, 0x0000_0020, 0xDEAD_BEEF,
    0x5555_5555, 0xAAAA_AAAA,
]


def signed(value):
    """Interpret a 32-bit pattern as two's complement."""
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


def alu_model(a, b, funct3, alt):
    """Independent reference. Written from the RV32I spec."""
    shamt = b & 0x1F
    if funct3 == F3_ADD_SUB:
        return ((a - b) if alt else (a + b)) & MASK32
    if funct3 == F3_SLL:
        return (a << shamt) & MASK32
    if funct3 == F3_SLT:
        return 1 if signed(a) < signed(b) else 0
    if funct3 == F3_SLTU:
        return 1 if a < b else 0
    if funct3 == F3_XOR:
        return a ^ b
    if funct3 == F3_SRL_SRA:
        if alt:
            return (signed(a) >> shamt) & MASK32   # Python >> on a negative
        return (a & MASK32) >> shamt               # int is arithmetic
    if funct3 == F3_OR:
        return a | b
    if funct3 == F3_AND:
        return a & b
    raise AssertionError(f"bad funct3 {funct3}")


async def run(dut, a, b, funct3, alt):
    dut.a_i.value = a
    dut.b_i.value = b
    dut.funct3_i.value = funct3
    dut.alt_i.value = alt
    await Timer(1, unit="ns")
    got = int(dut.result_o.value)
    want = alu_model(a, b, funct3, alt)
    assert got == want, (
        f"a={a:#010x} b={b:#010x} funct3={funct3:#05b} alt={alt}: "
        f"got {got:#010x}, want {want:#010x}"
    )
    return got


async def sweep(dut, funct3, alt):
    for a in CORNERS:
        for b in CORNERS:
            await run(dut, a, b, funct3, alt)


@cocotb.test()
async def test_add(dut):
    await sweep(dut, F3_ADD_SUB, 0)


@cocotb.test()
async def test_sub(dut):
    await sweep(dut, F3_ADD_SUB, 1)


@cocotb.test()
async def test_add_wraps(dut):
    """Addition wraps mod 2^32; RV32I has no arithmetic trap."""
    assert await run(dut, 0xFFFF_FFFF, 0x0000_0001, F3_ADD_SUB, 0) == 0
    assert await run(dut, 0x7FFF_FFFF, 0x0000_0001, F3_ADD_SUB, 0) == 0x8000_0000


@cocotb.test()
async def test_sub_borrows(dut):
    assert await run(dut, 0x0000_0000, 0x0000_0001, F3_ADD_SUB, 1) == 0xFFFF_FFFF


@cocotb.test()
async def test_and_or_xor(dut):
    for funct3 in (F3_AND, F3_OR, F3_XOR):
        await sweep(dut, funct3, 0)


@cocotb.test()
async def test_sll(dut):
    await sweep(dut, F3_SLL, 0)


@cocotb.test()
async def test_srl(dut):
    await sweep(dut, F3_SRL_SRA, 0)


@cocotb.test()
async def test_sra(dut):
    await sweep(dut, F3_SRL_SRA, 1)


@cocotb.test()
async def test_sra_sign_fills(dut):
    """SRA of a negative value fills with ones. SRL of the same fills zeros.

    This is the pair that catches a missing $signed() cast: both behave
    identically on non-negative operands, so the bug is invisible until a
    negative value is shifted.
    """
    assert await run(dut, 0x8000_0000, 4, F3_SRL_SRA, 1) == 0xF800_0000
    assert await run(dut, 0x8000_0000, 4, F3_SRL_SRA, 0) == 0x0800_0000
    assert await run(dut, 0xFFFF_FFFF, 31, F3_SRL_SRA, 1) == 0xFFFF_FFFF
    assert await run(dut, 0xFFFF_FFFF, 31, F3_SRL_SRA, 0) == 0x0000_0001


@cocotb.test()
async def test_shift_uses_low_five_bits_only(dut):
    """RV32I defines shifts to use operand bits [4:0]; the rest are ignored."""
    for funct3, alt in ((F3_SLL, 0), (F3_SRL_SRA, 0), (F3_SRL_SRA, 1)):
        for extra in (0x0000_0020, 0x0000_03E0, 0xFFFF_FFE0):
            bare = await run(dut, 0xDEAD_BEEF, extra & 0x1F, funct3, alt)
            wide = await run(dut, 0xDEAD_BEEF, extra, funct3, alt)
            assert bare == wide, f"shift used more than 5 bits ({extra:#010x})"


@cocotb.test()
async def test_shift_by_zero_is_identity(dut):
    for funct3, alt in ((F3_SLL, 0), (F3_SRL_SRA, 0), (F3_SRL_SRA, 1)):
        assert await run(dut, 0xDEAD_BEEF, 0, funct3, alt) == 0xDEAD_BEEF


@cocotb.test()
async def test_slt_signed(dut):
    await sweep(dut, F3_SLT, 0)


@cocotb.test()
async def test_sltu_unsigned(dut):
    await sweep(dut, F3_SLTU, 0)


@cocotb.test()
async def test_slt_vs_sltu_disagree_on_sign(dut):
    """The case that separates the two comparisons.

    -1 (0xFFFFFFFF) is less than 1 signed, but greater unsigned. An ALU that
    implements SLT as an unsigned compare passes every test using only small
    positive values.
    """
    assert await run(dut, 0xFFFF_FFFF, 0x0000_0001, F3_SLT, 0) == 1
    assert await run(dut, 0xFFFF_FFFF, 0x0000_0001, F3_SLTU, 0) == 0
    assert await run(dut, 0x8000_0000, 0x0000_0000, F3_SLT, 0) == 1
    assert await run(dut, 0x8000_0000, 0x0000_0000, F3_SLTU, 0) == 0


@cocotb.test()
async def test_slt_result_is_zero_or_one(dut):
    """SLT writes a full XLEN word that is exactly 0 or 1, not a wide mask."""
    for funct3 in (F3_SLT, F3_SLTU):
        for a in CORNERS:
            for b in CORNERS:
                assert await run(dut, a, b, funct3, 0) in (0, 1)


@cocotb.test()
async def test_random_against_model(dut):
    """Random sweep on top of the corners, all operations."""
    random.seed(20260917)
    ops = [(F3_ADD_SUB, 0), (F3_ADD_SUB, 1), (F3_SLL, 0), (F3_SLT, 0),
           (F3_SLTU, 0), (F3_XOR, 0), (F3_SRL_SRA, 0), (F3_SRL_SRA, 1),
           (F3_OR, 0), (F3_AND, 0)]
    for _ in range(400):
        funct3, alt = random.choice(ops)
        await run(dut, random.getrandbits(32), random.getrandbits(32), funct3, alt)
