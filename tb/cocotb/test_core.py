"""Phase A, step 1: PC sequencing and IF/ID capture."""

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
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
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
