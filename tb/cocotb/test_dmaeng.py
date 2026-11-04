"""The DMA engine (rtl/bus/dmaeng.sv) against the golden model.

sw/model/dmaeng_model.py, DMA-Engine's QEMU device ported before any RTL, is
the reference. Every register access goes to both the RTL (over AXI4-Lite)
and the model; the RTL's memory is served by an AXI4 slave (axi_mem.py) that
stalls at random and checks the master's protocol. The model completes a
doorbell inside the write; the RTL takes cycles, so after each write the
test waits for the engine to go idle, as a driver polling STATUS.BUSY would,
then requires the same registers, the same memory byte for byte, the same
irq_o and the same number of interrupt edges (the model's MSIs).

What matters and why:
  - DMA-Engine's golden trace (traces/dmaeng-sync.trace, recorded from the
    QEMU device under its Linux driver) replays on the RTL: the driver
    built there sees the same device here (buildplan Phase G);
  - copies at every source/destination byte alignment and lengths around
    the bus width, the 64-byte chunk and the 4 KiB page come out exact: the
    engine realigns bytes and splits bursts, which the trace (all aligned)
    never exercises;
  - every error the spec names stops the engine with the model's code, the
    model's HEAD and the model's ring contents (which descriptor carries
    the error is part of the contract, DMA-Engine 5.4);
  - bus errors (an unmapped or read-only page) fail as DMA_FAIL at each of
    fetch, copy, status write;
  - CTRL.RESET mid-copy finishes the burst in flight, then writes nothing:
    no status, OWN left set, and the engine works again after reprogramming.

Known divergences, not tested: a bus error part-way through a copy leaves
the destination partly written (the model writes all or nothing), and an
overlapping copy is not a memmove beyond one 64-byte chunk.
"""

import os
from pathlib import Path
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from axil import OKAY, axi_read, axi_write
from axi_mem import PAGE, AxiMem, init_ports

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "model"))
import dmaeng_model  # noqa: E402
from dmaeng_model import C  # noqa: E402

CLK_PERIOD_NS = 10
REGS = sorted(v for k, v in C.items() if k.startswith("REG_"))
RING = 0x1000
SRC = 0x20000           # source buffers, filled with random bytes
DST = 0x40000           # destination buffers
MAX = C["MAX_XFER_DEFAULT"]
IDLE_TIMEOUT = 400_000  # cycles; a 64 KiB copy with stalls is ~60k


class FaultMemory(dmaeng_model.Memory):
    """The model's memory with the same failing pages as the AXI slave."""

    def __init__(self, holes, read_only):
        super().__init__()
        self.holes, self.read_only = holes, read_only

    def pages(self, addr, n):
        return range(addr // PAGE, (addr + n - 1) // PAGE + 1)

    def read(self, addr, n):
        if any(p in self.holes for p in self.pages(addr, n)):
            return None
        return super().read(addr, n)

    def write(self, addr, data):
        if any(p in self.holes or p in self.read_only
               for p in self.pages(addr, len(data))):
            return False
        return super().write(addr, data)


class Bench:
    def __init__(self, dut, rng, stall):
        self.dut = dut
        self.rng = rng
        holes, ro = set(), set()
        self.model_mem = FaultMemory(holes, ro)
        self.rtl_mem = dmaeng_model.Memory()
        self.model = dmaeng_model.Dmaeng(self.model_mem)
        self.axi = AxiMem(dut, self.rtl_mem, rng, stall=stall)
        self.axi.holes, self.axi.read_only = holes, ro
        self.holes, self.read_only = holes, ro
        self.irq_edges = 0
        self.msis = 0
        self.descs = 0

    async def start(self):
        d = self.dut
        cocotb.start_soon(Clock(d.clk_i, CLK_PERIOD_NS, unit="ns").start())
        for s in ("s_awvalid_i", "s_wvalid_i", "s_bready_i", "s_arvalid_i",
                  "s_rready_i"):
            getattr(d, s).value = 0
        d.s_awaddr_i.value = 0
        d.s_araddr_i.value = 0
        d.s_wdata_i.value = 0
        d.s_wstrb_i.value = 0
        init_ports(d)
        d.rst_i.value = 1
        await RisingEdge(d.clk_i)
        await FallingEdge(d.clk_i)
        d.rst_i.value = 0
        cocotb.start_soon(self.axi.run())
        cocotb.start_soon(self.watch_irq())

    async def watch_irq(self):
        """Counts rises of irq_o, read once each edge has settled, so the
        count is current by the falling edge every check runs at."""
        prev = 0
        while True:
            await RisingEdge(self.dut.clk_i)
            await ReadOnly()
            cur = int(self.dut.irq_o.value)
            self.irq_edges += cur and not prev
            prev = cur

    # --- memory -----------------------------------------------------------
    def poke(self, addr, data):
        for m in (self.rtl_mem, self.model_mem):
            for i, b in enumerate(data):
                m.bytes[addr + i] = b

    def fill(self, addr, n):
        self.poke(addr, bytes(self.rng.getrandbits(8) for _ in range(n)))

    def put_desc(self, slot, src, dst, n, flags=None, rsvd=0, src_hi=0,
                 dst_hi=0, ring=RING):
        flags = C["DESC_OWN"] | C["DESC_IRQ"] if flags is None else flags
        desc = bytearray(C["DESC_SIZE"])
        for off, val, w in (("SRC", src_hi << 32 | src, 8),
                            ("DST", dst_hi << 32 | dst, 8), ("LEN", n, 4),
                            ("FLAGS", flags, 4), ("STATUS", 0xDEADBEEF, 4),
                            ("RSVD", rsvd, 4)):
            o = C["DESC_OFF_" + off]
            desc[o:o + w] = val.to_bytes(w, "little")
        self.poke(ring + slot * C["DESC_SIZE"], bytes(desc))

    # --- registers ------------------------------------------------------------
    async def wr(self, name, val, wait=True):
        off = C["REG_" + name]
        self.model.events = []
        self.model.reg_write(off, val)
        self.msis += self.model.events.count("MSI")
        self.descs += sum(e.startswith("DESC ") for e in self.model.events)
        assert await axi_write(self.dut, off, val) == OKAY
        if wait:
            await self.wait_idle()

    async def rd(self, name):
        data, _ = await axi_read(self.dut, C["REG_" + name])
        return data

    async def wait_idle(self):
        """The engine is done when it has no work (STATUS.BUSY low, what a
        driver polls) and nothing of its own on the bus."""
        d = self.dut
        for _ in range(IDLE_TIMEOUT):
            if int(d.u_regs.run_o.value) == 0 and \
                    int(d.u_desc.state_q.value) == 0 and \
                    int(d.u_axi.state_q.value) == 0 and self.axi.idle():
                return
            await FallingEdge(d.clk_i)
        raise AssertionError("engine never went idle")

    async def program(self, size=8, mask=3, base=RING):
        for name, val in (("RING_BASE_HI", 0), ("RING_BASE_LO", base),
                          ("RING_SIZE", size), ("IRQ_MASK", mask),
                          ("CTRL", C["CTRL_ENABLE"])):
            await self.wr(name, val)

    async def reset_engine(self):
        await self.wr("CTRL", C["CTRL_RESET"])

    # --- comparison --------------------------------------------------------------
    async def check(self, where):
        assert not self.axi.errors, f"{where}: AXI protocol: {self.axi.errors[:5]}"
        for off in REGS:
            data, _ = await axi_read(self.dut, off)
            want = self.model.reg_read(off)
            assert data == want, (f"{where}: register 0x{off:02x} reads 0x{data:08x}, "
                                  f"model 0x{want:08x}")
        a, b = self.rtl_mem.bytes, self.model_mem.bytes
        bad = [k for k in set(a) | set(b) if a.get(k, 0) != b.get(k, 0)]
        assert not bad, (f"{where}: {len(bad)} bytes differ, first at 0x{min(bad):x}: "
                         f"RTL 0x{a.get(min(bad), 0):02x} model 0x{b.get(min(bad), 0):02x}")
        assert int(self.dut.irq_o.value) == self.model.irq_level, f"{where}: irq_o"
        assert self.irq_edges == self.msis, (
            f"{where}: {self.irq_edges} interrupt edges, model sent {self.msis} MSIs")


def rng_for(dut):
    seed = int(os.environ.get("SEED", "1"))
    dut._log.info(f"random seed {seed} (rerun with SEED={seed})")
    return random.Random(seed)


async def bench(dut, stall=0.3):
    rng = rng_for(dut)
    b = Bench(dut, rng, stall)
    await b.start()
    return b


async def run_batch(b, descs, size, irq_clear=True):
    """Put descriptors at HEAD onward, ring the doorbell once, compare."""
    head = b.model.head
    for i, args in enumerate(descs):
        b.put_desc((head + i) % size, *args[:3], **args[3] if len(args) > 3 else {})
    await b.wr("TAIL", (head + len(descs)) % size)
    await b.check(f"batch at head {head}")
    if irq_clear:
        await b.wr("IRQ_STATUS", 3)


@cocotb.test()
async def test_single_copy(dut):
    """One aligned 64-byte copy: data moved, status 0, OWN cleared, HEAD
    advanced, completion interrupt."""
    b = await bench(dut, stall=0.0)
    b.fill(SRC, 64)
    await b.program()
    await run_batch(b, [(SRC, DST, 64)], 8, irq_clear=False)
    assert b.rtl_mem.read(DST, 64) == b.rtl_mem.read(SRC, 64)
    assert await b.rd("HEAD") == 1 and dut.irq_o.value
    # rule 5: the copy, then status, then flags with OWN cleared, in that
    # order on the bus (each waits for the previous write's response)
    assert b.axi.aw_log == [DST, RING + C["DESC_OFF_STATUS"], RING + C["DESC_OFF_FLAGS"]], \
        [hex(a) for a in b.axi.aw_log]


@cocotb.test()
async def test_alignments(dut):
    """Every source and destination byte offset, lengths around the bus
    width and the 64-byte chunk: the realigning datapath and its strobes."""
    b = await bench(dut)
    b.fill(SRC, 4096)
    b.fill(DST, 4096)            # so a stray strobe shows as a changed byte
    size = 64
    await b.program(size=size)
    lengths = [1, 2, 3, 4, 5, 7, 8, 9, 31, 60, 61, 63, 64, 65, 67, 127, 128, 200]
    jobs, dst = [], DST
    for sa in range(4):
        for da in range(4):
            for n in lengths:
                jobs.append((SRC + 0x100 + sa, dst + da, n))
                dst += (n + 16) & ~3
    for i in range(0, len(jobs), size - 1):
        await run_batch(b, jobs[i:i + size - 1], size)
    dut._log.info(f"{len(jobs)} copies, AXI {b.axi.stats}")


@cocotb.test()
async def test_page_and_length_limits(dut):
    """Copies across 4 KiB pages on either side, MAX_XFER exactly, and
    MAX_XFER + 1 (BAD_LEN)."""
    b = await bench(dut)
    b.fill(SRC, 3 * PAGE)
    await b.program(size=16)
    await run_batch(b, [
        (SRC + PAGE - 3, DST + 0x100, 10),          # src crosses
        (SRC + 0x10, DST + PAGE - 1, 10),           # dst crosses
        (SRC + PAGE - 7, DST + 2 * PAGE - 5, 300),  # both, different offsets
        (SRC + 1, DST + 0x3000 + 2, PAGE),          # a page, misaligned
        (SRC, DST + 0x6000, 2 * PAGE + 1),
    ], 16)
    b.fill(0x100000, MAX)
    await run_batch(b, [(0x100000, 0x200001, MAX)], 16)
    await run_batch(b, [(0x100000, 0x300000, MAX + 1)], 16)   # BAD_LEN, stops
    assert await b.rd("ERR_CODE") == C["ERR_BAD_LEN"]


@cocotb.test()
async def test_errors(dut):
    """Every error the spec names, each from a fresh reset: the model's code,
    HEAD, ring contents and interrupt."""
    b = await bench(dut)
    b.fill(SRC, 256)
    owned = C["DESC_OWN"] | C["DESC_IRQ"]
    cases = [
        # (name, ring setup, descriptor kwargs or None for slot 0 untouched)
        ("misaligned ring", dict(base=RING + 0x20), {}),
        ("RING_SIZE 0", dict(size=0), {}),
        ("RING_SIZE 3", dict(size=3), {}),
        ("RING_SIZE 8192", dict(size=8192), {}),
        ("OWN clear", {}, dict(flags=C["DESC_IRQ"])),
        ("rsvd set", {}, dict(rsvd=1)),
        ("len 0", {}, dict(n=0)),
        ("len MAX+1", {}, dict(n=MAX + 1)),
        ("src above 4 GiB", {}, dict(src_hi=1)),
        ("dst above 4 GiB", {}, dict(dst_hi=1)),
        ("src wraps 2^32", {}, dict(src=0xFFFF_FFF0, n=32)),
        ("dst ends at 2^32", {}, dict(dst=0xFFFF_FFE0, n=32)),   # fine
        ("rsvd beats len", {}, dict(rsvd=5, n=0)),
    ]
    for name, ring, kw in cases:
        await b.reset_engine()
        size = ring.get("size", 8)
        await b.program(size=size, base=ring.get("base", RING))
        args = dict(src=SRC, dst=DST, n=16, flags=owned)
        args.update(kw)
        b.put_desc(0, args.pop("src"), args.pop("dst"), args.pop("n"),
                   ring=ring.get("base", RING), **args)
        await b.wr("TAIL", 1)
        await b.check(name)
        dut._log.info(f"{name}: ERR_CODE {b.model.err_code}, HEAD {b.model.head}")
    # RING_BASE_HI set: the fetch reaches past 2^32
    await b.reset_engine()
    await b.program()
    b.put_desc(0, SRC, DST, 16)
    await b.wr("RING_BASE_HI", 1)
    await b.wr("TAIL", 1)
    await b.check("RING_BASE_HI set")
    assert b.model.err_code == C["ERR_DMA_FAIL"]


@cocotb.test()
async def test_bus_errors(dut):
    """SLVERR at each bus access: the fetch (ring in an unmapped page), the
    copy's read, its write, and the status write (ring read-only)."""
    b = await bench(dut)
    b.fill(SRC, 256)
    b.fill(DST, 256)             # a failed read written out would show
    hole = 0x80000
    for name, setup, desc in (
        ("fetch", lambda: b.holes.add(RING // PAGE), (SRC, DST, 16)),
        ("copy read", lambda: b.holes.add(hole // PAGE), (hole + 4, DST, 100)),
        ("copy write", lambda: b.holes.add(hole // PAGE), (SRC, hole + 1, 100)),
        ("status write", lambda: b.read_only.add(RING // PAGE), (SRC, DST, 16)),
    ):
        b.holes.clear()
        b.read_only.clear()
        await b.reset_engine()
        await b.program()
        b.put_desc(0, *desc)
        setup()
        await b.wr("TAIL", 1)
        await b.check(name)
        assert b.model.err_code == C["ERR_DMA_FAIL"], name
    b.holes.clear()
    b.read_only.clear()


@cocotb.test()
async def test_reset_mid_copy(dut):
    """CTRL.RESET in the middle of a 64 KiB copy: the burst in flight
    finishes, then nothing more is written (no status, OWN still set), every
    register is back to reset, and the engine runs again once reprogrammed."""
    b = await bench(dut, stall=0.2)
    b.fill(SRC, MAX)
    await b.program()
    b.put_desc(0, SRC, DST, MAX)
    await axi_write(dut, C["REG_TAIL"], 1)
    while b.axi.stats["bytes_written"] < 8000:
        await FallingEdge(dut.clk_i)
    at_reset = {}

    async def mark():
        at_reset["bytes"] = b.axi.stats["bytes_written"]
    await axi_write(dut, C["REG_CTRL"], C["CTRL_RESET"], on_commit=mark)
    b.model.reset()
    await b.wait_idle()
    after = b.axi.stats["bytes_written"] - at_reset["bytes"]
    dut._log.info(f"reset after {at_reset['bytes']} bytes; {after} more drained")
    assert after <= 64, f"{after} bytes written after CTRL.RESET: more than one burst"
    desc = RING
    flags = b.rtl_mem.read32(desc + C["DESC_OFF_FLAGS"])
    status = b.rtl_mem.read32(desc + C["DESC_OFF_STATUS"])
    assert flags & C["DESC_OWN"] and status == 0xDEADBEEF, "descriptor written back after reset"
    for off in REGS:
        data, _ = await axi_read(dut, off)
        assert data == b.model.reg_read(off), f"0x{off:02x} not reset"
    # copy what was written so the memories agree, then a normal run
    for k, v in b.rtl_mem.bytes.items():
        b.model_mem.bytes[k] = v
    await b.program()
    b.put_desc(0, SRC + 3, DST + 0x20000, 500)
    await b.wr("TAIL", 1)
    await b.check("after reset mid-copy")


@cocotb.test()
async def test_trace_replay(dut):
    """DMA-Engine's golden trace, every access in order, against the RTL:
    each read returns the trace's value, each descriptor's destination
    holds the trace's DST_AFTER, its status is the trace's DONE and OWN is
    clear, and the interrupt rises as often as the trace sent MSIs."""
    b = await bench(dut)
    steps = dmaeng_model.parse_trace()
    reads = copies = 0
    for n, (access, records) in enumerate(steps):
        kind, off, val = access.split()
        off, val = int(off, 16), int(val, 16)
        dmaeng_model.stage(b.rtl_mem, records)
        edges = b.irq_edges
        if kind == "RD":
            data, _ = await axi_read(dut, off)
            assert data == val, f"step {n}: {access}: RTL read 0x{data:08x}"
            reads += 1
        else:
            assert await axi_write(dut, off, val) == OKAY
            await b.wait_idle()
        assert not b.axi.errors, f"step {n}: AXI protocol: {b.axi.errors[:3]}"
        assert b.irq_edges - edges == records.count("MSI"), (
            f"step {n}: {access}: {b.irq_edges - edges} interrupt edges, "
            f"trace {records.count('MSI')} MSIs")
        desc = None
        for rec in records:
            if rec.startswith("DESC "):
                desc = dict(kv.split("=") for kv in rec.split()[1:])
            elif rec.startswith("DST_AFTER ") and desc:
                data = bytes.fromhex(rec.split()[1])
                got = b.rtl_mem.read(int(desc["dst"], 16), len(data))
                assert got == data, f"step {n}: destination of {desc} differs"
                copies += 1
            elif rec.startswith("DONE ") and desc:
                addr = int(desc["addr"], 16)
                status = int(rec.split("=")[1], 16)
                assert b.rtl_mem.read32(addr + C["DESC_OFF_STATUS"]) == status, (
                    f"step {n}: status of descriptor at 0x{addr:x}")
                assert not b.rtl_mem.read32(addr + C["DESC_OFF_FLAGS"]) & C["DESC_OWN"], (
                    f"step {n}: OWN still set at 0x{addr:x}")
    dut._log.info(f"trace: {len(steps)} accesses, {reads} reads checked, "
                  f"{copies} copies checked, {b.irq_edges} interrupts; AXI {b.axi.stats}")
    assert reads > 0 and copies > 0


@cocotb.test()
async def test_random_against_model(dut):
    """Random rings, batches of descriptors at random alignments and lengths,
    some failing, random IRQ_STATUS clears; RTL against the model after each
    doorbell, and a reset after each error."""
    b = await bench(dut)
    rng = b.rng
    b.fill(SRC, 0x8000)
    batches = int(os.environ.get("DMAENG_BATCHES", "60"))
    errors = copies = 0
    size = None
    for i in range(batches):
        if size is None or rng.random() < 0.1:
            size = rng.choice([2, 4, 8, 16, 64])
            await b.reset_engine()
            await b.program(size=size, mask=rng.randrange(4))
        descs = []
        for _ in range(rng.randrange(1, size)):
            r = rng.random()
            n = (rng.randrange(1, 200) if r < 0.7 else
                 rng.randrange(200, 5000) if r < 0.92 else
                 rng.choice([4095, 4096, 4097, 64, 65]))
            src = SRC + rng.randrange(0x8000 - n)
            dst = DST + rng.randrange(0x10000)
            flags = C["DESC_OWN"] | (C["DESC_IRQ"] if rng.random() < 0.5 else 0) \
                | (C["DESC_LAST"] if rng.random() < 0.3 else 0)
            kw = dict(flags=flags)
            e = rng.random()
            if e < 0.02:
                kw["rsvd"] = 1
            elif e < 0.04:
                n = rng.choice([0, MAX + 1])
            elif e < 0.05:
                kw["flags"] = 0
            descs.append((src, dst, n, kw))
        await run_batch(b, descs, size, irq_clear=rng.random() < 0.5)
        copies += len(descs)
        if b.model.status & C["STATUS_ERROR"]:
            errors += 1
            size = None
    dut._log.info(f"{batches} batches, {copies} descriptors, {errors} errors, "
                  f"{b.irq_edges} interrupts; AXI {b.axi.stats}")
    assert errors > 0 and b.irq_edges > 0
