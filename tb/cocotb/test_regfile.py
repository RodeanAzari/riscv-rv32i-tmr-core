"""Register file: x0 invariance, write/read, and WB->ID write-first forwarding.

Two of these are formal properties in CLAUDE.md 5.5 (x0 invariance, forwarding
correctness). Directed tests first, per 9 -- random stimulus is poor at hitting
"write and read the same register in the same cycle" on purpose.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

CLK_PERIOD_NS = 10
XLEN_MASK = 0xFFFF_FFFF


async def start(dut):
    """Clock up, write port idle. No reset: the array deliberately has none."""
    dut.rd_we_i.value = 0
    dut.rd_addr_i.value = 0
    dut.rd_wdata_i.value = 0
    dut.rs1_addr_i.value = 0
    dut.rs2_addr_i.value = 0
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)


async def write(dut, addr, value):
    """Drive one synchronous write and let it land."""
    dut.rd_we_i.value = 1
    dut.rd_addr_i.value = addr
    dut.rd_wdata_i.value = value
    await RisingEdge(dut.clk_i)
    dut.rd_we_i.value = 0
    await FallingEdge(dut.clk_i)


@cocotb.test()
async def test_write_then_read(dut):
    """A written register reads back on both ports."""
    await start(dut)
    await write(dut, 5, 0xDEAD_BEEF)

    dut.rs1_addr_i.value = 5
    dut.rs2_addr_i.value = 5
    await FallingEdge(dut.clk_i)

    assert int(dut.rs1_rdata_o.value) == 0xDEAD_BEEF
    assert int(dut.rs2_rdata_o.value) == 0xDEAD_BEEF


@cocotb.test()
async def test_ports_are_independent(dut):
    """The two read ports address the array separately."""
    await start(dut)
    await write(dut, 1, 0x1111_1111)
    await write(dut, 2, 0x2222_2222)

    dut.rs1_addr_i.value = 1
    dut.rs2_addr_i.value = 2
    await FallingEdge(dut.clk_i)

    assert int(dut.rs1_rdata_o.value) == 0x1111_1111
    assert int(dut.rs2_rdata_o.value) == 0x2222_2222


@cocotb.test()
async def test_x0_reads_zero_after_write(dut):
    """x0 reads zero however hard it is written. CLAUDE.md 5.5."""
    await start(dut)
    await write(dut, 0, 0xFFFF_FFFF)

    dut.rs1_addr_i.value = 0
    dut.rs2_addr_i.value = 0
    await FallingEdge(dut.clk_i)

    assert int(dut.rs1_rdata_o.value) == 0, "x0 kept a written value"
    assert int(dut.rs2_rdata_o.value) == 0, "x0 kept a written value"


@cocotb.test()
async def test_x0_reads_zero_during_write(dut):
    """The write-first bypass must not forward a write to x0 either.

    This is the case the bypass mux gets wrong if the x0 check is placed
    inside it rather than ahead of it: the architectural write is suppressed,
    but the forwarded value sails past.
    """
    await start(dut)

    dut.rd_we_i.value = 1
    dut.rd_addr_i.value = 0
    dut.rd_wdata_i.value = 0xCAFE_F00D
    dut.rs1_addr_i.value = 0
    await FallingEdge(dut.clk_i)

    assert int(dut.rs1_rdata_o.value) == 0, "x0 forwarded a suppressed write"


@cocotb.test()
async def test_write_first_forwarding(dut):
    """Reading the register being written this cycle returns the NEW value.

    CLAUDE.md 5.3 calls this WB->ID internal forwarding. Without it, an
    instruction in ID reading a register that WB is writing in the same cycle
    gets a stale value and no amount of EX forwarding can recover it.
    """
    await start(dut)
    await write(dut, 7, 0x0000_0001)          # old value

    # Same cycle: write 0x2 to x7 while reading x7.
    dut.rd_we_i.value = 1
    dut.rd_addr_i.value = 7
    dut.rd_wdata_i.value = 0x0000_0002
    dut.rs1_addr_i.value = 7
    dut.rs2_addr_i.value = 7
    await FallingEdge(dut.clk_i)

    assert int(dut.rs1_rdata_o.value) == 0x0000_0002, "read-first, not write-first"
    assert int(dut.rs2_rdata_o.value) == 0x0000_0002, "read-first, not write-first"


@cocotb.test()
async def test_no_forward_to_other_registers(dut):
    """The bypass fires only for the register actually being written."""
    await start(dut)
    await write(dut, 9, 0xAAAA_AAAA)

    dut.rd_we_i.value = 1
    dut.rd_addr_i.value = 10
    dut.rd_wdata_i.value = 0xBBBB_BBBB
    dut.rs1_addr_i.value = 9
    await FallingEdge(dut.clk_i)

    assert int(dut.rs1_rdata_o.value) == 0xAAAA_AAAA, "bypass leaked to x9"


@cocotb.test()
async def test_write_disabled_does_not_store(dut):
    """rd_we_i low means no write, and no bypass."""
    await start(dut)
    await write(dut, 3, 0x1234_5678)

    dut.rd_we_i.value = 0
    dut.rd_addr_i.value = 3
    dut.rd_wdata_i.value = 0x8765_4321
    dut.rs1_addr_i.value = 3
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)

    assert int(dut.rs1_rdata_o.value) == 0x1234_5678, "wrote with rd_we_i low"


@cocotb.test()
async def test_all_registers_hold_independently(dut):
    """Fill x1-x31 with distinct values, then read them all back.

    Catches address-decode faults that a single-register test cannot: a stuck
    or swapped address bit still passes "write x5, read x5".
    """
    await start(dut)
    random.seed(20260917)
    expected = {r: random.getrandbits(32) for r in range(1, 32)}

    for reg, value in expected.items():
        await write(dut, reg, value)

    for reg, value in expected.items():
        dut.rs1_addr_i.value = reg
        await FallingEdge(dut.clk_i)
        assert int(dut.rs1_rdata_o.value) == value, (
            f"x{reg}: expected {value:#010x}, got {int(dut.rs1_rdata_o.value):#010x}"
        )
