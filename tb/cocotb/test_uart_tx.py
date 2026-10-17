"""UART transmitter: frame format, exact bit timing, and the ready handshake.

Run at the hardware's parameters (50 MHz, 115200 baud: 434 clocks a bit), so
the timing checked here is the timing the board gets. Everything is measured
in clock cycles, not nanoseconds: a bit that is one clock long or short is a
bug the line's receiver would mostly forgive and a test should not.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

CLK_PERIOD_NS = 20          # 50 MHz
CLKS_PER_BIT = 434          # round(50e6 / 115200)
FRAME_CLKS = 10 * CLKS_PER_BIT


async def start(dut):
    dut.valid_i.value = 0
    dut.data_i.value = 0
    dut.rst_i.value = 1
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    for _ in range(2):
        await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0


async def send(dut, byte):
    """Wait for ready, offer one byte for one cycle. Returns at the edge that takes it."""
    while not dut.ready_o.value:
        await FallingEdge(dut.clk_i)
    dut.data_i.value = byte
    dut.valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.valid_i.value = 0


async def receive(dut):
    """Decode one frame from tx_o, checking every bit's length to the clock.

    Waits for the start bit's falling edge, then samples each bit at its middle
    and checks the line holds that value for the whole bit time.
    """
    while dut.tx_o.value:
        await RisingEdge(dut.clk_i)
    bits = []
    for i in range(10):
        values = []
        for _ in range(CLKS_PER_BIT):
            values.append(int(dut.tx_o.value))
            await RisingEdge(dut.clk_i)
        assert len(set(values)) == 1, f"bit {i} not stable for {CLKS_PER_BIT} clocks: {values}"
        bits.append(values[0])
    assert bits[0] == 0, "start bit not low"
    assert bits[9] == 1, "stop bit not high"
    return sum(b << i for i, b in enumerate(bits[1:9]))


@cocotb.test()
async def test_idle_after_reset(dut):
    await start(dut)
    for _ in range(50):
        assert dut.tx_o.value == 1, "line not idle high"
        assert dut.ready_o.value == 1, "not ready while idle"
        await FallingEdge(dut.clk_i)


@cocotb.test()
async def test_one_byte(dut):
    """0xA5: alternating bits, both ends distinct, so a reversed or shifted frame shows."""
    await start(dut)
    rx = cocotb.start_soon(receive(dut))
    await send(dut, 0xA5)
    assert dut.ready_o.value == 0, "ready stayed high after taking a byte"
    assert await rx == 0xA5


@cocotb.test()
async def test_ready_low_for_exactly_one_frame(dut):
    """ready_o drops on the edge that takes the byte and returns 10 bit times later."""
    await start(dut)
    await send(dut, 0x00)
    busy = 1   # the cycle send() returned on is the first busy one
    while not dut.ready_o.value:
        await FallingEdge(dut.clk_i)
        busy += 1
    # The last busy cycle is the stop bit's final clock; ready rises after it.
    assert busy - 1 == FRAME_CLKS, f"busy for {busy - 1} clocks, expected {FRAME_CLKS}"


@cocotb.test()
async def test_back_to_back(dut):
    """Bytes sent as fast as ready allows arrive intact and in order."""
    await start(dut)
    data = [random.randrange(256) for _ in range(8)] + [0x00, 0xFF]
    got = []

    async def rx_all():
        for _ in data:
            got.append(await receive(dut))

    rx = cocotb.start_soon(rx_all())
    for b in data:
        await send(dut, b)
    await rx
    assert got == data


@cocotb.test()
async def test_valid_while_busy_ignored(dut):
    """A byte offered mid-frame is neither sent nor allowed to corrupt the frame."""
    await start(dut)
    rx = cocotb.start_soon(receive(dut))
    await send(dut, 0x3C)
    for _ in range(3 * CLKS_PER_BIT):
        await FallingEdge(dut.clk_i)
    dut.data_i.value = 0xFF
    dut.valid_i.value = 1
    for _ in range(CLKS_PER_BIT):
        await FallingEdge(dut.clk_i)
    dut.valid_i.value = 0
    assert await rx == 0x3C
    for _ in range(2 * FRAME_CLKS):
        assert dut.tx_o.value == 1, "a second frame was sent"
        await FallingEdge(dut.clk_i)
