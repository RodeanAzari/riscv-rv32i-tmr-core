"""Phase A: the five-stage core, IF through WB.

There is no back door into the register file: registers are set by executing
instructions (li() below), the way software sets them. Until the hazard unit
lands there is no forwarding either, so every dependent instruction trails its
producer by HAZARD_GAP NOPs -- see the header of rtl/core/riscv_core.sv.

Both memories are BRAM-timed models: they latch an address at a clock edge and
answer during the following cycle. The testbench must never be more forgiving
than the hardware. An earlier version answered IMEM within the cycle, and that
hid an IF bug that paired every instruction with the wrong PC.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

CLK_PERIOD_NS = 10
NOP = 0x0000_0013
MASK32 = 0xFFFF_FFFF

# IF -> ID -> EX -> MEM -> WB: a producer writes the register file three
# instructions after it is fetched, and the write-first bypass serves the
# instruction in ID that same cycle. Three NOPs is the minimum safe gap.
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
OPCODE_LOAD   = 0b0000011
OPCODE_STORE  = 0b0100011


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


def li(rd, value):
    """The assembler's li pseudo-instruction, padded for the missing forwarding.

    addi's immediate is sign-extended, so when the low 12 bits look negative the
    lui half has to round up by one to compensate -- the same "+0x800" every
    RISC-V assembler does for %hi/%lo.
    """
    value &= MASK32
    lo = ((value & 0xFFF) ^ 0x800) - 0x800          # sign-extended low 12 bits
    hi = (value - lo) & MASK32
    gap = [NOP] * HAZARD_GAP
    if hi == 0:
        return [enc_i(lo, rs1=0, rd=rd)] + gap
    return [enc_u(hi, rd=rd)] + gap + [enc_i(lo, rs1=rd, rd=rd)] + gap


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
    """Values written through the WB port show up as ID/EX operands."""
    await reset(dut)
    await release(dut)

    await set_reg(dut, 3, 0x1111_1111)
    await set_reg(dut, 4, 0x2222_2222)

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
async def test_unimplemented_instruction_is_inert(dut):
    """A branch decodes to no register write until branches are implemented."""
    await reset(dut)
    await release(dut)

    await drain(dut, 0x0000_0063 | (1 << 15) | (2 << 20))   # beq x1, x2, 0
    assert int(dut.ex_mem_rd_we_o.value) == 0, "unimplemented branch writes rd"


@cocotb.test()
async def test_control_travels_with_its_instruction(dut):
    """Back-to-back instructions keep their own control through the pipeline.

    Feeds add (writes x7) directly behind a branch (writes nothing) with no NOPs
    between, so a control signal latched in the wrong stage shows up as the
    wrong rd_we reaching EX/MEM.
    """
    await reset(dut)
    await release(dut)
    await set_reg(dut, 3, 5)
    await set_reg(dut, 4, 6)

    branch = 0x0000_0063 | (1 << 15) | (2 << 20)
    await feed(dut, branch)
    await feed_to(dut, enc_r(0b000, rs1=3, rs2=4, rd=7), EX_MEM)
    # branch is now past EX/MEM; the add is in EX/MEM
    assert int(dut.ex_mem_rd_we_o.value) == 1
    assert int(dut.ex_mem_rd_addr_o.value) == 7
    assert int(dut.ex_mem_alu_result_o.value) == 11


# --- MEM and WB -------------------------------------------------------------
# Whole programs from here on, loaded into IMEM from address 0.

async def run(dut, program, mem=None):
    """Reset, run program from address 0, drain it to WB.

    Returns (writebacks, mem): every register write WB performed, in retirement
    order, as (rd, value) -- x0 included, since a write to x0 still happens --
    and the data memory as the program left it.
    """
    mem = await reset(dut, program, mem)
    await release(dut)

    writebacks = []
    for _ in range(len(program) + MEM_WB + 1):
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
        if int(dut.wb_rd_we_o.value):
            writebacks.append((int(dut.wb_rd_addr_o.value),
                               int(dut.wb_rd_wdata_o.value)))
    return writebacks, mem


def final_regs(writebacks):
    """Last value written to each register, x0 excluded."""
    return {rd: v for rd, v in writebacks if rd != 0}


GAP = [NOP] * HAZARD_GAP

LB, LH, LW, LBU, LHU = 0b000, 0b001, 0b010, 0b100, 0b101
SB, SH, SW = 0b000, 0b001, 0b010


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
