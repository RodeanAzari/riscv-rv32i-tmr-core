"""The SoC's external window (soc EXT_EN, fpga-coord 0014) on the whole SoC.

The RAM starts with the bootloader and sw/apps/exttest.c saved
(sw/build/boot_ext_sim.hex), reached with r. exttest reads and writes the
window at 0x2000_2000; this test is the register block on the ext_* ports.

The register model holds the whole 4 KiB window (1024 words) and answers
SLVERR at the last word (0xFFC), OKAY elsewhere. It stalls: AWREADY, WREADY
and ARREADY stay low for a random number of cycles once VALID is up (the
first AW and the first AR for 200 cycles, so a long stall always happens),
and B and R come a random number of cycles after they could.

What matters and why (P4's acceptance test, 0014):
  - the core writes, then reads back, words, halfwords and bytes in the
    window and gets what it wrote, with BUSERR clear: the window carries
    loads and stores whatever the slave's timing;
  - only the strobed lanes change (sb, sh): P4's registers see the core's
    byte enables, not a read-modify-write;
  - SLVERR from the slave sets BUSERR, for a store and for a load: a
    consumer's errors reach software;
  - a load from 0x2000_3000 is still DECERR: the window is exactly 4 KiB;
  - on ext_*, VALID stays up and the payload stable until READY (AXI's
    rule for a master), whatever the stalls; the window's offsets are what
    the core addressed.
"""

import random
import re

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from mmcm_bfm import start_array_clock
from test_demo import CLK_PERIOD_NS, CLKS_PER_BIT, uart_out

SLVERR_OFF = 0xFFC
OKAY, SLVERR = 0, 2
FIRST_STALL = 200


def stall():
    r = random.random()
    if r < 0.5:
        return 0
    if r < 0.85:
        return random.randint(1, 12)
    return random.randint(40, 150)


class ExtSlave:
    """AXI4-Lite slave on the ext_* ports. Everything happens at falling
    edges: the SoC's outputs there are what the next rising edge samples
    (none of them depends on this model's outputs), so a handshake at that
    edge is decided now from VALID and READY as they stand."""

    def __init__(self, dut):
        self.dut = dut
        self.mem = [0] * 1024
        self.log = []                    # ("w", off, data, strb, resp) / ("r", off, data, resp)
        self.max_stall = 0
        self.aw = self.w = None          # taken, waiting for the other half
        self.aw_stall, self.w_stall, self.ar_stall = FIRST_STALL, stall(), FIRST_STALL
        self.waited = {"aw": 0, "w": 0, "ar": 0}
        self.b = None                    # [delay, resp] once both halves are in
        self.r = None                    # [delay, data, resp]
        self.b_hs = self.r_hs = False
        self.prev = {}
        for name in ("awready_i", "wready_i", "bvalid_i", "arready_i", "rvalid_i"):
            getattr(dut, "ext_" + name).value = 0
        dut.ext_bresp_i.value = 0
        dut.ext_rresp_i.value = 0
        dut.ext_rdata_i.value = 0

    def sig(self, name):
        return int(getattr(self.dut, "ext_" + name).value)

    def held(self, ch, valid, payload, ready):
        """AXI: once VALID is up it stays up, payload unchanged, until READY."""
        p = self.prev.get(ch)
        if p is not None and p[0] and not p[2]:
            assert valid, f"{ch}: VALID dropped before READY"
            assert payload == p[1], f"{ch}: payload changed before READY: {p[1]} -> {payload}"
        self.prev[ch] = (valid, payload, valid and ready)

    def ready(self, ch, free, valid):
        """READY for a channel this model accepts on: low while it stalls."""
        if not (free and valid):
            return 0
        left = getattr(self, ch + "_stall")
        if left:
            setattr(self, ch + "_stall", left - 1)
            self.waited[ch] += 1
            return 0
        self.max_stall = max(self.max_stall, self.waited[ch])
        self.waited[ch] = 0
        setattr(self, ch + "_stall", stall())
        return 1

    async def run(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.clk_i)
            if int(dut.rst_i.value):
                continue
            # B and R taken at the last edge: drop them
            if self.b_hs:
                self.b, self.b_hs = None, False
                dut.ext_bvalid_i.value = 0
            if self.r_hs:
                self.r, self.r_hs = None, False
                dut.ext_rvalid_i.value = 0

            awv, wv, arv = self.sig("awvalid_o"), self.sig("wvalid_o"), self.sig("arvalid_o")
            awa, ara = self.sig("awaddr_o"), self.sig("araddr_o")
            wd, ws = self.sig("wdata_o"), self.sig("wstrb_o")

            awr = self.ready("aw", self.aw is None and self.b is None, awv)
            wr = self.ready("w", self.w is None and self.b is None, wv)
            arr = self.ready("ar", self.r is None, arv)
            dut.ext_awready_i.value = awr
            dut.ext_wready_i.value = wr
            dut.ext_arready_i.value = arr
            self.held("aw", awv, awa, awr)
            self.held("w", wv, (wd, ws), wr)
            self.held("ar", arv, ara, arr)
            if awv and awr:
                self.aw = awa
            if wv and wr:
                self.w = (wd, ws)

            if self.aw is not None and self.w is not None and self.b is None:
                off, (data, strb) = self.aw, self.w
                resp = SLVERR if off & ~3 == SLVERR_OFF else OKAY
                if resp == OKAY:
                    word = self.mem[off >> 2]
                    for lane in range(4):
                        if strb >> lane & 1:
                            mask = 0xFF << (8 * lane)
                            word = (word & ~mask) | (data & mask)
                    self.mem[off >> 2] = word
                self.log.append(("w", off, data, strb, resp))
                self.aw = self.w = None
                self.b = [random.randint(0, 6), resp]
            if arv and arr:
                resp = SLVERR if ara & ~3 == SLVERR_OFF else OKAY
                data = self.mem[ara >> 2] if resp == OKAY else 0
                self.log.append(("r", ara, data, resp))
                self.r = [random.randint(0, 6), data, resp]

            for ch in ("b", "r"):
                pend = getattr(self, ch)
                if pend is None:
                    continue
                if pend[0]:
                    pend[0] -= 1
                    continue
                if ch == "b":
                    dut.ext_bresp_i.value = pend[1]
                    dut.ext_bvalid_i.value = 1
                    self.b_hs = bool(self.sig("bready_o"))
                else:
                    dut.ext_rdata_i.value = pend[1]
                    dut.ext_rresp_i.value = pend[2]
                    dut.ext_rvalid_i.value = 1
                    self.r_hs = bool(self.sig("rready_o"))


@cocotb.test()
async def test_ext(dut):
    out = []
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    start_array_clock(dut)
    slave = ExtSlave(dut)
    dut.uart_rx_i.value = 1
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 5)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0
    cocotb.start_soon(uart_out(dut, out))
    cocotb.start_soon(slave.run())

    async def expect(text, cycles=20_000_000):
        for _ in range(0, cycles, 2000):
            if text in "".join(out):
                return "".join(out)
            await ClockCycles(dut.clk_i, 2000)
        raise AssertionError(f"waited for {text!r}; output was {''.join(out)[-800:]!r}")

    await expect("or r to rerun the last one\r\n")
    for bit in [0] + [(ord("r") >> i) & 1 for i in range(8)] + [1]:
        dut.uart_rx_i.value = bit
        await ClockCycles(dut.clk_i, CLKS_PER_BIT)
    text = await expect(" ok\r\n")
    text = text[text.index("exttest:"):]
    dut._log.info("\n" + text)

    summary = re.search(r"exttest: (\d+)/(\d+) ok", text)
    assert summary and summary[1] == summary[2], f"exttest failed:\n{text}"
    assert int(summary[2]) >= 11, "exttest ran fewer checks than it has"
    assert "FAIL" not in text
    assert "exttest: slverr store 1 load 1" in text, "the slave's SLVERR did not reach BUSERR"

    # what the slave saw: the window's offsets as the core addressed them
    writes = [(e[1], e[2], e[3]) for e in slave.log if e[0] == "w"]
    reads = [e[1] for e in slave.log if e[0] == "r"]
    want = {0x000: 0x01234567, 0x004: 0x89ABCDEF, 0x7FC: 0xDEADBEEF,
            0xFF8: 0x5A5AA5A5, 0x010: 0xBEEFAA44}
    got = {4 * i: v for i, v in enumerate(slave.mem) if v}
    assert got == want, f"window contents {[(hex(k), hex(v)) for k, v in got.items()]}"
    assert any(o & ~3 == 0x010 and s == 0b0010 and (d >> 8) & 0xFF == 0xAA
               for o, d, s in writes), "sb did not arrive as lane 1 alone"
    assert any(o & ~3 == 0x010 and s == 0b1100 and d >> 16 == 0xBEEF
               for o, d, s in writes), "sh did not arrive as lanes 2-3 alone"
    assert any(o & ~3 == SLVERR_OFF for o, _, _ in writes) and \
           any(o & ~3 == SLVERR_OFF for o in reads), \
        "the SLVERR word was not accessed both ways"
    assert all(o < 0x1000 for o, _, _ in writes) and all(o < 0x1000 for o in reads)
    assert slave.max_stall >= FIRST_STALL, f"longest READY stall {slave.max_stall} cycles"
    dut._log.info(f"slave: {len(writes)} writes, {len(reads)} reads, longest stall "
                  f"{slave.max_stall} cycles")
