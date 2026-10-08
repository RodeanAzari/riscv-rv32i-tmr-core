"""Phase A: the five-stage core, IF through WB.

There is no back door into the register file: registers are set by executing
instructions (li() below), the way software sets them. Forwarding and the
load-use stall are in place, so programs need no NOP padding; tests that pad do
so deliberately, to exercise a path with no hazard in it.

Both memories are BRAM-timed models: they latch an address at a clock edge and
answer during the following cycle. The testbench must never be more forgiving
than the hardware. An earlier version answered IMEM within the cycle, and that
hid an IF bug that paired every instruction with the wrong PC.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

from rv32i_model import run_model

CLK_PERIOD_NS = 10
NOP = 0x0000_0013
MASK32 = 0xFFFF_FFFF

# A producer writes the register file three instructions after it is fetched,
# and the write-first bypass serves the instruction in ID that same cycle. With
# three NOPs between producer and consumer there is nothing to forward and
# nothing to stall -- the hazard-free baseline.
HAZARD_GAP = 3

# feed() writes an instruction at the address the core is presenting. The BRAM
# latches it at the next edge and IF/ID captures it at the edge after that.
# Edges from the start of feed() to each pipeline register:
IF_ID, ID_EX, EX_MEM, MEM_WB = 2, 3, 4, 5

OPCODE_OP     = 0b0110011
OPCODE_OP_IMM = 0b0010011
OPCODE_LUI    = 0b0110111
OPCODE_AUIPC  = 0b0010111
OPCODE_BRANCH = 0b1100011
OPCODE_JAL    = 0b1101111
OPCODE_JALR   = 0b1100111
OPCODE_LOAD   = 0b0000011
OPCODE_STORE  = 0b0100011

ECALL  = 0x0000_0073
EBREAK = 0x0010_0073
FENCE  = 0x0FF0_000F     # fence iorw, iorw


def enc_i(imm, rs1=0, funct3=0, rd=0, opcode=OPCODE_OP_IMM):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_r(funct3, rs1, rs2, rd, funct7=0):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) \
        | (rd << 7) | OPCODE_OP


def enc_u(imm, rd=0, opcode=OPCODE_LUI):
    return (imm & 0xFFFF_F000) | (rd << 7) | opcode


def enc_s(imm, rs1=0, rs2=0, funct3=0):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) \
        | (funct3 << 12) | ((imm & 0x1F) << 7) | OPCODE_STORE


def enc_load(funct3, rd, imm, rs1=0):
    return enc_i(imm, rs1=rs1, funct3=funct3, rd=rd, opcode=OPCODE_LOAD)


def enc_b(funct3, rs1, rs2, offset):
    """Conditional branch to pc + offset; offset is even, +/-4 KiB."""
    return (((offset >> 12) & 1) << 31) | (((offset >> 5) & 0x3F) << 25) \
        | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) \
        | (((offset >> 1) & 0xF) << 8) | (((offset >> 11) & 1) << 7) | OPCODE_BRANCH


def enc_jal(rd, offset):
    """rd = pc + 4, jump to pc + offset; offset is even, +/-1 MiB."""
    return (((offset >> 20) & 1) << 31) | (((offset >> 1) & 0x3FF) << 21) \
        | (((offset >> 11) & 1) << 20) | (((offset >> 12) & 0xFF) << 12) \
        | (rd << 7) | OPCODE_JAL


def enc_jalr(rd, rs1, imm):
    """rd = pc + 4, jump to (rs1 + imm) & ~1."""
    return enc_i(imm, rs1=rs1, rd=rd, opcode=OPCODE_JALR)


def li(rd, value):
    """The assembler's li pseudo-instruction.

    addi's immediate is sign-extended, so when the low 12 bits look negative the
    lui half has to round up by one to compensate -- the same "+0x800" every
    RISC-V assembler does for %hi/%lo.
    """
    value &= MASK32
    lo = ((value & 0xFFF) ^ 0x800) - 0x800          # sign-extended low 12 bits
    hi = (value - lo) & MASK32
    if hi == 0:
        return [enc_i(lo, rs1=0, rd=rd)]
    # The addi reads the lui's result back to back: EX/MEM -> EX forwarding.
    return [enc_u(hi, rd=rd), enc_i(lo, rs1=rd, rd=rd)]


# The instruction memory the IMEM model serves, byte address -> word, absent
# reads as NOP. Module-level so feed() can write into it; reset() clears it, and
# cocotb runs tests one at a time.
_imem = {}


async def bram_model(dut, prefix, mem, default):
    """A synchronous-read RAM, as an Arty A7 BRAM behaves.

    Samples its inputs 1 ns before each rising edge -- a flop's setup window --
    then at the edge applies any write and drives the read data for the address
    it latched. A value assigned after RisingEdge is not seen by the flops on
    that same edge, so the data appears just after the clock: one cycle of
    latency. Read-first: reading the word being written returns the old value.

    Sampling just before the edge, not at the falling edge, matters: a test
    that releases reset at the falling edge changes imem_addr_o in that same
    instant, and a model reading it then could see either value.

    mem maps word-aligned byte addresses to 32-bit words. For DMEM the write
    port is dmem_we_o / dmem_wstrb_o / dmem_wdata_o; IMEM has none.
    """
    addr_sig = getattr(dut, f"{prefix}_addr_o")
    rdata_sig = getattr(dut, f"{prefix}_rdata_i")
    writable = prefix == "dmem"
    # Started at a falling edge, so each iteration begins half a cycle before a
    # rising edge. Waiting for FallingEdge first would sleep through the very
    # next edge -- the reset edge that latches address 0 -- and lose mem[0].
    while True:
        await Timer(CLK_PERIOD_NS // 2 - 1, unit="ns")
        addr = int(addr_sig.value) & ~0b11
        if writable:
            we = int(dut.dmem_we_o.value)
            wstrb = int(dut.dmem_wstrb_o.value)
            wdata = int(dut.dmem_wdata_o.value)
        await RisingEdge(dut.clk_i)
        old = mem.get(addr, default)
        if writable and we:
            keep = sum(0xFF << (8 * i) for i in range(4) if not (wstrb >> i) & 1)
            mem[addr] = (old & keep) | (wdata & ~keep & MASK32)
        rdata_sig.value = old
        await FallingEdge(dut.clk_i)


async def reset(dut, program=(), mem=None):
    """Start the clock and both memories, and hold reset for two edges.

    Leaves rst_i asserted, so a test can inspect reset state; release() ends it.
    Two edges, not one, because the IMEM model needs one edge with the reset
    vector on imem_addr_o before mem[0] is waiting at its output -- exactly as a
    real BRAM does.

    program is loaded from address 0. Returns the DMEM contents dict.
    """
    _imem.clear()
    _imem.update({4 * i: w for i, w in enumerate(program)})
    mem = {} if mem is None else mem

    dut.rst_i.value = 1
    dut.imem_rdata_i.value = NOP
    dut.dmem_rdata_i.value = 0
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    cocotb.start_soon(bram_model(dut, "imem", _imem, NOP))
    cocotb.start_soon(bram_model(dut, "dmem", mem, 0))
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    return mem


async def release(dut):
    """Deassert reset and let the combinational outputs settle.

    imem_addr_o depends on rst_i combinationally. A read in the same instant as
    the write returns the old value, so wait 1 ns before anyone looks.
    """
    dut.rst_i.value = 0
    await Timer(1, unit="ns")


async def feed(dut, instr):
    """Place one instruction at the address the core is fetching, then advance
    a cycle. It reaches IF/ID IF_ID edges after feed() starts."""
    _imem[int(dut.imem_addr_o.value)] = instr
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)


async def feed_to(dut, instr, stage):
    """Feed instr and walk it into the given pipeline register (IF_ID ... MEM_WB)."""
    await feed(dut, instr)
    for _ in range(stage - 1):
        await feed(dut, NOP)


async def set_reg(dut, rd, value):
    """Set a register by executing li() -- needs rst_i already released."""
    for instr in li(rd, value):
        await feed(dut, instr)


@cocotb.test()
async def test_reset_state(dut):
    """In reset the core presents the reset vector, with a NOP in IF/ID."""
    await reset(dut)
    assert int(dut.imem_addr_o.value) == 0, f"fetch addr={dut.imem_addr_o.value}"
    assert int(dut.if_id_instr_o.value) == NOP, f"if_id_instr_o={dut.if_id_instr_o.value}"


@cocotb.test()
async def test_fetch_address_runs_one_word_ahead(dut):
    """imem_addr_o is pc_next: one word ahead of the pc whose word is arriving,
    advancing a word per cycle when nothing stalls it."""
    await reset(dut)
    await release(dut)
    for expected in (4, 8, 12, 16):
        assert int(dut.imem_addr_o.value) == expected, (
            f"expected fetch addr {expected}, got {int(dut.imem_addr_o.value)}"
        )
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)


@cocotb.test()
async def test_if_id_pairs_each_word_with_its_own_pc(dut):
    """The regression for the IF timing bug: every cycle, the word in IF/ID is
    the word stored at IF/ID's pc. Driving pc rather than pc_next into a BRAM
    tags each word with the next word's pc, and this fails on every cycle.

    Every word in the program is distinct, so a one-word skew cannot pass by
    coincidence; the pcs seen are checked so the test cannot pass vacuously.
    """
    program = [enc_i(i + 1, rd=i + 1) for i in range(6)]
    await reset(dut, program)
    await release(dut)

    seen = set()
    for _ in range(len(program) + 2):
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
        pc = int(dut.if_id_pc_o.value)
        word = int(dut.if_id_instr_o.value)
        expected = program[pc >> 2] if pc >> 2 < len(program) else NOP
        assert word == expected, (
            f"IF/ID pc={pc:#x} holds {word:#010x}, but that address holds "
            f"{expected:#010x}"
        )
        seen.add(pc)
    assert {0, 4, 8, 12, 16, 20} <= seen, f"pcs seen: {sorted(seen)}"


# --- ID stage --------------------------------------------------------------
# addi x5, x3, -1  ->  imm=-1, rs1=3, rd=5, opcode=OP-IMM
ADDI_X5_X3_M1 = 0xFFF1_8293
# add x7, x3, x4   ->  rs1=3, rs2=4, rd=7
ADD_X7_X3_X4  = 0x0041_83B3


@cocotb.test()
async def test_id_ex_resets_to_a_nop_decode(dut):
    """ID/EX comes out of reset looking like a NOP, not like X."""
    await reset(dut)
    assert int(dut.id_ex_instr_o.value) == NOP
    assert int(dut.id_ex_rd_addr_o.value) == 0, "reset ID/EX targets a real register"
    assert int(dut.id_ex_rs1_rdata_o.value) == 0
    assert int(dut.id_ex_rs2_rdata_o.value) == 0


@cocotb.test()
async def test_id_ex_captures_decode(dut):
    """Register addresses, immediate and destination reach ID/EX together."""
    await reset(dut)
    await release(dut)

    await feed_to(dut, ADDI_X5_X3_M1, ID_EX)

    assert int(dut.id_ex_instr_o.value) == ADDI_X5_X3_M1
    assert int(dut.id_ex_rs1_addr_o.value) == 3
    assert int(dut.id_ex_rd_addr_o.value) == 5
    assert int(dut.id_ex_imm_o.value) == 0xFFFF_FFFF, "immediate not sign-extended"


@cocotb.test()
async def test_id_ex_carries_rvfi_shadow_addresses(dut):
    """rs1/rs2 addresses ride ID/EX as RVFI shadow fields -- docs/rvfi-plan.md."""
    await reset(dut)
    await release(dut)

    await feed_to(dut, ADD_X7_X3_X4, ID_EX)

    assert int(dut.id_ex_rs1_addr_o.value) == 3
    assert int(dut.id_ex_rs2_addr_o.value) == 4
    assert int(dut.id_ex_rd_addr_o.value) == 7


@cocotb.test()
async def test_regfile_read_reaches_id_ex(dut):
    """Values written back in WB show up as register file reads in ID/EX.

    Padded on purpose. ID/EX holds what the register file returned; without
    the gap, x3 and x4 would still be in flight, the add would get them by
    forwarding in EX, and ID/EX's copy would be stale -- correctly.
    """
    await reset(dut)
    await release(dut)

    await set_reg(dut, 3, 0x1111_1111)
    await set_reg(dut, 4, 0x2222_2222)
    for _ in range(HAZARD_GAP):
        await feed(dut, NOP)

    await feed_to(dut, ADD_X7_X3_X4, ID_EX)

    assert int(dut.id_ex_rs1_rdata_o.value) == 0x1111_1111
    assert int(dut.id_ex_rs2_rdata_o.value) == 0x2222_2222


@cocotb.test()
async def test_x0_reads_zero_through_the_core(dut):
    """x0 invariance holds at the core level, not just in the unit test."""
    await reset(dut)
    await release(dut)

    # addi x0, x0, -1 really does reach WB as a write to x0; the register
    # file has to throw it away.
    await feed_to(dut, enc_i(-1, rs1=0, rd=0), MEM_WB)
    assert int(dut.wb_rd_we_o.value) == 1 and int(dut.wb_rd_addr_o.value) == 0, (
        "the write to x0 never reached WB, so this test proves nothing"
    )

    # add x7, x0, x0 -- both operands read x0
    await feed_to(dut, 0x0000_03B3, ID_EX)

    assert int(dut.id_ex_rs1_rdata_o.value) == 0
    assert int(dut.id_ex_rs2_rdata_o.value) == 0


# --- EX stage --------------------------------------------------------------
# drain() walks an instruction into EX/MEM so a test can assert on it.

async def drain(dut, instr):
    """Feed one instruction and walk it to EX/MEM. Returns the PC it saw."""
    pc = int(dut.imem_addr_o.value)
    await feed_to(dut, instr, EX_MEM)
    return pc


@cocotb.test()
async def test_ex_mem_resets_inert(dut):
    """Nothing appears to retire on cycle one."""
    await reset(dut)
    assert int(dut.ex_mem_rd_we_o.value) == 0, "EX/MEM claims a write out of reset"
    assert int(dut.ex_mem_instr_o.value) == NOP


@cocotb.test()
async def test_addi_computes_in_ex(dut):
    """addi x5, x0, 42 -> 42 reaches EX/MEM addressed to x5."""
    await reset(dut)
    await release(dut)

    await drain(dut, enc_i(42, rs1=0, rd=5))
    assert int(dut.ex_mem_alu_result_o.value) == 42
    assert int(dut.ex_mem_rd_addr_o.value) == 5
    assert int(dut.ex_mem_rd_we_o.value) == 1


@cocotb.test()
async def test_addi_negative_immediate_adds(dut):
    """The decoder's alt-bit trap, checked through the whole datapath.

    x3 = 100, then addi x6, x3, -1. If instr[30] leaked into the ALU's alt bit
    this computes 100 - (-1) = 101 instead of 99.
    """
    await reset(dut)
    await release(dut)
    await set_reg(dut, 3, 100)

    await drain(dut, enc_i(-1, rs1=3, rd=6))
    assert int(dut.ex_mem_alu_result_o.value) == 99, "addi -1 behaved as a subtract"


@cocotb.test()
async def test_register_register_add_and_sub(dut):
    await reset(dut)
    await release(dut)
    await set_reg(dut, 3, 70)
    await set_reg(dut, 4, 12)

    await drain(dut, enc_r(0b000, rs1=3, rs2=4, rd=7))
    assert int(dut.ex_mem_alu_result_o.value) == 82

    await drain(dut, enc_r(0b000, rs1=3, rs2=4, rd=7, funct7=0b0100000))
    assert int(dut.ex_mem_alu_result_o.value) == 58


@cocotb.test()
async def test_lui_places_upper_immediate(dut):
    """lui x8, 0x12345 -> 0x12345000, with rs1 ignored."""
    await reset(dut)
    await release(dut)
    await set_reg(dut, 1, 0xFFFF_FFFF)   # must not leak into the result

    await drain(dut, enc_u(0x1234_5000, rd=8))
    assert int(dut.ex_mem_alu_result_o.value) == 0x1234_5000
    assert int(dut.ex_mem_rd_addr_o.value) == 8


@cocotb.test()
async def test_auipc_adds_its_own_pc(dut):
    """auipc uses the PC of the auipc itself, not the fetch PC three stages on."""
    await reset(dut)
    await release(dut)

    pc = await drain(dut, enc_u(0x0001_0000, rd=9, opcode=OPCODE_AUIPC))
    assert int(dut.ex_mem_alu_result_o.value) == (pc + 0x0001_0000) & 0xFFFF_FFFF, (
        f"auipc used the wrong pc (instruction pc was {pc:#010x})"
    )


@cocotb.test()
async def test_slt_signed_through_the_core(dut):
    """slt x10, x3, x4 with x3 = -1, x4 = 1 -> 1. Unsigned would give 0."""
    await reset(dut)
    await release(dut)
    await set_reg(dut, 3, 0xFFFF_FFFF)
    await set_reg(dut, 4, 1)

    await drain(dut, enc_r(0b010, rs1=3, rs2=4, rd=10))
    assert int(dut.ex_mem_alu_result_o.value) == 1, "slt compared unsigned"

    await drain(dut, enc_r(0b011, rs1=3, rs2=4, rd=10))
    assert int(dut.ex_mem_alu_result_o.value) == 0, "sltu compared signed"


@cocotb.test()
async def test_csr_instruction_is_inert(dut):
    """csrrw x1, mstatus, x2: SYSTEM, but not ECALL/EBREAK. No CSRs exist, so
    it must neither write rd nor halt."""
    await reset(dut)
    await release(dut)

    await drain(dut, (0x300 << 20) | (2 << 15) | (0b001 << 12) | (1 << 7) | 0x73)
    assert int(dut.ex_mem_rd_we_o.value) == 0, "csrrw writes rd"
    for _ in range(3):
        await feed(dut, NOP)
    assert int(dut.halt_o.value) == 0, "csrrw halted the core"


@cocotb.test()
async def test_control_travels_with_its_instruction(dut):
    """Back-to-back instructions keep their own control through the pipeline.

    Feeds add (writes x7) directly behind a store (writes no register) with no
    NOPs between, so a control signal latched in the wrong stage shows up as
    the wrong rd_we reaching EX/MEM.
    """
    await reset(dut)
    await release(dut)
    await set_reg(dut, 3, 5)
    await set_reg(dut, 4, 6)

    await feed(dut, enc_s(0, rs1=0, rs2=0, funct3=0b010))   # sw x0, 0(x0)
    await feed_to(dut, enc_r(0b000, rs1=3, rs2=4, rd=7), EX_MEM)
    # the store is now past EX/MEM; the add is in EX/MEM
    assert int(dut.ex_mem_rd_we_o.value) == 1
    assert int(dut.ex_mem_rd_addr_o.value) == 7
    assert int(dut.ex_mem_alu_result_o.value) == 11


# --- MEM and WB -------------------------------------------------------------
# Whole programs from here on, loaded into IMEM from address 0.

RVFI_FIELDS = ("order", "insn", "trap", "halt", "intr", "pc_rdata", "pc_wdata",
               "rs1_addr", "rs1_rdata", "rs2_addr", "rs2_rdata",
               "rd_addr", "rd_wdata", "mem_addr", "mem_rmask", "mem_wmask",
               "mem_rdata", "mem_wdata")


def rvfi_record(dut):
    return {f: int(getattr(dut, f"rvfi_{f}_o").value) for f in RVFI_FIELDS}


async def run(dut, program, mem=None, timed=False, cycles=None, rvfi=None):
    """Reset, run program from address 0, drain it to WB.

    Returns (writebacks, mem): every register write WB performed, in retirement
    order, as (rd, value) -- x0 included, since a write to x0 still happens --
    and the data memory as the program left it. With timed=True each writeback
    is (cycle, rd, value), so a test can measure what a stall cost.

    The default budget is three cycles per instruction: at worst each one is a
    taken branch (two flushed cycles) or stalls once. A program with a
    backward branch executes more instructions than it holds, and passes
    cycles. Past the end the core fetches NOPs, which write only x0.

    Stops early once halt_o rises: an ECALL or EBREAK has retired, and
    everything older with it, so there is nothing left to collect.

    Pass a list as rvfi to collect every RVFI retirement record.
    """
    mem = await reset(dut, program, mem)
    await release(dut)

    writebacks = []
    if cycles is None:
        cycles = 3 * len(program) + MEM_WB + 1
    for cycle in range(cycles):
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
        if int(dut.wb_rd_we_o.value):
            wb = (int(dut.wb_rd_addr_o.value), int(dut.wb_rd_wdata_o.value))
            writebacks.append((cycle, *wb) if timed else wb)
        if rvfi is not None and int(dut.rvfi_valid_o.value):
            rvfi.append(rvfi_record(dut))
        if int(dut.halt_o.value):
            break
    return writebacks, mem


def bytes_in(mask, word):
    """The bytes of word selected by a 4-bit lane mask, low lane first."""
    return [(word >> (8 * i)) & 0xFF for i in range(4) if (mask >> i) & 1]


def check_rvfi(got, want):
    """Compare the core's RVFI retirements with the model's, one by one.

    Every retirement counts -- stores, branches and NOPs too -- so a dropped,
    duplicated or bubble-retired instruction anywhere misaligns the stream.
    Register values are compared only where the model knows them (the
    register file has no reset), and memory data only in the lanes the masks
    select. Past the program's end the core retires the NOPs it fetches --
    unless the program halted, in which case nothing retires after the halt.
    """
    assert len(got) >= len(want), f"core retired {len(got)}, model {len(want)}"
    for i, (g, w) in enumerate(zip(got, want)):
        where = f"retirement #{i} pc={w['pc_rdata']:#x} insn={w['insn']:#010x}"
        assert g["order"] == i, f"{where}: order {g['order']}"
        assert (g["trap"], g["halt"], g["intr"]) == (w["trap"], w["halt"], 0), (
            f"{where}: trap/halt/intr core {(g['trap'], g['halt'], g['intr'])}, "
            f"model {(w['trap'], w['halt'], 0)}")
        for f in ("insn", "pc_rdata", "pc_wdata", "rs1_addr", "rs2_addr",
                  "rd_addr", "rd_wdata", "mem_rmask", "mem_wmask"):
            assert g[f] == w[f], f"{where}: {f} core {g[f]:#x}, model {w[f]:#x}"
        for r in ("rs1", "rs2"):
            if w[f"{r}_defined"]:
                assert g[f"{r}_rdata"] == w[f"{r}_rdata"], (
                    f"{where}: {r}_rdata core {g[f'{r}_rdata']:#x}, "
                    f"model {w[f'{r}_rdata']:#x}")
        if w["mem_rmask"] or w["mem_wmask"]:
            assert g["mem_addr"] == w["mem_addr"], f"{where}: mem_addr {g['mem_addr']:#x}"
        for f, m in (("mem_rdata", "mem_rmask"), ("mem_wdata", "mem_wmask")):
            assert bytes_in(w[m], g[f]) == bytes_in(w[m], w[f]), (
                f"{where}: {f} core {g[f]:#010x}, model {w[f]:#010x}")
    if want and want[-1]["halt"]:
        assert len(got) == len(want), f"core retired {len(got) - len(want)} past the halt"
    for g in got[len(want):]:
        assert g["insn"] == NOP, f"core retired {g['insn']:#010x} past the program"
    return {"retirements": len(want),
            "rs values checked": sum(w[f"{r}_defined"] for w in want for r in ("rs1", "rs2")),
            "memory accesses": sum(bool(w["mem_rmask"] or w["mem_wmask"]) for w in want)}


def final_regs(writebacks):
    """Last value written to each register, x0 excluded."""
    return {rd: v for rd, v in writebacks if rd != 0}


GAP = [NOP] * HAZARD_GAP

LB, LH, LW, LBU, LHU = 0b000, 0b001, 0b010, 0b100, 0b101
SB, SH, SW = 0b000, 0b001, 0b010
BEQ, BNE, BLT, BGE, BLTU, BGEU = 0b000, 0b001, 0b100, 0b101, 0b110, 0b111


@cocotb.test()
async def test_wb_and_dmem_reset_inert(dut):
    """Out of reset nothing is written -- not a register, not memory."""
    await reset(dut)
    assert int(dut.wb_rd_we_o.value) == 0, "WB writes a register out of reset"
    assert int(dut.dmem_we_o.value) == 0, "MEM writes memory out of reset"
    assert int(dut.dmem_wstrb_o.value) == 0
    assert int(dut.mem_wb_instr_o.value) == NOP


@cocotb.test()
async def test_alu_result_writes_back_and_is_read_again(dut):
    """The loop closes: a result written in WB is an operand three instructions on."""
    program = [enc_i(42, rs1=0, rd=5)] + GAP + [enc_r(0b000, rs1=5, rs2=5, rd=6)]
    writebacks, _ = await run(dut, program)
    regs = final_regs(writebacks)
    assert regs.get(5) == 42, f"x5 never written back: {writebacks}"
    assert regs.get(6) == 84, f"x6 = x5 + x5 read a stale x5: {writebacks}"


@cocotb.test()
async def test_store_then_load_round_trip(dut):
    """The slice's definition of done: store a value, load it into a different
    register, and prove the loaded value really landed in the register file by
    storing it again from there.

    The load directly follows the store. That is a dependency through memory,
    not a register, so it needs no gap: the store writes at the end of its MEM
    cycle and the load reads at the end of its own, one cycle later.
    """
    value = 0x8765_4321
    program = li(1, value) + [
        enc_s(16, rs1=0, rs2=1, funct3=SW),      # sw x1, 16(x0)
        enc_load(LW, rd=2, imm=16),              # lw x2, 16(x0)
    ] + GAP + [
        enc_s(20, rs1=0, rs2=2, funct3=SW),      # sw x2, 20(x0)
    ]
    writebacks, mem = await run(dut, program)
    assert mem.get(16) == value, f"store: mem[16] = {mem.get(16, 0):#010x}"
    assert final_regs(writebacks).get(2) == value, f"load: writebacks {writebacks}"
    assert mem.get(20) == value, (
        f"x2 was written back but not stored: mem[20] = {mem.get(20, 0):#010x}"
    )


@cocotb.test()
async def test_store_widths_and_lanes_through_the_core(dut):
    """SB to all four lanes and SH to both halves, distinct data per lane.

    riscv_mem_align is swept exhaustively in its own test; this one proves the
    core feeds it the right funct3 and address bits.
    """
    program = []
    for rd, v in ((1, 0x01), (2, 0x02), (3, 0x03), (4, 0x04), (5, 0xFFFF_FFFE)):
        program += li(rd, v)
    program += [
        enc_s(32, rs2=1, funct3=SB), enc_s(33, rs2=2, funct3=SB),
        enc_s(34, rs2=3, funct3=SB), enc_s(35, rs2=4, funct3=SB),
        enc_s(36, rs2=1, funct3=SH), enc_s(38, rs2=5, funct3=SH),
        enc_s(40, rs2=5, funct3=SW),
    ]
    _, mem = await run(dut, program, mem={32: 0xAAAA_AAAA, 36: 0xAAAA_AAAA})
    assert mem.get(32) == 0x0403_0201, f"SB lanes: {mem.get(32, 0):#010x}"
    assert mem.get(36) == 0xFFFE_0001, f"SH halves: {mem.get(36, 0):#010x}"
    assert mem.get(40) == 0xFFFF_FFFE, f"SW: {mem.get(40, 0):#010x}"


@cocotb.test()
async def test_load_widths_lanes_and_extension_through_the_core(dut):
    """Every load form against one word whose lanes are 0x01, 0x7F, 0xFF, 0x80.

    Byte 2 (0xFF) and the upper half (0x80FF) are the cases where LB/LBU and
    LH/LHU must disagree. Byte 1 (0x7F) is where they must agree.
    """
    word = 0x80FF_7F01
    loads = [
        (LB, 66, 0xFFFF_FFFF), (LBU, 66, 0x0000_00FF), (LB, 65, 0x0000_007F),
        (LBU, 64, 0x0000_0001), (LB, 67, 0xFFFF_FF80),
        (LH, 66, 0xFFFF_80FF), (LHU, 66, 0x0000_80FF), (LH, 64, 0x0000_7F01),
        (LW, 64, word),
    ]
    program = [enc_load(f3, rd=i + 1, imm=addr) for i, (f3, addr, _) in enumerate(loads)]
    writebacks, _ = await run(dut, program, mem={64: word})
    regs = final_regs(writebacks)
    for i, (f3, addr, want) in enumerate(loads):
        got = regs.get(i + 1)
        assert got == want, (
            f"funct3={f3:03b} addr={addr}: x{i + 1} = "
            f"{'never written' if got is None else hex(got)}, expected {want:#010x}"
        )


@cocotb.test()
async def test_store_writes_no_register(dut):
    """A store's rd field is immediate bits; it must not reach WB as a write.

    imm[4:0] = 31 sits in the rd slot, so a leaked write shows up as x31. The
    NOP padding does write x0 -- NOP is addi x0, x0, 0 -- hence final_regs().
    """
    program = [enc_s(0b11111, rs1=0, rs2=0, funct3=SW)]
    writebacks, _ = await run(dut, program)
    assert final_regs(writebacks) == {}, f"store wrote a register: {writebacks}"


@cocotb.test()
async def test_misaligned_access_uses_the_containing_word(dut):
    """Pins the documented assumption: bits below the access size are ignored.

    Not RV32I-required behaviour -- misalignment is outside this core's scope --
    but whatever the hardware does must be what docs/PROGRESS.md says it does,
    because rvfi_mem_rmask/wmask will encode it.
    """
    program = [enc_load(LW, rd=1, imm=66), enc_load(LH, rd=2, imm=67)]
    writebacks, _ = await run(dut, program, mem={64: 0x8765_4321})
    regs = final_regs(writebacks)
    assert regs.get(1) == 0x8765_4321, f"lw @66: {regs.get(1)}"
    assert regs.get(2) == 0xFFFF_8765, f"lh @67: {regs.get(2)}"


@cocotb.test()
async def test_auipc_at_a_known_address(dut):
    """The IF bug as first observed: auipc x5, 0 at pc 8 must write 8, not 12.

    test_auipc_adds_its_own_pc uses whatever pc feed() lands on; this one pins
    an absolute address, so the expected value does not come from the DUT.
    """
    program = [NOP, NOP, enc_u(0, rd=5, opcode=OPCODE_AUIPC)]
    writebacks, _ = await run(dut, program)
    assert final_regs(writebacks).get(5) == 8, f"writebacks {writebacks}"


# --- forwarding and the load-use stall (CLAUDE.md 5.3, 9) ------------------
# No padding anywhere below: these are the hazards the padding used to hide.
# Directed before random, per 9 -- each test names the one path it exercises.

def retire_cycle(timed_writebacks, rd):
    """Cycle of the first writeback to rd."""
    return next(c for c, r, _ in timed_writebacks if r == rd)


@cocotb.test()
async def test_forward_ex_mem_to_ex(dut):
    """Back to back: the producer is in EX/MEM when the consumer is in EX.
    rs1 and rs2 both name x1, so both operands forward at once (a 9 case)."""
    writebacks, _ = await run(dut, [enc_i(5, rd=1), enc_r(0b000, rs1=1, rs2=1, rd=2)])
    assert final_regs(writebacks).get(2) == 10, f"writebacks {writebacks}"


@cocotb.test()
async def test_forward_mem_wb_to_ex(dut):
    """One instruction between: the producer is in MEM/WB."""
    program = [enc_i(5, rd=1), NOP, enc_r(0b000, rs1=1, rs2=0, rd=2)]
    writebacks, _ = await run(dut, program)
    assert final_regs(writebacks).get(2) == 5, f"writebacks {writebacks}"


@cocotb.test()
async def test_forward_wb_to_id_through_the_register_file(dut):
    """Two between: the producer writes the register file while the consumer
    is in ID, and the write-first bypass must hand over the new value."""
    program = [enc_i(5, rd=1), NOP, NOP, enc_r(0b000, rs1=1, rs2=0, rd=2)]
    writebacks, _ = await run(dut, program)
    assert final_regs(writebacks).get(2) == 5, f"writebacks {writebacks}"


@cocotb.test()
async def test_younger_write_wins(dut):
    """x1 is in flight twice -- EX/MEM holds 2, MEM/WB holds 1. Program order
    says the consumer sees 2."""
    program = [enc_i(1, rd=1), enc_i(2, rd=1), enc_r(0b000, rs1=1, rs2=0, rd=2)]
    writebacks, _ = await run(dut, program)
    assert final_regs(writebacks).get(2) == 2, f"forwarded the older x1: {writebacks}"


@cocotb.test()
async def test_operands_forward_from_different_stages(dut):
    """rs1 from MEM/WB and rs2 from EX/MEM in the same instruction."""
    program = [enc_i(3, rd=1), enc_i(4, rd=2), enc_r(0b000, rs1=1, rs2=2, rd=3)]
    writebacks, _ = await run(dut, program)
    assert final_regs(writebacks).get(3) == 7, f"writebacks {writebacks}"


@cocotb.test()
async def test_write_to_x0_is_never_forwarded(dut):
    """addi x0, x0, 7 reaches EX/MEM as a write to x0. Forwarding it would make
    x0 read 7 for one instruction."""
    program = [enc_i(7, rd=0), enc_r(0b000, rs1=0, rs2=0, rd=1),
               enc_i(7, rd=0), NOP, enc_r(0b000, rs1=0, rs2=0, rd=2)]
    writebacks, _ = await run(dut, program)
    regs = final_regs(writebacks)
    assert regs.get(1) == 0, f"x0 forwarded from EX/MEM: {writebacks}"
    assert regs.get(2) == 0, f"x0 forwarded from MEM/WB: {writebacks}"


@cocotb.test()
async def test_load_use_stalls_exactly_one_cycle(dut):
    """The 9 headline case. A use directly behind a load must get the loaded
    value, AND cost exactly one bubble: back-to-back instructions retire one
    cycle apart, so the use retires two after the load.

    Then a third instruction, to check the stall neither drops nor repeats
    anything behind it.
    """
    program = [enc_load(LW, rd=1, imm=16), enc_r(0b000, rs1=1, rs2=1, rd=2),
               enc_i(9, rd=3)]
    writebacks, _ = await run(dut, program, mem={16: 21}, timed=True)
    assert [(r, v) for _, r, v in writebacks if r] == [(1, 21), (2, 42), (3, 9)], (
        f"writebacks {writebacks}"
    )
    lw, use, nxt = (retire_cycle(writebacks, rd) for rd in (1, 2, 3))
    assert use - lw == 2, f"load-use cost {use - lw - 1} bubbles, expected 1"
    assert nxt - use == 1, "the instruction after the stall was delayed too"


@cocotb.test()
async def test_load_use_on_rs2(dut):
    """The stall checks rs2 as well as rs1."""
    program = [enc_load(LW, rd=1, imm=16), enc_r(0b000, rs1=0, rs2=1, rd=2)]
    writebacks, _ = await run(dut, program, mem={16: 21})
    assert final_regs(writebacks).get(2) == 21, f"writebacks {writebacks}"


@cocotb.test()
async def test_pointer_chase_load_after_load(dut):
    """lw x1, 16(x0); lw x1, 0(x1) -- a linked-list walk. The bubble the stall
    inserts is a copy of the waiting load (ID/EX clears only its control
    bits), so if it kept mem_read it would stall on itself forever."""
    program = [enc_load(LW, rd=1, imm=16), enc_load(LW, rd=1, imm=0, rs1=1),
               enc_i(3, rd=2)]
    writebacks, _ = await run(dut, program, mem={16: 32, 32: 7})
    assert [(r, v) for r, v in writebacks if r] == [(1, 32), (1, 7), (2, 3)], (
        f"writebacks {writebacks}"
    )


@cocotb.test()
async def test_load_use_branch_is_not_evaluated_in_the_bubble(dut):
    """lw x4, 16(x0); beq x4, x1. During the stall, EX/MEM holds the load's
    ADDRESS. With x1 = 16 a bubble that kept the branch bit would compare 16
    == 16 and take; the real branch compares the data, 5, and must not."""
    program = li_all(x1=16) + GAP + [
        enc_load(LW, rd=4, imm=16),
        enc_b(BEQ, 4, 1, 8),
        enc_i(1, rd=3),                                 # not taken: runs
        enc_i(2, rd=5)]
    writebacks, _ = await run(dut, program, mem={16: 5})
    assert final_regs(writebacks).get(3) == 1, f"retired {writebacks}"


@cocotb.test()
async def test_branch_in_the_shadow_of_a_jump_does_not_redirect(dut):
    """jal over an always-taken beq: the beq is the wrong-path word in ID
    when the jal redirects. Its bubble must not redirect a second time."""
    program = [enc_jal(0, 12),                          # 0  -> 12
               enc_b(BEQ, 0, 0, 20),                    # 4  wrong path, -> 24
               enc_i(1, rd=3),                          # 8  wrong path
               enc_i(5, rd=5),                          # 12 target
               enc_i(6, rd=6),                          # 16
               NOP,                                     # 20
               enc_i(7, rd=7)]                          # 24
    writebacks, _ = await run(dut, program)
    assert [r for r, _ in writebacks if r] == [5, 6, 7], f"retired {writebacks}"


@cocotb.test()
async def test_load_with_one_between_does_not_stall(dut):
    """lw; nop; use -- the load is already in MEM/WB when the use reaches EX,
    so forwarding suffices. A stall here would be a wasted cycle."""
    program = [enc_load(LW, rd=1, imm=16), NOP, enc_r(0b000, rs1=1, rs2=1, rd=2)]
    writebacks, _ = await run(dut, program, mem={16: 21}, timed=True)
    assert final_regs([(r, v) for _, r, v in writebacks]).get(2) == 42
    assert retire_cycle(writebacks, 2) - retire_cycle(writebacks, 1) == 2, (
        f"unnecessary stall: {writebacks}"
    )


@cocotb.test()
async def test_load_to_x0_does_not_stall(dut):
    """A load to x0 writes nothing, so nothing can depend on it.

    Timed from a marker (addi x3) rather than from the load: the load's own
    writeback goes to x0, and so does the reset NOP's, so it cannot be told
    apart by register. Three instructions retire back to back -- marker, load,
    use -- so the use lands two cycles after the marker unless something stalled.
    """
    program = [enc_i(1, rd=3), enc_load(LW, rd=0, imm=16),
               enc_r(0b000, rs1=0, rs2=0, rd=1)]
    writebacks, _ = await run(dut, program, mem={16: 21}, timed=True)
    assert retire_cycle(writebacks, 1) - retire_cycle(writebacks, 3) == 2, (
        f"stalled on a load to x0: {writebacks}"
    )
    assert final_regs([(r, v) for _, r, v in writebacks]).get(1) == 0


@cocotb.test()
async def test_store_data_is_forwarded(dut):
    """sw directly behind the instruction that computed its data. EX/MEM must
    capture the forwarded rs2, not ID/EX's stale copy."""
    program = [enc_i(0x55, rd=1), enc_s(0, rs1=0, rs2=1, funct3=SW)]
    _, mem = await run(dut, program)
    assert mem.get(0) == 0x55, f"stored stale data: {mem.get(0, 0):#x}"


@cocotb.test()
async def test_loaded_value_stored_back_to_back(dut):
    """lw x1; sw x1 -- load-use through the STORE DATA operand: stall, then
    forward the load data from MEM/WB into the store."""
    program = [enc_load(LW, rd=1, imm=16), enc_s(20, rs1=0, rs2=1, funct3=SW)]
    _, mem = await run(dut, program, mem={16: 0xCAFE_F00D})
    assert mem.get(20) == 0xCAFE_F00D, f"mem[20] = {mem.get(20, 0):#x}"


@cocotb.test()
async def test_address_operand_is_forwarded(dut):
    """addi x1, x0, 32 directly before lw x2, 0(x1) and sw x2, 4(x1). The
    random programs address off x0, so this is where the base register's
    forwarding is checked."""
    program = [enc_i(32, rd=1), enc_load(LW, rd=2, imm=0, rs1=1),
               enc_s(4, rs1=1, rs2=2, funct3=SW)]
    writebacks, mem = await run(dut, program, mem={32: 0x1234_5678})
    assert final_regs(writebacks).get(2) == 0x1234_5678, f"writebacks {writebacks}"
    assert mem.get(36) == 0x1234_5678, f"mem {mem}"


# --- branches and jumps ------------------------------------------------------
# Resolved in EX with static not-taken prediction. When a branch or jump is in
# EX, two younger words have already been fetched: one in IF/ID, one waiting at
# the IMEM output. A taken redirect must discard both -- the CLAUDE.md 9
# failure mode is discarding only one, so a wrong-path instruction reaches WB.

def li_all(**regs):
    """li for several registers, e.g. li_all(x1=5, x2=-1)."""
    return [w for name, v in regs.items() for w in li(int(name[1:]), v)]


@cocotb.test()
async def test_taken_branch_flushes_both_wrong_path_instructions(dut):
    """beq taken over two instructions: neither the one in IF/ID nor the one at
    the IMEM output may retire. Flushing only one stage lets one through."""
    program = [enc_i(5, rd=1), enc_i(5, rd=2),
               enc_b(BEQ, 1, 2, 12),
               enc_i(1, rd=3),                 # in IF/ID when beq resolves
               enc_i(1, rd=4),                 # at the IMEM output
               enc_i(7, rd=5)]                 # target
    writebacks, _ = await run(dut, program)
    regs = [r for r, _ in writebacks if r]
    assert regs == [1, 2, 5], f"retired {writebacks}"
    assert final_regs(writebacks)[5] == 7


@cocotb.test()
async def test_wrong_path_store_does_not_write_memory(dut):
    """A store behind a taken branch is squashed before MEM, not after: a
    flushed store that still reached the memory port could not be undone."""
    program = [enc_jal(0, 8),
               enc_s(16, rs1=0, rs2=0, funct3=SW),       # wrong path
               enc_i(3, rd=1)]
    _, mem = await run(dut, program, mem={16: 0xDEAD_BEEF})
    assert mem[16] == 0xDEAD_BEEF, f"wrong-path store wrote {mem[16]:#010x}"


@cocotb.test()
async def test_taken_branch_costs_exactly_two_cycles(dut):
    """Taken to the very next instruction: same path either way, so the
    difference in retire time is purely the flush. Not taken costs nothing."""
    program = [enc_i(1, rd=1),
               enc_b(BNE, 0, 0, 4),                    # never taken
               enc_i(2, rd=2),
               enc_b(BEQ, 0, 0, 4),                    # always taken, to pc + 4
               enc_i(3, rd=3)]
    writebacks, _ = await run(dut, program, timed=True)
    c1, c2, c3 = (retire_cycle(writebacks, rd) for rd in (1, 2, 3))
    assert c2 - c1 == 2, f"not-taken branch cost {c2 - c1 - 2} cycles, expected 0"
    assert c3 - c2 == 4, f"taken branch cost {c3 - c2 - 2} cycles, expected 2"


@cocotb.test()
async def test_each_condition_taken_and_not_taken(dut):
    """Every condition on operands that take it and operands that do not,
    including the pair where signed and unsigned order disagree (-1 vs 1).

    One program walks through every case: each branch skips an `addi x3, x0,
    id` when taken, so the x3 writebacks list exactly the cases not taken."""
    cases = [  # (funct3, rs1 value, rs2 value, taken)
        (BEQ, 5, 5, True), (BEQ, 5, 6, False),
        (BNE, 5, 6, True), (BNE, 5, 5, False),
        (BLT, -1, 1, True), (BLT, 1, -1, False), (BLT, 4, 4, False),
        (BGE, 1, -1, True), (BGE, 4, 4, True), (BGE, -1, 1, False),
        (BLTU, 1, -1, True), (BLTU, -1, 1, False), (BLTU, 4, 4, False),
        (BGEU, -1, 1, True), (BGEU, 4, 4, True), (BGEU, 1, -1, False),
    ]
    program = []
    for i, (funct3, a, b, _) in enumerate(cases):
        program += li_all(x1=a, x2=b)
        program += [enc_b(funct3, 1, 2, 8), enc_i(i, rd=3)]
    writebacks, _ = await run(dut, program)
    got = [v for r, v in writebacks if r == 3]
    want = [i for i, c in enumerate(cases) if not c[3]]
    assert got == want, f"cases not taken: got {got}, expected {want}"


@cocotb.test()
async def test_branch_compares_forwarded_operands(dut):
    """The comparator sits behind the forwarding muxes: back-to-back producers
    feed it from EX/MEM and MEM/WB, and a load feeds it after its stall.

    The registers are preset to unequal values first, so a comparator reading
    stale register-file values sees them differ and does not branch."""
    program = li_all(x1=1, x2=2, x4=4) + GAP + [
        enc_i(9, rd=1),                                 # -> MEM/WB
        enc_i(9, rd=2),                                 # -> EX/MEM
        enc_b(BEQ, 1, 2, 8),                            # taken only if both forwarded
        enc_i(1, rd=3),
        enc_load(LW, rd=4, imm=16),
        enc_b(BEQ, 4, 1, 8),                            # load-use, then compare
        enc_i(2, rd=3),
        enc_i(3, rd=5)]
    writebacks, _ = await run(dut, program, mem={16: 9})
    assert [v for r, v in writebacks if r == 3] == [], f"retired {writebacks}"
    assert final_regs(writebacks).get(5) == 3


@cocotb.test()
async def test_jal_writes_link_and_jumps(dut):
    program = [enc_i(1, rd=2),
               enc_jal(1, 12),                          # at 4: link 8, target 16
               enc_i(1, rd=3), enc_i(1, rd=4),
               enc_r(0b000, rs1=1, rs2=0, rd=5)]        # reads the link
    writebacks, _ = await run(dut, program)
    assert [r for r, _ in writebacks if r] == [2, 1, 5], f"retired {writebacks}"
    regs = final_regs(writebacks)
    assert regs[1] == 8 and regs[5] == 8, f"link {regs}"


@cocotb.test()
async def test_jalr_uses_forwarded_base_and_drops_low_bits(dut):
    """addi x2 directly before jalr off x2: the base comes from EX/MEM. The
    target is odd -- JALR clears bit 0 -- so the jump lands one byte lower.
    x2 is preset first, so a stale base would jump somewhere else."""
    head = li_all(x2=0x400) + GAP
    jalr_at = 4 * (len(head) + 1)
    target = jalr_at + 12
    program = head + [enc_i(target + 1, rd=2),
                      enc_jalr(1, 2, 0),
                      enc_i(1, rd=3), enc_i(1, rd=4),
                      enc_i(5, rd=5)]                   # at target
    writebacks, _ = await run(dut, program)
    assert [r for r, _ in writebacks if r][-3:] == [2, 1, 5], f"retired {writebacks}"
    assert final_regs(writebacks)[1] == jalr_at + 4


@cocotb.test()
async def test_jalr_base_from_a_load(dut):
    """lw x2 then jalr off x2: load-use stall, then the base from MEM/WB."""
    head = li_all(x2=0x400) + GAP
    target = 4 * (len(head) + 4)
    program = head + [enc_load(LW, rd=2, imm=32),
                      enc_jalr(1, 2, 0),
                      enc_i(1, rd=3), enc_i(1, rd=4),
                      enc_i(5, rd=5)]                   # at target
    writebacks, _ = await run(dut, program, mem={32: target})
    assert [r for r, _ in writebacks if r][-3:] == [2, 1, 5], f"retired {writebacks}"


@cocotb.test()
async def test_jalr_rd_equal_to_rs1_reads_before_writing(dut):
    """jalr x1, 0(x1): the target is the OLD x1, then x1 becomes the link."""
    program = [enc_i(16, rd=1),
               enc_jalr(1, 1, 0),                       # at 4: link 8
               enc_i(1, rd=3), enc_i(1, rd=4),
               enc_i(5, rd=5)]                          # at 16
    writebacks, _ = await run(dut, program)
    assert [r for r, _ in writebacks if r] == [1, 1, 5], f"retired {writebacks}"
    assert final_regs(writebacks)[1] == 8


@cocotb.test()
async def test_jump_to_x0_writes_nothing_visible(dut):
    """jal x0 is a plain jump (`j`): the link goes nowhere."""
    program = [enc_jal(0, 8), enc_i(1, rd=3), enc_i(5, rd=5)]
    writebacks, _ = await run(dut, program)
    assert final_regs(writebacks) == {5: 5}, f"retired {writebacks}"


@cocotb.test()
async def test_misaligned_target_drops_low_bits(dut):
    """beq to pc + 10: bit 1 set. RV32I would trap; this core ignores the low
    bits (the misalignment assumption) and lands on pc + 8.

    Checking which instruction ran is not enough: IMEM ignores the low address
    bits too, so a pc of 10 still fetches the word at 8. auipc at the target
    reads the pc itself."""
    program = [enc_b(BEQ, 0, 0, 10), enc_i(1, rd=3),
               enc_u(0, rd=5, opcode=OPCODE_AUIPC)]
    writebacks, _ = await run(dut, program)
    assert final_regs(writebacks) == {5: 8}, f"retired {writebacks}"


@cocotb.test()
async def test_backward_branch_loop(dut):
    """A counted loop: the backward branch, the flush on every iteration, and
    the fall-through on the last, checked against the golden model."""
    program = [enc_i(4, rd=1),                          # x1 = 4
               enc_i(10, rs1=2, rd=2),                  # loop: x2 += 10
               enc_i(-1, rs1=1, rd=1),                  #       x1 -= 1
               enc_b(BNE, 1, 0, -8),                    #       until x1 == 0
               enc_i(0x55, rd=3)]
    want, _ = run_model(program)
    writebacks, _ = await run(dut, program, cycles=60)
    got = [(r, v) for r, v in writebacks if r]
    # x2 starts undefined (no regfile reset), so compare x1 and x3 exactly and
    # x2 by its increments.
    assert [v for r, v in got if r == 1] == [v for r, v in want if r == 1]
    assert [v for r, v in got if r == 3] == [0x55]
    x2 = [v for r, v in got if r == 2]
    assert len(x2) == 4 and all((b - a) & MASK32 == 10 for a, b in zip(x2, x2[1:])), x2


# --- FENCE, ECALL, EBREAK ---------------------------------------------------
# ECALL and EBREAK halt the core (no trap machinery, CLAUDE.md 5.1): everything
# older retires, nothing younger does, and halt_o stays high until reset.

async def assert_stays_halted(dut, cycles=10):
    """After halt_o: no register write, no store, no retirement, and the
    fetch address frozen -- for as long as we care to watch."""
    assert int(dut.halt_o.value) == 1, "core did not halt"
    addr = int(dut.imem_addr_o.value)
    for _ in range(cycles):
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
        assert int(dut.halt_o.value) == 1, "halt_o dropped without a reset"
        assert int(dut.wb_rd_we_o.value) == 0, "register write after the halt"
        assert int(dut.dmem_we_o.value) == 0, "store after the halt"
        assert int(dut.rvfi_valid_o.value) == 0, "retirement after the halt"
        assert int(dut.imem_addr_o.value) == addr, "fetch moved after the halt"


@cocotb.test()
async def test_ecall_halts_after_older_instructions_retire(dut):
    """The two instructions ahead of the ecall write back; the store and the
    addi behind it -- already fetched when it reached EX -- do nothing."""
    program = [enc_i(1, rd=1), enc_i(2, rd=2), ECALL,
               enc_s(0, rs1=0, rs2=1, funct3=SW), enc_i(3, rd=3)]
    rvfi = []
    writebacks, mem = await run(dut, program, rvfi=rvfi)
    assert final_regs(writebacks) == {1: 1, 2: 2}, f"retired {writebacks}"
    assert mem == {}, f"store behind the ecall wrote {mem}"
    assert [r["insn"] for r in rvfi] == program[:3]
    assert (rvfi[-1]["trap"], rvfi[-1]["halt"]) == (1, 1), "ecall not marked in RVFI"
    assert all((r["trap"], r["halt"]) == (0, 0) for r in rvfi[:-1])
    await assert_stays_halted(dut)


@cocotb.test()
async def test_ebreak_halts(dut):
    program = [enc_i(1, rd=1), EBREAK, enc_i(3, rd=3)]
    rvfi = []
    writebacks, _ = await run(dut, program, rvfi=rvfi)
    assert final_regs(writebacks) == {1: 1}, f"retired {writebacks}"
    assert [r["insn"] for r in rvfi] == program[:2]
    assert rvfi[-1]["halt"] == 1
    await assert_stays_halted(dut)


@cocotb.test()
async def test_halt_rises_the_cycle_after_the_halting_retirement(dut):
    """halt_o promises that architectural state is final. Too early and the
    instructions ahead would still be in flight; it should not lag either."""
    program = [enc_i(1, rd=1), ECALL]
    await reset(dut, program)
    await release(dut)
    retired = None
    for cycle in range(20):
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
        if int(dut.rvfi_valid_o.value) and int(dut.rvfi_halt_o.value):
            retired = cycle
            assert int(dut.halt_o.value) == 0, "halt_o rose before the ecall retired"
        if int(dut.halt_o.value):
            assert retired == cycle - 1, f"ecall retired at {retired}, halt_o at {cycle}"
            return
    assert False, "core never halted"


@cocotb.test()
async def test_wrong_path_ecall_does_not_halt(dut):
    """An ecall in the shadow of a taken branch is flushed, not obeyed: the
    core runs on to the target and halts at the next ecall."""
    program = [enc_b(BEQ, 0, 0, 8), ECALL,
               enc_i(5, rd=5), ECALL]                  # target at 8
    rvfi = []
    writebacks, _ = await run(dut, program, rvfi=rvfi)
    assert final_regs(writebacks) == {5: 5}, f"retired {writebacks}"
    assert [r["pc_rdata"] for r in rvfi] == [0, 8, 12]
    await assert_stays_halted(dut)


@cocotb.test()
async def test_ebreak_stalled_behind_a_load_halts_once(dut):
    """ebreak's rs2 field is 1, so after lw x1 the stall comparator fires (a
    false match: ebreak reads nothing) and ID/EX takes a bubble holding a copy
    of the ebreak. If the bubble kept its halt bit, the copy would halt the
    core a cycle early and the real ebreak would be flushed, never retiring."""
    program = [enc_load(LW, rd=1, imm=32), EBREAK, enc_i(3, rd=3)]
    rvfi = []
    writebacks, _ = await run(dut, program, mem={32: 0x1234}, rvfi=rvfi)
    assert final_regs(writebacks) == {1: 0x1234}, f"retired {writebacks}"
    assert [r["insn"] for r in rvfi] == program[:2], "the ebreak did not retire"
    assert rvfi[-1]["halt"] == 1
    await assert_stays_halted(dut)


@cocotb.test()
async def test_fence_is_a_nop(dut):
    """A fence between a producer and its consumer changes nothing: no write,
    no stall, no lost forward."""
    program = [enc_i(7, rd=1), FENCE, enc_i(1, rs1=1, rd=2)]
    writebacks, _ = await run(dut, program, timed=True)
    assert [(r, v) for _, r, v in writebacks if r] == [(1, 7), (2, 8)]
    assert retire_cycle(writebacks, 2) - retire_cycle(writebacks, 1) == 2


# --- random programs against the golden model --------------------------------
# Directed tests above pin the cases we thought of; these find the ones we did
# not. Few registers, so nearly every instruction depends on a recent one, and
# x0 is a frequent destination, so a forwarded write to x0 shows up.

RANDOM_REGS = range(5)                 # x0-x4
IMM_CORNERS = [0, 1, -1, 2047, -2048, 0x400, -0x400]


def random_instruction(rng, pc):
    """One random instruction for address pc.

    Branches and jumps only go forward, 1-6 words, so every program ends:
    offset 1 is taken-but-to-the-next-instruction (still a redirect, still a
    flush), offset 2 skips exactly the instruction in IF/ID -- the classic
    flush-off-by-one case. One in ten targets has bit 1 set, which the
    misalignment assumption drops. jalr bases off x0, so its target is an
    absolute address known to be ahead; a forwarded jalr base is a directed
    test.
    """
    rd, rs1, rs2 = (rng.choice(RANDOM_REGS) for _ in range(3))
    kind = rng.choices(["op", "op_imm", "lui", "auipc", "load", "store",
                        "branch", "jal", "jalr", "fence"],
                       weights=[4, 4, 1, 1, 3, 2, 3, 1, 1, 1])[0]
    if kind == "fence":
        return FENCE
    if kind in ("branch", "jal", "jalr"):
        offset = 4 * rng.randint(1, 6) + (2 if rng.random() < 0.1 else 0)
        if kind == "branch":
            funct3 = rng.choice([BEQ, BNE, BLT, BGE, BLTU, BGEU])
            return enc_b(funct3, rs1, rs2, offset)
        if kind == "jal":
            return enc_jal(rd, offset)
        assert pc + offset < 2048, "jalr's absolute target outgrew its immediate"
        return enc_jalr(rd, 0, pc + offset)
    if kind == "op":
        funct3 = rng.randrange(8)
        alt = rng.random() < 0.5 and funct3 in (0b000, 0b101)
        return enc_r(funct3, rs1, rs2, rd, funct7=0b0100000 if alt else 0)
    if kind == "op_imm":
        funct3 = rng.randrange(8)
        if funct3 in (0b001, 0b101):
            alt = funct3 == 0b101 and rng.random() < 0.5
            imm = (0b0100000 << 5 if alt else 0) | rng.randrange(32)
        else:
            imm = rng.choice(IMM_CORNERS) if rng.random() < 0.3 \
                else rng.randrange(-2048, 2048)
        return enc_i(imm, rs1=rs1, funct3=funct3, rd=rd)
    if kind in ("lui", "auipc"):
        return enc_u(rng.randrange(1 << 20) << 12, rd=rd,
                     opcode=OPCODE_LUI if kind == "lui" else OPCODE_AUIPC)
    # Loads and stores address off x0, so addresses stay inside the preloaded
    # window whatever the registers hold. Forwarding into the address operand
    # is covered by a directed test instead.
    if kind == "load":
        funct3 = rng.choice([LB, LH, LW, LBU, LHU])
        size = 1 << (funct3 & 0b11)
        return enc_load(funct3, rd=rd, imm=rng.randrange(0, 64, size))
    funct3 = rng.choice([SB, SH, SW])
    size = 1 << funct3
    return enc_s(rng.randrange(0, 64, size), rs1=0, rs2=rs2, funct3=funct3)


# The farthest a random branch or jump reaches is 6 words, plus a misaligned
# half-word that the core drops, so a program that ends in this many halting
# instructions halts whichever path its last control transfer takes.
HALT_TAIL = 6


def random_program(rng, length, gap):
    """length random instructions, each followed by gap NOPs, then a tail of
    ECALL/EBREAK -- so every program also checks the halt: the exact
    retirement count, and that nothing retires after it.

    Starts by loading x1-x4 with random values. The register file has no reset
    (RV32I leaves x1-x31 undefined), so without this the core reads whatever
    the simulator initialised them to while the model reads 0 -- and they
    disagree on the very first instruction that reads a register it has not
    written.
    """
    program = []
    for rd in RANDOM_REGS[1:]:
        program += li(rd, rng.getrandbits(32))
    for _ in range(length):
        program += [random_instruction(rng, 4 * len(program))] + [NOP] * gap
    return program + [rng.choice([ECALL, EBREAK]) for _ in range(HALT_TAIL)]


async def check_against_model(dut, program, mem, min_taken=0):
    want_rvfi = []
    want_wb, model = run_model(program, mem, traces=want_rvfi)
    dut._log.info(f"model: {len(want_wb)} writebacks, {model.taken} redirects")
    # A random test whose branches are never taken tests nothing about flushing.
    assert model.taken >= min_taken, f"only {model.taken} redirects in the program"
    assert model.halted, "program ran off its end without reaching the halt tail"
    got_rvfi = []
    got_wb, got_mem = await run(dut, program, dict(mem), rvfi=got_rvfi)
    dut._log.info(f"RVFI: {check_rvfi(got_rvfi, want_rvfi)}")

    # Retirement order, not just final state: a dropped or duplicated
    # instruction can leave the same final registers but not the same history.
    want = [(rd, v) for rd, v in want_wb if rd != 0]
    got = [(rd, v) for rd, v in got_wb if rd != 0]
    for i, (g, w) in enumerate(zip(got, want)):
        assert g == w, (
            f"writeback #{i}: core x{g[0]}={g[1]:#010x}, model x{w[0]}={w[1]:#010x}"
        )
    assert len(got) == len(want), f"core retired {len(got)} writes, model {len(want)}"

    for addr in sorted(set(got_mem) | set(model.mem)):
        g, w = got_mem.get(addr, 0), model.mem.get(addr, 0)
        assert g == w, f"mem[{addr}]: core {g:#010x}, model {w:#010x}"


def seeded_rng(dut):
    seed = int(os.environ.get("SEED", "1"))
    dut._log.info(f"random seed {seed} (rerun with SEED={seed})")
    return random.Random(seed)


def random_mem(rng):
    return {a: rng.getrandbits(32) for a in range(0, 64, 4)}


@cocotb.test()
async def test_random_padded_programs_match_model(dut):
    """With HAZARD_GAP NOPs between instructions there are no hazards at all.

    This is the model's own test as much as the core's: the core's directed
    tests already pass, so a mismatch here most likely means the model is
    wrong.
    """
    rng = seeded_rng(dut)
    await check_against_model(dut, random_program(rng, 120, HAZARD_GAP), random_mem(rng),
                              min_taken=5)


@cocotb.test()
async def test_random_dense_programs_match_model(dut):
    """No padding: every hazard the random stream happens to produce."""
    rng = seeded_rng(dut)
    await check_against_model(dut, random_program(rng, 400, 0), random_mem(rng),
                              min_taken=20)
