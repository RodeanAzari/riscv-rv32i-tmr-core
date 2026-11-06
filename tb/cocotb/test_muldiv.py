"""M-extension unit (rtl/core/riscv_muldiv.sv) alone, against spike and the
golden model.

Results: every vector in sw/model/m_vectors.txt (spike's own answers, edge
pairs and random), then random operands against rv32i_model.muldiv, which is
itself checked against those vectors (make model-test).

Handshake, driven as the core will: valid_i held from the first cycle until
the cycle ack_i is given. The operands are scrambled after the first cycle --
the unit must have captured them, because in the core the forwarding paths
move on while the instruction waits. ack_i is delayed at random, as a MEM_WAIT
hold would delay it, and the result must not move meanwhile.

Timing is part of the spec (docs/PROGRESS.md): an M instruction spends exactly
3 cycles in EX for MUL*, XLEN + 2 = 34 for DIV*, whatever the operands.
"""

import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

from rv32i_model import muldiv

OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
XLEN = 32
EX_CYCLES = {f3: 3 if f3 < 4 else XLEN + 2 for f3 in range(8)}
VECTORS = Path(__file__).resolve().parents[2] / "sw/model/m_vectors.txt"


def load_vectors():
    out = []
    for line in VECTORS.read_text().splitlines():
        if not line.startswith("#"):
            op, a, b, r = line.split()
            out.append((OPS.index(op), int(a, 16), int(b, 16), int(r, 16)))
    assert out, f"no vectors in {VECTORS}"
    return out


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    dut.rst_i.value = 1
    dut.valid_i.value = 0
    dut.ack_i.value = 0
    dut.a_i.value = 0
    dut.b_i.value = 0
    dut.funct3_i.value = 0
    for _ in range(2):
        await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0


async def run_op(dut, f3, a, b, rng, max_ack_delay=0):
    """One M instruction through EX, starting at a falling edge with the unit
    idle. Returns (result, cycles in EX up to and including the first with
    done_o: the unit's latency, not counting the ack delay). Leaves valid_i
    low."""
    dut.valid_i.value = 1
    dut.ack_i.value = 0
    dut.funct3_i.value = f3
    dut.a_i.value = a
    dut.b_i.value = b
    cycles = 0
    while True:
        await FallingEdge(dut.clk_i)          # cycle `cycles` ended at the rising edge
        cycles += 1
        # The instruction is still in EX; the forwarding paths move on.
        dut.a_i.value = rng.getrandbits(32)
        dut.b_i.value = rng.getrandbits(32)
        dut.funct3_i.value = rng.randrange(8)
        if dut.done_o.value:
            break
        assert cycles <= XLEN + 2, f"{OPS[f3]}: no done after {cycles} cycles"
    result = int(dut.result_o.value)
    for _ in range(rng.randint(0, max_ack_delay)):
        await FallingEdge(dut.clk_i)
        assert dut.done_o.value, f"{OPS[f3]}: done dropped before ack"
        assert int(dut.result_o.value) == result, f"{OPS[f3]}: result moved before ack"
    cycles += 1                                # the done cycle itself is in EX
    dut.ack_i.value = 1
    await FallingEdge(dut.clk_i)
    dut.ack_i.value = 0
    dut.valid_i.value = 0
    assert not dut.done_o.value, f"{OPS[f3]}: done still up after ack"
    return result, cycles


def check(f3, a, b, got, cycles, want):
    assert got == want, f"{OPS[f3]} {a:08x} {b:08x}: got {got:08x} want {want:08x}"
    assert cycles == EX_CYCLES[f3], \
        f"{OPS[f3]} {a:08x} {b:08x}: {cycles} cycles in EX, want {EX_CYCLES[f3]}"


@cocotb.test()
async def test_spike_vectors(dut):
    """Every spike vector, back to back, exact result and cycle count."""
    await setup(dut)
    rng = random.Random(1)
    vectors = load_vectors()
    for f3, a, b, want in vectors:
        got, cycles = await run_op(dut, f3, a, b, rng)
        check(f3, a, b, got, cycles, want)
    dut._log.info(f"{len(vectors)} spike vectors match, cycle counts exact")


@cocotb.test()
async def test_random_vs_model(dut):
    """Random operands and ops with random ack delays and idle gaps."""
    await setup(dut)
    rng = random.Random(2)
    n = 3000
    for _ in range(n):
        f3 = rng.randrange(8)
        a, b = rng.getrandbits(32), rng.getrandbits(rng.choice([32, 32, 16, 4, 1]))
        got, cycles = await run_op(dut, f3, a, b, rng, max_ack_delay=3)
        check(f3, a, b, got, cycles, muldiv(f3, a, b))
        for _ in range(rng.choice([0, 0, 0, 1, 3])):
            await FallingEdge(dut.clk_i)
    dut._log.info(f"{n} random ops match the golden model")


@cocotb.test()
async def test_reset_mid_op(dut):
    """Reset during a divide or multiply returns the unit to idle: done low,
    and the next op runs its full, correct course."""
    await setup(dut)
    rng = random.Random(3)
    for f3, stop in [(4, 1), (4, 10), (6, XLEN + 1), (0, 1), (1, 2), (5, XLEN + 2)]:
        dut.valid_i.value, dut.funct3_i.value = 1, f3
        dut.a_i.value, dut.b_i.value = 0xDEAD_BEEF, 7
        for _ in range(stop):
            await FallingEdge(dut.clk_i)
        dut.rst_i.value = 1
        dut.valid_i.value = 0
        await FallingEdge(dut.clk_i)
        dut.rst_i.value = 0
        assert not dut.done_o.value, f"{OPS[f3]}: done after reset at cycle {stop}"
        await FallingEdge(dut.clk_i)
        assert not dut.done_o.value, f"{OPS[f3]}: done while idle after reset"
        a, b = 0x8000_0000, 0xFFFF_FFFF
        got, cycles = await run_op(dut, f3, a, b, rng)
        check(f3, a, b, got, cycles, muldiv(f3, a, b))
