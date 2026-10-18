"""The serial bootloader on the whole SoC: programs sent over the UART's RX pin.

The SoC runs sw/build/boot.hex, the same image the bitstream carries, and the
test plays scripts/load.py's part bit by bit on uart_rx_i: the protocol, a
CRC failure, the program running and answering keys, its return to the
bootloader, and rerunning it with r. The program is sw/apps/echo.c.
"""

import struct
import zlib
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from test_soc import CLK_PERIOD_NS, CLKS_PER_BIT, assert_no_tmr_mismatch, uart_rx

REPO = Path(__file__).resolve().parents[2]
ECHO = (REPO / "sw/build/apps/echo.bin").read_bytes()
BANNER = "\r\nrv32i bootloader: send a program (scripts/load.py)\r\n"
BANNER_SAVED = ("\r\nrv32i bootloader: send a program (scripts/load.py),"
                " or r to rerun the last one\r\n")


async def start(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    dut.uart_rx_i.value = 1
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 5)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0
    got = []
    cocotb.start_soon(uart_rx(dut, got))
    return got


async def send(dut, data):
    """8N1 frames on uart_rx_i, back to back, at the SoC's baud rate."""
    for byte in data:
        for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            dut.uart_rx_i.value = bit
            await ClockCycles(dut.clk_i, CLKS_PER_BIT)


def packet(image, crc=None):
    return b"RVLD" + struct.pack("<II", len(image),
                                 zlib.crc32(image) if crc is None else crc) + image


async def expect(dut, got, text, frames=None):
    """Wait until the output so far ends with text.

    Fails after time to send `frames` characters (default: the text itself),
    plus a million cycles for whatever runs first -- a CRC over the program
    before a rerun takes about 150,000. The slack costs time only on failure.
    """
    budget = ((frames or len(text)) + 20) * 10 * CLKS_PER_BIT + 1_000_000
    for _ in range(0, budget, 1000):
        out = "".join(c for c, _ in got)
        if out.endswith(text):
            return out
        await ClockCycles(dut.clk_i, 1000)
    raise AssertionError(f"waited for {text!r}, got {''.join(c for c, _ in got)!r}")


@cocotb.test()
async def test_banner(dut):
    got = await start(dut)
    await expect(dut, got, BANNER)


@cocotb.test()
async def test_bad_crc_then_noise_then_load_and_run(dut):
    """A corrupt image is refused; bytes before the magic are ignored; a good one runs."""
    got = await start(dut)
    await expect(dut, got, BANNER)
    bad = bytes(range(32))
    await send(dut, packet(bad, crc=zlib.crc32(bad) ^ 1))
    await expect(dut, got, f"ERR crc {zlib.crc32(bad):08x}\r\n")

    await send(dut, b"xyz" + packet(ECHO))
    await expect(dut, got, "OK\r\necho: type, q to quit\r\n", frames=len(ECHO))

    await send(dut, b"hi!")
    await expect(dut, got, "HI!")
    assert got[-1][1] == ord("!") & 0xF, "LEDs do not show the last key"

    await send(dut, b"q")
    out = await expect(dut, got, BANNER_SAVED, frames=160)
    assert "echo: bye after " in out, "the program did not finish"
    assert_no_tmr_mismatch(dut)


@cocotb.test()
async def test_reset_and_rerun(dut):
    """After RESET the RAM still holds the program (the previous test's): r runs it again."""
    got = await start(dut)
    await expect(dut, got, BANNER_SAVED)
    await send(dut, b"r")
    await expect(dut, got, "OK\r\necho: type, q to quit\r\n")
    await send(dut, b"ok")
    await expect(dut, got, "OK\r\necho: type, q to quit\r\nOK")
    assert_no_tmr_mismatch(dut)
