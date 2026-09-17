"""Phase A: PC sequencing, IF/ID capture, and the ID stage."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

CLK_PERIOD_NS = 10
NOP = 0x0000_0013

# addi x1,x0,1 / addi x2,x0,2 / addi x3,x0,3
PROGRAM = [0x0000_0013, 0x0010_0093, 0x0020_0113, 0x0030_0193]


async def reset(dut):
    dut.rst_i.value = 1
    dut.imem_rdata_i.value = 0
    dut.wb_rd_we_i.value = 0
    dut.wb_rd_addr_i.value = 0
    dut.wb_rd_wdata_i.value = 0
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)


async def write_reg(dut, addr, value):
    """Drive the temporary WB write port. Collapses into WB when it exists."""
    dut.wb_rd_we_i.value = 1
    dut.wb_rd_addr_i.value = addr
    dut.wb_rd_wdata_i.value = value
    await RisingEdge(dut.clk_i)
    dut.wb_rd_we_i.value = 0
    await FallingEdge(dut.clk_i)


async def feed(dut, instr):
    """Present one instruction to IF and advance a cycle."""
    dut.imem_rdata_i.value = instr
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)


@cocotb.test()
async def test_reset_state(dut):
    """Out of reset the core fetches from the reset vector with a NOP in IF/ID."""
    await reset(dut)
    assert dut.imem_addr_o.value == 0, f"pc={dut.imem_addr_o.value}"
    assert dut.if_id_instr_o.value == NOP, f"if_id_instr_o={dut.if_id_instr_o.value}"


@cocotb.test()
async def test_pc_increments_by_four(dut):
    """PC advances one word per cycle when nothing stalls it."""
    await reset(dut)
    dut.rst_i.value = 0
    for expected in (4, 8, 12, 16):
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
        assert dut.imem_addr_o.value == expected, (
            f"expected pc={expected}, got {dut.imem_addr_o.value}"
        )


@cocotb.test()
async def test_if_id_captures_fetched_word(dut):
    """Each fetched instruction lands in IF/ID the cycle after its address is driven."""
    await reset(dut)
    dut.rst_i.value = 0

    for _ in range(len(PROGRAM)):
        word = int(dut.imem_addr_o.value) >> 2
        fetched = PROGRAM[word] if word < len(PROGRAM) else NOP
        dut.imem_rdata_i.value = fetched

        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)

        assert int(dut.if_id_instr_o.value) == fetched, (
            f"word {word}: expected {fetched:#010x}, got {int(dut.if_id_instr_o.value):#010x}"
        )


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
    dut.rst_i.value = 0

    await feed(dut, ADDI_X5_X3_M1)   # lands in IF/ID
    await feed(dut, NOP)             # IF/ID -> ID/EX

    assert int(dut.id_ex_instr_o.value) == ADDI_X5_X3_M1
    assert int(dut.id_ex_rs1_addr_o.value) == 3
    assert int(dut.id_ex_rd_addr_o.value) == 5
    assert int(dut.id_ex_imm_o.value) == 0xFFFF_FFFF, "immediate not sign-extended"


@cocotb.test()
async def test_id_ex_carries_rvfi_shadow_addresses(dut):
    """rs1/rs2 addresses ride ID/EX as RVFI shadow fields -- docs/rvfi-plan.md."""
    await reset(dut)
    dut.rst_i.value = 0

    await feed(dut, ADD_X7_X3_X4)
    await feed(dut, NOP)

    assert int(dut.id_ex_rs1_addr_o.value) == 3
    assert int(dut.id_ex_rs2_addr_o.value) == 4
    assert int(dut.id_ex_rd_addr_o.value) == 7


@cocotb.test()
async def test_regfile_read_reaches_id_ex(dut):
    """Values written through the WB port show up as ID/EX operands."""
    await reset(dut)
    dut.rst_i.value = 0

    await write_reg(dut, 3, 0x1111_1111)
    await write_reg(dut, 4, 0x2222_2222)

    await feed(dut, ADD_X7_X3_X4)
    await feed(dut, NOP)

    assert int(dut.id_ex_rs1_rdata_o.value) == 0x1111_1111
    assert int(dut.id_ex_rs2_rdata_o.value) == 0x2222_2222


@cocotb.test()
async def test_x0_reads_zero_through_the_core(dut):
    """x0 invariance holds at the core level, not just in the unit test."""
    await reset(dut)
    dut.rst_i.value = 0

    await write_reg(dut, 0, 0xFFFF_FFFF)

    # add x7, x0, x0 -- both operands read x0
    await feed(dut, 0x0000_03B3)
    await feed(dut, NOP)

    assert int(dut.id_ex_rs1_rdata_o.value) == 0
    assert int(dut.id_ex_rs2_rdata_o.value) == 0


# --- EX stage --------------------------------------------------------------
# An instruction fed at cycle N reaches IF/ID at N+1, ID/EX at N+2, EX/MEM at
# N+3. drain() walks it the whole way so a test can assert on EX/MEM.

OPCODE_OP     = 0b0110011
OPCODE_OP_IMM = 0b0010011
OPCODE_LUI    = 0b0110111
OPCODE_AUIPC  = 0b0010111
OPCODE_BRANCH = 0b1100011


def enc_i(imm, rs1=0, funct3=0, rd=0, opcode=OPCODE_OP_IMM):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_r(funct3, rs1, rs2, rd, funct7=0):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) \
        | (rd << 7) | OPCODE_OP


def enc_u(imm, rd=0, opcode=OPCODE_LUI):
    return (imm & 0xFFFF_F000) | (rd << 7) | opcode


async def drain(dut, instr):
    """Feed one instruction and walk it to EX/MEM. Returns the PC it saw."""
    pc = int(dut.imem_addr_o.value)
    await feed(dut, instr)
    await feed(dut, NOP)
    await feed(dut, NOP)
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
    dut.rst_i.value = 0

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
    dut.rst_i.value = 0
    await write_reg(dut, 3, 100)

    await drain(dut, enc_i(-1, rs1=3, rd=6))
    assert int(dut.ex_mem_alu_result_o.value) == 99, "addi -1 behaved as a subtract"


@cocotb.test()
async def test_register_register_add_and_sub(dut):
    await reset(dut)
    dut.rst_i.value = 0
    await write_reg(dut, 3, 70)
    await write_reg(dut, 4, 12)

    await drain(dut, enc_r(0b000, rs1=3, rs2=4, rd=7))
    assert int(dut.ex_mem_alu_result_o.value) == 82

    await drain(dut, enc_r(0b000, rs1=3, rs2=4, rd=7, funct7=0b0100000))
    assert int(dut.ex_mem_alu_result_o.value) == 58


@cocotb.test()
async def test_lui_places_upper_immediate(dut):
    """lui x8, 0x12345 -> 0x12345000, with rs1 ignored."""
    await reset(dut)
    dut.rst_i.value = 0
    await write_reg(dut, 1, 0xFFFF_FFFF)   # must not leak into the result

    await drain(dut, enc_u(0x1234_5000, rd=8))
    assert int(dut.ex_mem_alu_result_o.value) == 0x1234_5000
    assert int(dut.ex_mem_rd_addr_o.value) == 8


@cocotb.test()
async def test_auipc_adds_its_own_pc(dut):
    """auipc uses the PC of the auipc itself, not the fetch PC three stages on."""
    await reset(dut)
    dut.rst_i.value = 0

    pc = await drain(dut, enc_u(0x0001_0000, rd=9, opcode=OPCODE_AUIPC))
    assert int(dut.ex_mem_alu_result_o.value) == (pc + 0x0001_0000) & 0xFFFF_FFFF, (
        f"auipc used the wrong pc (instruction pc was {pc:#010x})"
    )


@cocotb.test()
async def test_slt_signed_through_the_core(dut):
    """slt x10, x3, x4 with x3 = -1, x4 = 1 -> 1. Unsigned would give 0."""
    await reset(dut)
    dut.rst_i.value = 0
    await write_reg(dut, 3, 0xFFFF_FFFF)
    await write_reg(dut, 4, 1)

    await drain(dut, enc_r(0b010, rs1=3, rs2=4, rd=10))
    assert int(dut.ex_mem_alu_result_o.value) == 1, "slt compared unsigned"

    await drain(dut, enc_r(0b011, rs1=3, rs2=4, rd=10))
    assert int(dut.ex_mem_alu_result_o.value) == 0, "sltu compared signed"


@cocotb.test()
async def test_unimplemented_instruction_is_inert(dut):
    """A branch decodes to no register write until branches are implemented."""
    await reset(dut)
    dut.rst_i.value = 0

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
    dut.rst_i.value = 0
    await write_reg(dut, 3, 5)
    await write_reg(dut, 4, 6)

    branch = 0x0000_0063 | (1 << 15) | (2 << 20)
    await feed(dut, branch)
    await feed(dut, enc_r(0b000, rs1=3, rs2=4, rd=7))
    await feed(dut, NOP)
    await feed(dut, NOP)
    # branch is now past EX/MEM; the add is in EX/MEM
    assert int(dut.ex_mem_rd_we_o.value) == 1
    assert int(dut.ex_mem_rd_addr_o.value) == 7
    assert int(dut.ex_mem_alu_result_o.value) == 11
