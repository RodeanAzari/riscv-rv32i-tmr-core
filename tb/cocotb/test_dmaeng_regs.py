"""DMA engine registers behind AXI4-Lite, against the golden model.

sw/model/dmaeng_model.py (DMA-Engine's QEMU device, ported before any RTL) is
the reference for every register: the mirror below is the model itself with
descriptor processing switched off, so it keeps only the register semantics
(BUSY = has_work, RESET clears all, W1C, HEAD wrap, the level interrupt). The
descriptor engine is not built yet; the test plays it, through the ports the
engine will drive, and only while run_o says there is work, as the engine
will.

What matters and why:
  - every read, irq_o and run_o equal the model's, through thousands of
    random register writes, reads and engine reports: the driver built in
    DMA-Engine against this model must see the same device on this SoC;
  - a write and read on AXI4-Lite completes whatever the order and delay of
    AW, W, B and R, since the core's interconnect will not order them;
  - an engine report in the same cycle as a register write is not lost
    (IRQ_STATUS W1C), and CTRL.RESET in that cycle wins (the driver
    reprograms everything after a reset and must find nothing left over);
  - a write without all four strobes changes nothing and answers SLVERR
    (registers are 32-bit only, DMA-Engine rule 1).
"""

import os
from pathlib import Path
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import dmaeng_model  # noqa: E402
from dmaeng_model import C  # noqa: E402

CLK_PERIOD_NS = 10
OKAY, SLVERR = 0, 2
MASK32 = 0xFFFF_FFFF
REGS = sorted(v for k, v in C.items() if k.startswith("REG_"))
WRITABLE = [C[f"REG_{r}"] for r in
            ("CTRL", "RING_BASE_LO", "RING_BASE_HI", "RING_SIZE", "TAIL",
             "IRQ_STATUS", "IRQ_MASK")]
UNMAPPED = [0x034, 0x0FC, 0x100, 0xFFC, 0x009, 0x022]   # incl. unaligned
ERR_CODES = [C["ERR_BAD_LEN"], C["ERR_DMA_FAIL"], C["ERR_BAD_DESC"]]


class Mirror(dmaeng_model.Dmaeng):
    """The golden model's registers, without its descriptor processing."""

    def kick(self):
        self.update_busy()

    def engine(self, adv=False, irq=False, err=0):
        """What the engine reports, applied as the model applies it."""
        if adv:
            self.advance_head()
            if irq:
                self.irq_status |= C["IRQ_STATUS_COMPLETION"]
                self.update_irq()
        if err:
            self.error(err)
        self.update_busy()


def rng_for(dut):
    seed = int(os.environ.get("SEED", "1"))
    dut._log.info(f"random seed {seed} (rerun with SEED={seed})")
    return random.Random(seed)


def idle(dut):
    for s in ("s_awvalid_i", "s_wvalid_i", "s_bready_i", "s_arvalid_i",
              "s_rready_i", "head_adv_i", "done_irq_i", "err_i"):
        getattr(dut, s).value = 0
    dut.s_awaddr_i.value = 0
    dut.s_araddr_i.value = 0
    dut.s_wdata_i.value = 0
    dut.s_wstrb_i.value = 0
    dut.err_code_i.value = 0


async def start(dut):
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    idle(dut)
    dut.rst_i.value = 1
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0


# Everything is driven and sampled at the falling edge: a handshake happens
# at the next rising edge when VALID and READY are both high here. READY is
# a flop's output, so setting VALID cannot change it in the same cycle.
# A write to a cocotb handle is not visible on read-back until the simulator
# advances, so handshakes are judged from the values the driver intends.

async def axi_write(dut, off, val, strb=0xF, aw_delay=0, w_delay=0,
                    b_delay=0, on_commit=None):
    """One write; returns BRESP. on_commit runs in the cycle the register
    file takes the write (both halves held, no response pending)."""
    aw_done = w_done = False
    cyc = 0
    while not (aw_done and w_done):
        awvalid = not aw_done and cyc >= aw_delay
        wvalid = not w_done and cyc >= w_delay
        dut.s_awvalid_i.value = int(awvalid)
        dut.s_awaddr_i.value = off
        dut.s_wvalid_i.value = int(wvalid)
        dut.s_wdata_i.value = val & MASK32
        dut.s_wstrb_i.value = strb
        aw_hs = awvalid and dut.s_awready_o.value
        w_hs = wvalid and dut.s_wready_o.value
        await FallingEdge(dut.clk_i)
        aw_done |= bool(aw_hs)
        w_done |= bool(w_hs)
        cyc += 1
    dut.s_awvalid_i.value = 0
    dut.s_wvalid_i.value = 0
    # both halves are held now; the write commits at the next rising edge
    assert not dut.s_bvalid_o.value, "BVALID before the write was taken"
    if on_commit:
        await on_commit()
    cyc = 0
    while True:
        bready = cyc >= b_delay
        dut.s_bready_i.value = int(bready)
        if dut.s_bvalid_o.value and bready:
            resp = int(dut.s_bresp_o.value)
            await FallingEdge(dut.clk_i)
            dut.s_bready_i.value = 0
            return resp
        await FallingEdge(dut.clk_i)
        cyc += 1
        assert cyc < 20, "no write response"


async def axi_read(dut, off, ar_delay=0, r_delay=0):
    """One read; returns (RDATA, RRESP)."""
    cyc = 0
    while True:
        arvalid = cyc >= ar_delay
        dut.s_arvalid_i.value = int(arvalid)
        dut.s_araddr_i.value = off
        hs = arvalid and dut.s_arready_o.value
        await FallingEdge(dut.clk_i)
        cyc += 1
        if hs:
            break
    dut.s_arvalid_i.value = 0
    cyc = 0
    while True:
        rready = cyc >= r_delay
        dut.s_rready_i.value = int(rready)
        if dut.s_rvalid_o.value and rready:
            data, resp = int(dut.s_rdata_o.value), int(dut.s_rresp_o.value)
            await FallingEdge(dut.clk_i)
            dut.s_rready_i.value = 0
            return data, resp
        await FallingEdge(dut.clk_i)
        cyc += 1
        assert cyc < 20, "no read response"


async def engine(dut, adv=False, irq=False, err=0):
    """Drive the engine's report for one cycle (call at a falling edge)."""
    dut.head_adv_i.value = int(adv)
    dut.done_irq_i.value = int(irq)
    dut.err_i.value = int(bool(err))
    dut.err_code_i.value = err
    await FallingEdge(dut.clk_i)
    dut.head_adv_i.value = 0
    dut.done_irq_i.value = 0
    dut.err_i.value = 0
    dut.err_code_i.value = 0


def check_outputs(dut, m, where):
    assert int(dut.irq_o.value) == m.irq_level, f"{where}: irq_o"
    assert int(dut.run_o.value) == bool(m.has_work()), f"{where}: run_o"
    assert int(dut.head_o.value) == m.head, f"{where}: head_o"
    assert int(dut.ring_size_o.value) == m.ring_size, f"{where}: ring_size_o"
    assert int(dut.ring_base_lo_o.value) == m.ring_base_lo, f"{where}: ring_base_lo_o"
    assert int(dut.ring_base_hi_o.value) == m.ring_base_hi, f"{where}: ring_base_hi_o"


async def check_all_regs(dut, m, where):
    for off in REGS + UNMAPPED:
        data, resp = await axi_read(dut, off)
        assert resp == OKAY, f"{where}: RRESP at 0x{off:03x}"
        assert data == m.reg_read(off), (
            f"{where}: 0x{off:03x} reads 0x{data:08x}, model 0x{m.reg_read(off):08x}")
    check_outputs(dut, m, where)


def mem():
    return dmaeng_model.Memory()


@cocotb.test()
async def test_reset_values(dut):
    """After reset every register reads as the model's, ID and MAX_XFER too."""
    await start(dut)
    m = Mirror(mem())
    assert m.reg_read(C["REG_ID"]) == C["ID_MAGIC"]
    await check_all_regs(dut, m, "after reset")


@cocotb.test()
async def test_ring_setup_and_doorbell(dut):
    """The driver's sequence: program the ring, enable, ring the doorbell; the
    engine (played here) walks HEAD to TAIL across the wrap, then stops."""
    await start(dut)
    m = Mirror(mem())
    size = 8
    for off, val in ((C["REG_RING_BASE_HI"], 0), (C["REG_RING_BASE_LO"], 0x2000),
                     (C["REG_RING_SIZE"], size), (C["REG_IRQ_MASK"], 3),
                     (C["REG_CTRL"], C["CTRL_ENABLE"]), (C["REG_TAIL"], 6)):
        assert await axi_write(dut, off, val) == OKAY
        m.reg_write(off, val)
    await check_all_regs(dut, m, "ring programmed")
    for _ in range(6):
        assert dut.run_o.value, "run_o low with HEAD != TAIL"
        await engine(dut, adv=True)
        m.engine(adv=True)
    check_outputs(dut, m, "caught up")
    assert not dut.run_o.value
    # past the wrap: TAIL = 3 means slots 6, 7, 0, 1, 2
    assert await axi_write(dut, C["REG_TAIL"], 3) == OKAY
    m.reg_write(C["REG_TAIL"], 3)
    n = 0
    while dut.run_o.value and n < size:
        await engine(dut, adv=True, irq=(n == 4))
        m.engine(adv=True, irq=(n == 4))
        n += 1
    assert n == 5 and m.head == 3
    await check_all_regs(dut, m, "after the wrap")
    assert dut.irq_o.value, "completion with IRQ_MASK set raises irq_o"


@cocotb.test()
async def test_error_stops_until_reset(dut):
    """An error sets STATUS.ERROR, ERR_CODE and IRQ_STATUS.ERROR and drops
    run_o with work left; only CTRL.RESET clears it, and it clears all."""
    await start(dut)
    m = Mirror(mem())
    for off, val in ((C["REG_RING_SIZE"], 4), (C["REG_IRQ_MASK"], 2),
                     (C["REG_CTRL"], C["CTRL_ENABLE"]), (C["REG_TAIL"], 3)):
        await axi_write(dut, off, val)
        m.reg_write(off, val)
    # an owned descriptor fails: HEAD advances and the error lands together
    await engine(dut, adv=True, err=C["ERR_BAD_LEN"])
    m.engine(adv=True, err=C["ERR_BAD_LEN"])
    await check_all_regs(dut, m, "after the error")
    assert not dut.run_o.value and dut.irq_o.value
    # clearing IRQ_STATUS drops the interrupt but not the stop
    await axi_write(dut, C["REG_IRQ_STATUS"], C["IRQ_STATUS_ERROR"])
    m.reg_write(C["REG_IRQ_STATUS"], C["IRQ_STATUS_ERROR"])
    await check_all_regs(dut, m, "IRQ_STATUS cleared")
    assert not dut.run_o.value, "W1C restarted the engine"
    # re-enabling does not restart it either
    await axi_write(dut, C["REG_CTRL"], C["CTRL_ENABLE"])
    m.reg_write(C["REG_CTRL"], C["CTRL_ENABLE"])
    assert not dut.run_o.value
    # RESET with ENABLE in the same write: everything clears, ENABLE ignored;
    # soft_rst_o is high in the commit cycle only
    seen = []
    resp = await axi_write(dut, C["REG_CTRL"], C["CTRL_RESET"] | C["CTRL_ENABLE"],
                           on_commit=lambda: _sample(dut, seen))
    m.reg_write(C["REG_CTRL"], C["CTRL_RESET"] | C["CTRL_ENABLE"])
    assert resp == OKAY
    assert seen == [1], "soft_rst_o not high in the reset write's cycle"
    assert not dut.soft_rst_o.value, "soft_rst_o longer than one cycle"
    await check_all_regs(dut, m, "after CTRL.RESET")


async def _sample(dut, out):
    out.append(int(dut.soft_rst_o.value))


@cocotb.test()
async def test_same_cycle_reports(dut):
    """An engine report in the cycle a register write commits: a completion
    is not lost to a W1C of IRQ_STATUS, and CTRL.RESET wins over a report."""
    await start(dut)
    m = Mirror(mem())
    for off, val in ((C["REG_RING_SIZE"], 4), (C["REG_IRQ_MASK"], 1),
                     (C["REG_CTRL"], C["CTRL_ENABLE"]), (C["REG_TAIL"], 3)):
        await axi_write(dut, off, val)
        m.reg_write(off, val)
    await engine(dut, adv=True, irq=True)
    m.engine(adv=True, irq=True)
    assert dut.irq_o.value
    # W1C of COMPLETION while the next completion lands
    await axi_write(dut, C["REG_IRQ_STATUS"], C["IRQ_STATUS_COMPLETION"],
                    on_commit=lambda: engine(dut, adv=True, irq=True))
    m.reg_write(C["REG_IRQ_STATUS"], C["IRQ_STATUS_COMPLETION"])
    m.engine(adv=True, irq=True)
    await check_all_regs(dut, m, "W1C with a completion")
    assert dut.irq_o.value, "a completion was lost to the W1C"
    # CTRL.RESET while an error lands: nothing of the error survives
    await axi_write(dut, C["REG_CTRL"], C["CTRL_RESET"],
                    on_commit=lambda: engine(dut, adv=True, err=C["ERR_DMA_FAIL"]))
    m.reg_write(C["REG_CTRL"], C["CTRL_RESET"])
    await check_all_regs(dut, m, "reset with an error")


@cocotb.test()
async def test_partial_strobes_rejected(dut):
    """Any write without all four strobes: SLVERR and no register changes."""
    await start(dut)
    m = Mirror(mem())
    for strb in range(0xF):
        for off in WRITABLE:
            val = C["CTRL_ENABLE"] if off == C["REG_CTRL"] else MASK32
            assert await axi_write(dut, off, val, strb=strb) == SLVERR, (
                f"0x{off:03x} strobes {strb:04b}")
    await check_all_regs(dut, m, "after partial writes")


@cocotb.test()
async def test_random_against_model(dut):
    """Random writes, reads and engine reports, random AXI timing, with
    reports sometimes in a write's commit cycle; every read, irq_o and run_o
    against the model."""
    await start(dut)
    rng = rng_for(dut)
    m = Mirror(mem())
    ops = int(os.environ.get("DMAENG_REGS_OPS", "6000"))
    counts = dict(write=0, slverr=0, read=0, adv=0, irq=0, err=0, reset=0,
                  same_cycle=0, irq_high=0)

    def value_for(off):
        r = rng.random()
        if off == C["REG_CTRL"]:
            return C["CTRL_RESET"] if r < 0.2 else rng.choice(
                [0, C["CTRL_ENABLE"], C["CTRL_ENABLE"], rng.getrandbits(32) & ~C["CTRL_RESET"]])
        if off == C["REG_RING_SIZE"]:
            return rng.choice([2, 4, 8, 16, 4096]) if r < 0.9 else rng.getrandbits(32)
        if off == C["REG_TAIL"]:
            return rng.randrange(max(m.ring_size, 2)) if r < 0.9 else rng.getrandbits(32)
        if off in (C["REG_IRQ_STATUS"], C["REG_IRQ_MASK"]):
            return rng.randrange(4) if r < 0.8 else rng.getrandbits(32)
        return rng.getrandbits(32)

    def report():
        """A legal engine report for this cycle, or None (needs work)."""
        if not m.has_work():
            return None
        if rng.random() < 0.03:
            return dict(adv=rng.random() < 0.5, irq=False, err=rng.choice(ERR_CODES))
        irq = rng.random() < 0.4
        return dict(adv=True, irq=irq, err=0)

    for i in range(ops):
        where = f"op {i}"
        rep = None
        kind = rng.random()
        if kind < 0.45:
            off = rng.choice(WRITABLE + REGS + UNMAPPED)
            val = value_for(off)
            strb = 0xF if rng.random() < 0.92 else rng.randrange(0xF)
            rep = None
            # a report in the commit cycle; RING_SIZE changes the wrap mask
            # mid-advance, which the driver never does, so not with it
            if rng.random() < 0.3 and off != C["REG_RING_SIZE"]:
                rep = report()
            resp = await axi_write(
                dut, off, val, strb,
                aw_delay=rng.choice([0, 0, 1, 3]), w_delay=rng.choice([0, 0, 2, 4]),
                b_delay=rng.choice([0, 0, 1, 5]),
                on_commit=(lambda r=rep: engine(dut, **r)) if rep else None)
            counts["write"] += 1
            if strb != 0xF:
                assert resp == SLVERR, f"{where}: partial write answered {resp}"
                counts["slverr"] += 1
            else:
                assert resp == OKAY, f"{where}: write answered {resp}"
                m.reg_write(off, val)
                if off == C["REG_CTRL"] and val & C["CTRL_RESET"]:
                    counts["reset"] += 1
                    rep = None           # CTRL.RESET wins over a report
            if rep:
                m.engine(**rep)
                counts["same_cycle"] += 1
        elif kind < 0.85:
            off = rng.choice(REGS + REGS + UNMAPPED)
            data, resp = await axi_read(dut, off, ar_delay=rng.choice([0, 0, 2]),
                                        r_delay=rng.choice([0, 0, 1, 4]))
            assert resp == OKAY
            assert data == m.reg_read(off), (
                f"{where}: 0x{off:03x} reads 0x{data:08x}, model 0x{m.reg_read(off):08x}")
            counts["read"] += 1
        else:
            rep = report()
            if rep is None:
                continue
            await engine(dut, **rep)
            m.engine(**rep)
        if rep:
            counts["adv"] += rep["adv"]
            counts["irq"] += rep["irq"]
            counts["err"] += bool(rep["err"])
        check_outputs(dut, m, where)
        counts["irq_high"] += m.irq_level
    await check_all_regs(dut, m, "end")
    dut._log.info(f"{ops} ops: {counts}")
    # the run is only worth something if it reached these
    for k in ("slverr", "adv", "irq", "err", "reset", "same_cycle", "irq_high"):
        assert counts[k] > 0, f"random run never reached {k}"
