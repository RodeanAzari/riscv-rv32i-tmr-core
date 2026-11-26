"""The tiny-LLM demo (sw/llm/) on the whole SoC: the LLM build's 384 KiB RAM,
RV32IM core, the accelerator on the core clock (soc_llm in the Makefile).

The RAM starts with the LLM build's bootloader and the simulation image of
sw/llm/llm_app.c saved (sw/build/boot_llm_sim.hex), reached with r. The
image runs three positions of "Once upon a time" twice: matrix products on
the core, then on the accelerator.

What matters and why:
  - every position's next token and the CRC-32 of all 512 logits equal the
    golden model's (sw/build/llm/llm_vectors.txt, from sw/model/llm_model.py):
    the RV32IM build of llm.c computes what the model computes, 64-bit
    arithmetic through libgcc included, which the native check (make
    llm-host) cannot show;
  - the accelerator run gives exactly the software run's logits: the array's
    INT32 sums are the core's, so the products moved to it change nothing
    but time;
  - no bus error and no gemm_run failure.
"""

from pathlib import Path
import re

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from mmcm_bfm import start_array_clock
from test_demo import CLK_PERIOD_NS, CLKS_PER_BIT, uart_out

VECTORS = Path(__file__).resolve().parents[2] / "sw" / "build" / "llm" / "llm_vectors.txt"
RUN_POS = 3                  # llm_sim.elf's LLM_RUN_POS (Makefile)


@cocotb.test()
async def test_llm(dut):
    out = []
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    start_array_clock(dut)
    dut.uart_rx_i.value = 1
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 5)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0
    cocotb.start_soon(uart_out(dut, out))

    async def expect(text, cycles):
        for _ in range(0, cycles, 10_000):
            if text in "".join(out):
                return "".join(out)
            await ClockCycles(dut.clk_i, 10_000)
        raise AssertionError(f"waited for {text!r}; output was {''.join(out)[-800:]!r}")

    await expect("or r to rerun the last one\r\n", 200_000)
    for bit in [0] + [(ord("r") >> i) & 1 for i in range(8)] + [1]:
        dut.uart_rx_i.value = bit
        await ClockCycles(dut.clk_i, CLKS_PER_BIT)
    text = await expect("llm: done", 60_000_000)
    text = text[text.index("llm:"):]
    dut._log.info("\n" + text)
    assert "FAIL" not in text, text

    want = {}
    for line in VECTORS.read_text().splitlines():
        f = line.split()
        if f and f[0].isdigit():
            want[int(f[0])] = (int(f[1]), f[2])
    got = {"sw": {}, "array": {}}
    for mode, pos, tok, crc, cycles in re.findall(
            r"llm: (sw|array) (\d+) (\d+) ([0-9a-f]{8}) (\d+)", text):
        got[mode][int(pos)] = (int(tok), crc)
    for mode in got:
        assert sorted(got[mode]) == list(range(RUN_POS)), f"{mode}: positions {sorted(got[mode])}"
        for pos in range(RUN_POS):
            assert got[mode][pos] == want[pos], \
                f"{mode} position {pos}: token, CRC {got[mode][pos]}, model {want[pos]}"
    assert re.search(r"llm: done\r", text), "the run reported a failure"
