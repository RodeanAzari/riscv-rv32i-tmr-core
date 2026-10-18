"""UART receiver: bytes in, the one-byte buffer, glitches, overrun, framing.

Run at the hardware's parameters (50 MHz, 115200 baud: 434 clocks a bit). The
sender below is the model: an 8N1 frame drawn on rx_i bit by bit, with each
bit edge placed at round(k * bit length) clocks, so a sender whose clock is a
few percent off is drawn exactly, not approximated.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

CLK_PERIOD_NS = 20          # 50 MHz
CLKS_PER_BIT = 434          # round(50e6 / 115200)


async def start(dut):
    dut.rx_i.value = 1
    dut.ack_i.value = 0
    dut.rst_i.value = 1
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    for _ in range(2):
        await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0
    for _ in range(4):
        await FallingEdge(dut.clk_i)


async def line(dut, bits, error=0.0):
    """Drive rx_i with these bit values, each (1 + error) bit times long."""
    length = CLKS_PER_BIT * (1 + error)
    t = 0
    for k, b in enumerate(bits, 1):
        dut.rx_i.value = b
        end = round(k * length)
        while t < end:
            await FallingEdge(dut.clk_i)
            t += 1
    dut.rx_i.value = 1


def frame(byte, stop=1):
    return [0] + [(byte >> i) & 1 for i in range(8)] + [stop]


async def send(dut, byte, error=0.0, stop=1, idle_bits=1):
    await line(dut, frame(byte, stop) + [1] * idle_bits, error)


async def ack(dut):
    dut.ack_i.value = 1
    await FallingEdge(dut.clk_i)
    dut.ack_i.value = 0


def flags(dut):
    return int(dut.valid_o.value), int(dut.overrun_o.value), int(dut.frame_err_o.value)


@cocotb.test()
async def test_idle_after_reset(dut):
    await start(dut)
    for _ in range(3 * CLKS_PER_BIT):
        assert flags(dut) == (0, 0, 0), "a flag set on an idle line"
        await FallingEdge(dut.clk_i)


@cocotb.test()
async def test_one_byte(dut):
    """0xA5: alternating bits, both ends distinct, so a reversed or shifted byte shows."""
    await start(dut)
    await send(dut, 0xA5)
    assert flags(dut) == (1, 0, 0)
    assert dut.data_o.value == 0xA5
    await ack(dut)
    assert flags(dut) == (0, 0, 0), "ack did not clear valid"


@cocotb.test()
async def test_valid_rises_in_the_stop_bit(dut):
    """The byte is ready mid-stop-bit: half a bit before the line could start again."""
    await start(dut)
    sender = cocotb.start_soon(line(dut, frame(0x5A)))
    clocks = 0
    while not dut.valid_o.value:
        await FallingEdge(dut.clk_i)
        clocks += 1
    # 9.5 bits to the stop bit's middle, plus the synchroniser's two flops.
    assert abs(clocks - (9.5 * CLKS_PER_BIT + 2)) <= 3, f"valid after {clocks} clocks"
    await sender


@cocotb.test()
async def test_random_bytes_back_to_back(dut):
    """Frames with no idle between them, acknowledged as they arrive, in order."""
    await start(dut)
    data = [random.randrange(256) for _ in range(64)] + [0x00, 0xFF]
    got = []

    async def reader():
        while len(got) < len(data):
            await FallingEdge(dut.clk_i)
            if dut.valid_o.value:
                got.append(int(dut.data_o.value))
                await ack(dut)

    r = cocotb.start_soon(reader())
    await line(dut, [b for x in data for b in frame(x)])
    for _ in range(CLKS_PER_BIT):
        await FallingEdge(dut.clk_i)
    r.cancel()
    assert got == data
    assert flags(dut)[1:] == (0, 0), "an error flag on clean frames"


@cocotb.test()
async def test_baud_error_tolerated(dut):
    """A sender 3% slow or fast, back to back, still decodes."""
    for error in (-0.03, +0.03):
        await start(dut)
        data = [random.randrange(256) for _ in range(16)]
        got = []

        async def reader():
            while True:
                await FallingEdge(dut.clk_i)
                if dut.valid_o.value:
                    got.append(int(dut.data_o.value))
                    await ack(dut)

        r = cocotb.start_soon(reader())
        await line(dut, [b for x in data for b in frame(x)], error)
        for _ in range(CLKS_PER_BIT):
            await FallingEdge(dut.clk_i)
        r.cancel()
        assert got == data, f"baud error {error:+.0%}: {got} != {data}"
        assert flags(dut)[1:] == (0, 0), f"baud error {error:+.0%}: an error flag"


@cocotb.test()
async def test_glitch_ignored(dut):
    """A low pulse shorter than half a bit is not a start bit."""
    await start(dut)
    dut.rx_i.value = 0
    for _ in range(CLKS_PER_BIT // 3):
        await FallingEdge(dut.clk_i)
    dut.rx_i.value = 1
    for _ in range(12 * CLKS_PER_BIT):
        assert flags(dut) == (0, 0, 0), "a glitch produced a byte or an error"
        await FallingEdge(dut.clk_i)
    await send(dut, 0x3C)
    assert flags(dut) == (1, 0, 0) and dut.data_o.value == 0x3C, "receiver stuck after a glitch"


@cocotb.test()
async def test_overrun_keeps_the_unread_byte(dut):
    await start(dut)
    await send(dut, 0x11)
    await send(dut, 0x22)
    assert flags(dut) == (1, 1, 0)
    assert dut.data_o.value == 0x11, "the unread byte was overwritten"
    await ack(dut)
    assert flags(dut) == (0, 0, 0), "ack did not clear overrun"
    await send(dut, 0x33)
    assert flags(dut) == (1, 0, 0) and dut.data_o.value == 0x33


@cocotb.test()
async def test_framing_error(dut):
    """A low stop bit drops the byte and flags it; the next good frame is received."""
    await start(dut)
    await send(dut, 0x7E, stop=0)
    assert flags(dut) == (0, 0, 1)
    await send(dut, 0x81)
    assert flags(dut) == (1, 0, 1) and dut.data_o.value == 0x81
    await ack(dut)
    assert flags(dut) == (0, 0, 0)


@cocotb.test()
async def test_break_is_one_error(dut):
    """A line held low for many frames is one framing error, not a run of zero bytes."""
    await start(dut)
    await line(dut, [0] * 40 + [1, 1])
    assert flags(dut) == (0, 0, 1)
    await send(dut, 0xC3)
    assert flags(dut) == (1, 0, 1) and dut.data_o.value == 0xC3


@cocotb.test()
async def test_reading_has_no_side_effect(dut):
    """Holding a byte unacknowledged for a long time changes nothing."""
    await start(dut)
    await send(dut, 0x96)
    for _ in range(5 * CLKS_PER_BIT):
        assert flags(dut) == (1, 0, 0) and dut.data_o.value == 0x96
        await FallingEdge(dut.clk_i)
