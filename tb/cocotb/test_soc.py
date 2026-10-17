"""First-light SoC, whole: the real firmware on the core, RAM, LEDs and UART.

The board's program (sw/firstlight/hello.c), built with a short delay loop
(sw/build/hello_sim.hex, from `make fw`), runs from reset. The UART line is
decoded at the board's own baud rate, so what this test reads is what the
serial terminal will show, and the LEDs are checked against the count the
program prints. If this passes and the board does not, suspect the board-
level pieces (clocking, reset, pins), not the SoC.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

CLK_PERIOD_NS = 20          # 50 MHz, as on the board
CLKS_PER_BIT = 434          # 115200 baud

GREETING = "\r\nhello from rv32i\r\nsum 1..100 = 5050\r\n"
COUNTS = 4


async def uart_rx(dut, out):
    """Decode 8N1 bytes from uart_tx_o forever, appending (char, LEDs) to out.

    The LEDs are sampled at the start bit: the byte was handed to the UART
    just before, while putc returns at once, so by the stop bit the program
    may already have moved the LEDs on.
    """
    while True:
        while dut.uart_tx_o.value:
            await RisingEdge(dut.clk_i)
        leds = int(dut.led_o.value)
        await ClockCycles(dut.clk_i, CLKS_PER_BIT // 2)
        assert dut.uart_tx_o.value == 0, "start bit glitch"
        byte = 0
        for i in range(8):
            await ClockCycles(dut.clk_i, CLKS_PER_BIT)
            byte |= int(dut.uart_tx_o.value) << i
        await ClockCycles(dut.clk_i, CLKS_PER_BIT)
        assert dut.uart_tx_o.value == 1, f"framing error after {byte:#04x}"
        out.append((chr(byte), leds))


@cocotb.test()
async def test_firstlight(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 5)
    await FallingEdge(dut.clk_i)
    assert dut.uart_tx_o.value == 1, "UART line not idle in reset"
    assert dut.led_o.value == 0, "LEDs not cleared by reset"
    dut.rst_i.value = 0

    got = []
    cocotb.start_soon(uart_rx(dut, got))

    want = GREETING + "".join(f"count {n}\r\n" for n in range(COUNTS))
    # Generous: the text takes about len(want) * 10 bit times.
    budget = (len(want) + 10) * 10 * CLKS_PER_BIT
    for _ in range(budget // 1000):
        await ClockCycles(dut.clk_i, 1000)
        if len(got) >= len(want):
            break
    text = "".join(c for c, _ in got)
    assert text[:len(want)] == want, f"UART said {text!r}"

    # Each "count n" line is printed after the program writes n to the LEDs;
    # the LEDs are 4 bits wide.
    pos = len(GREETING)
    for n in range(COUNTS):
        line = f"count {n}\r\n"
        leds = {led for _, led in got[pos:pos + len(line)]}
        assert leds == {n & 0xF}, f"LEDs {leds} while printing {line!r}"
        pos += len(line)
