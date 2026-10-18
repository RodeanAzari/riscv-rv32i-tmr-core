"""CoreMark on the whole SoC: the benchmark's simulation image
(sw/build/coremark_sim.hex, from `make bench`, one iteration) runs from reset
and its report is read off the UART at the board's baud rate.

One iteration is far below CoreMark's 10-second minimum, so the score here is
not a result; the board run is, and here CoreMark reports its too-short run
as an error and so never prints "Correct operation validated". What this
checks instead is the three CRCs CoreMark computes, against the values its
README publishes for the 2K performance run: a core or port bug that changes
any computed value changes one. It is also the end-to-end test of the SoC's
cycle counter: the ticks CoreMark reports must be positive and no more than
the cycles simulated.

And it measures IPC. The core's RVFI port is compiled into every test build
(RISCV_FORMAL; observation only), so retirements can be counted. CoreMark's
timed region is bracketed by two loads from the cycle counter: the
instructions retired from the first to the second, over the ticks between
them, is the IPC of the benchmark's own code. The pipeline has no caches and
the memories are BRAM-timed in simulation as on the board, so the cycle
count of this run is the board's, iteration for iteration. The numbers go to
sim_build/coremark_sim.txt, to be copied to docs/reports/.
"""

import os

import re

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from test_soc import CLK_PERIOD_NS, assert_no_tmr_mismatch, uart_rx

DONE = re.compile(r"CoreMark/MHz: \d+\.\d{3}\r\n")
TOO_SHORT = "ERROR! Must execute for at least 10 secs for a valid result!"
# sw/coremark/README.md, 2K performance run (seeds 0, 0, 0x66)
EXPECTED_CRCS = {"seedcrc": 0xE9F5, "[0]crclist": 0xE714,
                 "[0]crcmatrix": 0x1FD7, "[0]crcstate": 0x8E3A}
BUDGET_CYCLES = 20_000_000
CYCLE_ADDR = 0x1000_0010


async def count_retirements(dut, marks):
    """Count RVFI retirements; append the count at each load of CYCLE."""
    core = dut.g_cpu.u_core
    n = 0
    while True:
        await FallingEdge(dut.clk_i)
        if core.rvfi_valid_o.value:
            n += 1
            if (int(core.rvfi_mem_addr_o.value) == CYCLE_ADDR
                    and int(core.rvfi_mem_rmask_o.value)):
                marks.append(n)


@cocotb.test()
async def test_coremark(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    dut.uart_rx_i.value = 1          # idle line
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 5)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0

    got = []
    marks = []
    cocotb.start_soon(uart_rx(dut, got))
    cocotb.start_soon(count_retirements(dut, marks))

    cycles = 0
    text = ""
    while cycles < BUDGET_CYCLES:
        await ClockCycles(dut.clk_i, 10_000)
        cycles += 10_000
        text = "".join(c for c, _ in got)
        if DONE.search(text):
            break
    dut._log.info("CoreMark report after %d cycles:\n%s", cycles, text)

    assert DONE.search(text), f"no CoreMark/MHz line in {cycles} cycles"
    assert "ERROR" not in text.replace(TOO_SHORT, ""), "CoreMark reported an error"
    for name, want in EXPECTED_CRCS.items():
        m = re.search(re.escape(name) + r"\s*:\s*0x([0-9a-f]+)", text)
        assert m, f"no {name} in the report"
        assert int(m.group(1), 16) == want, f"{name} {m.group(1)}, want {want:#06x}"

    ticks = int(re.search(r"Total ticks\s*:\s*(\d+)", text).group(1))
    assert 0 < ticks <= cycles, f"{ticks} ticks in {cycles} simulated cycles"

    assert len(marks) == 2, f"{len(marks)} loads of CYCLE, want 2"
    insns = marks[1] - marks[0]
    ipc = insns / ticks
    report = (f"CoreMark, 1 iteration, RTL simulation of rtl/top/soc.sv (Verilator)\n"
              f"timed region: {insns} instructions retired, {ticks} cycles\n"
              f"IPC {ipc:.4f}  CPI {1 / ipc:.4f}\n"
              f"CoreMark/MHz (1 iteration) {1e6 / ticks:.3f}\n")
    dut._log.info(report)
    with open(os.path.join("sim_build", "coremark_sim.txt"), "w") as f:
        f.write(report)
    assert 0 < ipc <= 1, f"IPC {ipc}"
    assert_no_tmr_mismatch(dut)
