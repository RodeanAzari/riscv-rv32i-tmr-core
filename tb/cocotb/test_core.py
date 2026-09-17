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
