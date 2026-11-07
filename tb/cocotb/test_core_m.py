"""Phase H: the M extension in the core (riscv_core built with M_EXT = 1).

Every check is against the golden model with m_ext on, retirement by
retirement through RVFI (check_rvfi): the register written and its value, the
operands each instruction read, memory, the pc chain, the halt. The operands
matter here: an M instruction waits in EX while the stages after it move on,
so the forwarding paths it read on its first cycle point elsewhere by its
last -- the core must report, and compute with, what it read on the first.

Directed cases first, one per hazard an M instruction can meet; then random
RV32IM programs, dense, few registers, corner operand values; then the exact
cost in cycles of each kind, which is part of the spec (docs/PROGRESS.md).
"""

import cocotb

from rv32i_model import run_model
from test_core import (DMEM_WAIT, ECALL, EBREAK, HALT_TAIL, RANDOM_REGS,
                       check_rvfi, enc_b, enc_i, enc_jal, enc_load, enc_r,
                       enc_s, li, random_instruction, random_mem, run,
                       seeded_rng)

MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU = range(8)
INT_MIN, INT_MAX = 0x8000_0000, 0x7FFF_FFFF
CORNERS = [0, 1, 2, 0xFFFF_FFFF, 0xFFFF_FFFE, INT_MIN, INT_MAX, 0x0000_8000,
           0xFFFF_8000, 0x0001_0000]


def m(funct3, rd, rs1, rs2):
    return enc_r(funct3, rs1, rs2, rd, funct7=0b0000001)


def is_m(insn):
    return insn & 0xFE00_007F == 0x0200_0033


async def check_m(dut, program, mem=None, min_m=1, min_taken=0):
    """Run program on the model (RV32IM) and the core; every retirement,
    every non-x0 writeback in order and the final memory must agree."""
    mem = dict(mem or {})
    want_rvfi = []
    want_wb, model = run_model(program, mem, traces=want_rvfi, m_ext=True)
    assert model.halted, "program ran off its end without halting"
    n_m = sum(is_m(t["insn"]) and not t["trap"] for t in want_rvfi)
    assert n_m >= min_m, f"only {n_m} M instructions executed"
    assert model.taken >= min_taken, f"only {model.taken} redirects"
    # Budget: a divide is 34 cycles in EX, anything else at most 3.
    cycles = 40 * n_m + 3 * len(want_rvfi) + 20
    got_rvfi = []
    got_wb, got_mem = await run(dut, program, dict(mem), cycles=cycles, rvfi=got_rvfi)
    assert int(dut.halt_o.value), "core never halted"
    stats = check_rvfi(got_rvfi, want_rvfi)
    want = [(rd, v) for rd, v in want_wb if rd != 0]
    got = [(rd, v) for rd, v in got_wb if rd != 0]
    for i, (g, w) in enumerate(zip(got, want)):
        assert g == w, f"writeback #{i}: core x{g[0]}={g[1]:#010x}, model x{w[0]}={w[1]:#010x}"
    assert len(got) == len(want), f"core retired {len(got)} writes, model {len(want)}"
    for addr in sorted(set(got_mem) | set(model.mem)):
        assert got_mem.get(addr, 0) == model.mem.get(addr, 0), f"mem[{addr}]"
    return stats, n_m


DIRECTED = {
    # Operands forwarded into the first cycle: lui/addi straight before, so
    # rs1 comes from MEM/WB and rs2 from EX/MEM; then the result is read
    # back to back (EX/MEM) and one later (MEM/WB).
    "forward_in_and_out": li(1, 0x1234_5678) + li(2, 0xDEAD_BEEF) + [
        m(MUL, 3, 1, 2), enc_r(0, 3, 3, 4), enc_r(0, 3, 1, 5)],
    # Each op, dependent chain, operands from the previous M result.
    "chain_all_ops": li(1, 0xFFFF_FFF9) + li(2, 3) + li(3, 5) + li(4, 0xFFFF_0000) + [
        m(f3, 3 + (f3 % 2), 1 if f3 % 2 else 3, 2) for f3 in range(8)] + [
        m(f3, 2, 3, 4) for f3 in range(8)],
    # Corner cases through the core: x / 0, INT_MIN / -1, MULH of extremes.
    "corners": li(1, INT_MIN) + li(2, 0xFFFF_FFFF) + [
        m(DIV, 3, 1, 2), m(REM, 4, 1, 2), m(DIV, 5, 1, 0), m(REMU, 6, 1, 0),
        m(MULH, 7, 1, 1), m(MULHSU, 8, 2, 1), m(MULHU, 9, 2, 2), m(DIVU, 10, 2, 0)],
    # A load feeds an M instruction: the load-use stall, then the wait.
    "load_use_into_m": [enc_load(0b010, 1, 8), m(MUL, 2, 1, 1), m(DIV, 3, 2, 1)],
    # The result is stored straight away (store data forwarded from EX/MEM)
    # and loaded back.
    "store_result": li(1, 77) + [m(MUL, 2, 1, 1), enc_s(16, rs1=0, rs2=2, funct3=0b010),
                                 enc_load(0b010, 3, 16)],
    # A branch on the result, taken, over an M instruction that must never
    # start (it is in IF/ID when the branch redirects).
    "branch_on_result_skips_m": li(1, 6) + li(2, 7) + [
        m(MUL, 3, 1, 2), enc_b(0b001, 3, 0, 8), m(DIV, 4, 3, 3), enc_r(0, 3, 3, 5)],
    # An M instruction at a jump target and one in the jump's shadow.
    "m_at_jump_target": li(1, 9) + [enc_jal(5, 8), m(DIVU, 2, 1, 1), m(REMU, 3, 1, 5)],
    # rd = rs1 = rs2, and rd = x0 (writes nothing, forwards nothing).
    "self_and_x0": li(1, 0x0001_0001) + [m(MUL, 1, 1, 1), m(MUL, 0, 1, 1),
                                         enc_r(0, 0, 1, 2)],
    # Back to back, no dependency, then a halt right behind a divide: the
    # divide retires first, nothing after the halt.
    "back_to_back_then_halt": li(1, 100) + li(2, 7) + [
        m(DIV, 3, 1, 2), m(REM, 4, 1, 2), m(MULHU, 5, 1, 2), m(DIV, 6, 2, 1), EBREAK],
    # A misaligned load right after an M instruction traps; the M retires.
    "trap_after_m": li(1, 5) + [m(MUL, 2, 1, 1), enc_load(0b010, 3, 2)],
    # funct7 = 0000011 under OP is still illegal on an M core: it traps.
    "illegal_funct7_still_traps": li(1, 5) + [enc_r(0, 1, 1, 2, funct7=0b0000011)],
}


@cocotb.test()
@cocotb.parametrize(name=list(DIRECTED))
async def test_m_directed(dut, name):
    program = DIRECTED[name] + [ECALL]
    min_m = 0 if name == "illegal_funct7_still_traps" else 1
    stats, n_m = await check_m(dut, program, {8: 0x0000_0009}, min_m=min_m)
    dut._log.info(f"{name}: {n_m} M instructions; {stats}")


def random_m_program(rng, length):
    """Random RV32I (test_core's generator) with M instructions mixed in, a
    third of the time, and corner values loaded now and then so divides by
    zero and INT_MIN / -1 come up. x0-x4 only: nearly everything depends on
    something recent."""
    program = []
    for rd in RANDOM_REGS[1:]:
        program += li(rd, rng.getrandbits(32))
    for _ in range(length):
        r = rng.random()
        if r < 0.33:
            program.append(m(rng.randrange(8), *(rng.choice(RANDOM_REGS) for _ in range(3))))
        elif r < 0.40:
            program += li(rng.choice(RANDOM_REGS[1:]), rng.choice(CORNERS))
        else:
            program.append(random_instruction(rng, 4 * len(program)))
    return program + [rng.choice([ECALL, EBREAK]) for _ in range(HALT_TAIL)]


@cocotb.test()
async def test_random_m_programs_match_model(dut):
    """Dense random RV32IM programs: every hazard the stream produces, with
    M instructions in the middle of forwarding, load-use stalls, flushes and
    (on the _wait build) holds."""
    rng = seeded_rng(dut)
    total = 0
    for _ in range(6):
        program = random_m_program(rng, 250)
        stats, n_m = await check_m(dut, program, random_mem(rng), min_m=30, min_taken=10)
        total += n_m
        dut._log.info(f"{n_m} M instructions; {stats}")
    dut._log.info(f"{total} M instructions checked")


@cocotb.test(skip=bool(DMEM_WAIT))
async def test_m_latency(dut):
    """The cost of each M instruction against an add in the same slot:
    MUL* 2 extra cycles (3 in EX), DIV* 33 (34 in EX), whatever the operands,
    and back to back the costs simply add."""
    async def retire_cycle_of_marker(body):
        program = li(1, 0xDEAD_BEEF) + li(2, 3) + body + [enc_i(1, rd=31), ECALL]
        wbs, _ = await run(dut, program, cycles=200, timed=True)
        return next(c for c, rd, _ in wbs if rd == 31)

    for f3 in range(8):
        for a, b in [(0xDEAD_BEEF, 3), (0, 0), (INT_MIN, 0xFFFF_FFFF)]:
            body = li(1, a) + li(2, b) + [m(f3, 3, 1, 2)]
            ref = li(1, a) + li(2, b) + [enc_r(0, 1, 2, 3)]
            extra = await retire_cycle_of_marker(body) - await retire_cycle_of_marker(ref)
            want = 2 if f3 < 4 else 33
            assert extra == want, f"funct3 {f3} ({a:#x}, {b:#x}): {extra} extra cycles, want {want}"
    # Against two adds: the second instruction's own issue cycle is not M's.
    two = await retire_cycle_of_marker([m(DIV, 3, 1, 2), m(MUL, 4, 1, 2)])
    adds = await retire_cycle_of_marker([enc_r(0, 1, 2, 3), enc_r(0, 1, 2, 4)])
    assert two - adds == 33 + 2, f"DIV then MUL: {two - adds} extra, want 35"
