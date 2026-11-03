#!/usr/bin/env python3
"""Golden model of the descriptor-ring DMA engine (Phase G, buildplan 6.3).

Written before the RTL, as a port of DMA-Engine's QEMU device model
(sw/dma-engine/qemu-device/dmaeng.c, synchronous mode): the register map,
descriptor layout and limits are read from that repo's generated header
(include/dmaeng_regs.h, from spec/dmaeng.yaml), so no offset is typed here.
DMA-Engine: https://github.com/RodeanAzari/DMA-Engine

Behaviour (DMA-Engine CLAUDE.md 5.4-5.6, as dmaeng.c implements it):
  - A write to TAIL (or CTRL enabling the engine) is the doorbell: while
    enabled, not stopped on an error and HEAD != TAIL, the descriptor at HEAD
    is processed.
  - Errors before a descriptor is owned (misaligned ring, bad RING_SIZE,
    descriptor fetch fails, OWN clear at HEAD) touch nothing in the ring and
    leave HEAD. An owned descriptor that fails (rsvd non-zero, bad length,
    copy fails) gets its status written and OWN cleared, HEAD advances, then
    the engine stops. Either way: ERR_CODE, STATUS.ERROR, IRQ_STATUS.ERROR,
    and nothing more until CTRL.RESET, which clears every register.
  - Status is written before OWN clears (rule 5).
  - The interrupt is the level IRQ_STATUS & IRQ_MASK; an MSI is sent on each
    rising edge of it.

On this SoC addresses are 32 bits: any access reaching past 2^32 fails
(DMA_FAIL), which is also how the trace's out-of-range addresses fail.

`python3 sw/model/dmaeng_model.py` replays DMA-Engine's golden trace
(traces/dmaeng-sync.trace, recorded from the QEMU device under a Linux
driver) through the model and requires every record to match, then checks
that planted model bugs each make the replay fail.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DMAENG = ROOT / "sw" / "dma-engine"
HEADER = DMAENG / "include" / "dmaeng_regs.h"
TRACE = DMAENG / "traces" / "dmaeng-sync.trace"


def load_header(path=HEADER):
    """Every `#define DMAENG_<NAME> <int>` in the generated header, as C."""
    consts = {}
    pat = re.compile(r"#define DMAENG_(\w+)\s+\(?\s*(0x[0-9A-Fa-f]+|\d+)U?"
                     r"(?:\s*<<\s*(\d+)\))?")
    for line in path.read_text().splitlines():
        m = pat.match(line)
        if m:
            val = int(m.group(2), 0)
            consts[m.group(1)] = val << int(m.group(3)) if m.group(3) else val
    return consts


C = load_header()
ADDR_LIMIT = 1 << 32            # this SoC's address space


def is_pow2(x):
    return x > 0 and x & (x - 1) == 0


class Memory:
    """Sparse byte memory. An access reaching past ADDR_LIMIT fails."""

    def __init__(self):
        self.bytes = {}

    def ok(self, addr, n):
        return addr + n <= ADDR_LIMIT

    def read(self, addr, n):
        if not self.ok(addr, n):
            return None
        return bytes(self.bytes.get(addr + i, 0) for i in range(n))

    def write(self, addr, data):
        if not self.ok(addr, len(data)):
            return False
        for i, b in enumerate(data):
            self.bytes[addr + i] = b
        return True

    def read32(self, addr):
        return int.from_bytes(self.read(addr, 4), "little")

    def read64(self, addr):
        return int.from_bytes(self.read(addr, 8), "little")


class Dmaeng:
    """dmaeng.c, synchronous mode. `events` collects trace records (strings
    in the trace's format) for everything the device does."""

    def __init__(self, mem):
        self.mem = mem
        self.events = []
        self.reset()

    def reset(self):
        self.ctrl = self.status = 0
        self.ring_base_lo = self.ring_base_hi = self.ring_size = 0
        self.head = self.tail = 0
        self.irq_status = self.irq_mask = self.err_code = 0
        self.irq_level = False

    # interrupt and error -------------------------------------------------
    def update_irq(self):
        level = bool(self.irq_status & self.irq_mask)
        if level and not self.irq_level:
            self.events.append("MSI")
        self.irq_level = level

    def error(self, code):
        self.events.append(f"ERROR code=0x{code:x}")
        self.err_code = code
        self.status |= C["STATUS_ERROR"]
        self.irq_status |= C["IRQ_STATUS_ERROR"]
        self.update_irq()

    def has_work(self):
        return (self.ctrl & C["CTRL_ENABLE"] and
                not self.status & C["STATUS_ERROR"] and
                self.head != self.tail)

    def update_busy(self):
        if self.has_work():
            self.status |= C["STATUS_BUSY"]
        else:
            self.status &= ~C["STATUS_BUSY"]

    # one descriptor --------------------------------------------------------
    def copy(self, src, dst, n):
        data = self.mem.read(src, n)
        if data is None:
            return C["ERR_DMA_FAIL"]
        self.events.append("SRC " + data.hex())
        before = self.mem.read(dst, n)
        if before is not None:
            self.events.append("DST_BEFORE " + before.hex())
        if not self.mem.write(dst, data):
            return C["ERR_DMA_FAIL"]
        self.events.append("DST_AFTER " + self.mem.read(dst, n).hex())
        return C["ERR_OK"]

    def bad_len(self, n):
        return n == 0 or n > C["MAX_XFER_DEFAULT"]

    def advance_head(self):
        self.head = (self.head + 1) & (self.ring_size - 1)

    def step(self):
        base = self.ring_base_hi << 32 | self.ring_base_lo
        addr = base + self.head * C["DESC_SIZE"]
        if (base % C["RING_ALIGN"] or not is_pow2(self.ring_size) or
                not C["RING_SIZE_MIN"] <= self.ring_size <= C["RING_SIZE_MAX"]):
            self.error(C["ERR_BAD_DESC"])
            return
        desc = self.mem.read(addr, C["DESC_SIZE"])
        if desc is None:
            self.error(C["ERR_DMA_FAIL"])
            return

        def field(off, n):
            return int.from_bytes(desc[off:off + n], "little")
        flags = field(C["DESC_OFF_FLAGS"], 4)
        if not flags & C["DESC_OWN"]:
            self.error(C["ERR_BAD_DESC"])
            return
        src = field(C["DESC_OFF_SRC"], 8)
        dst = field(C["DESC_OFF_DST"], 8)
        n = field(C["DESC_OFF_LEN"], 4)
        rsvd = field(C["DESC_OFF_RSVD"], 4)
        self.events.append(
            f"DESC head={self.head} addr=0x{addr:x} src=0x{src:x} "
            f"dst=0x{dst:x} len={n} flags=0x{flags:x} rsvd=0x{rsvd:x}")
        if rsvd:
            err = C["ERR_BAD_DESC"]
        elif self.bad_len(n):
            err = C["ERR_BAD_LEN"]
        else:
            err = self.copy(src, dst, n)
        self.events.append(f"DONE status=0x{err:x}")
        # rule 5: status before OWN clears
        if not (self.mem.write(addr + C["DESC_OFF_STATUS"],
                               err.to_bytes(4, "little")) and
                self.mem.write(addr + C["DESC_OFF_FLAGS"],
                               (flags & ~C["DESC_OWN"]).to_bytes(4, "little"))):
            self.error(C["ERR_DMA_FAIL"])
            return
        self.advance_head()
        if err:
            self.error(err)
            return
        if flags & C["DESC_IRQ"]:
            self.irq_status |= C["IRQ_STATUS_COMPLETION"]
            self.update_irq()

    def kick(self):
        self.update_busy()
        while self.has_work():
            self.step()
        self.update_busy()

    # register port ---------------------------------------------------------
    def reg_read(self, off):
        regs = {
            C["REG_ID"]: C["ID_MAGIC"], C["REG_VERSION"]: C["VERSION"],
            C["REG_CTRL"]: self.ctrl, C["REG_STATUS"]: self.status,
            C["REG_RING_BASE_LO"]: self.ring_base_lo,
            C["REG_RING_BASE_HI"]: self.ring_base_hi,
            C["REG_RING_SIZE"]: self.ring_size,
            C["REG_HEAD"]: self.head, C["REG_TAIL"]: self.tail,
            C["REG_IRQ_STATUS"]: self.irq_status,
            C["REG_IRQ_MASK"]: self.irq_mask,
            C["REG_ERR_CODE"]: self.err_code,
            C["REG_MAX_XFER"]: C["MAX_XFER_DEFAULT"],
        }
        return regs.get(off, 0)

    def reg_write(self, off, val):
        val &= 0xFFFFFFFF
        if off == C["REG_CTRL"]:
            if val & C["CTRL_RESET"]:
                self.reset()
            else:
                self.ctrl = val & C["CTRL_ENABLE"]
                self.kick()
        elif off == C["REG_RING_BASE_LO"]:
            self.ring_base_lo = val
        elif off == C["REG_RING_BASE_HI"]:
            self.ring_base_hi = val
        elif off == C["REG_RING_SIZE"]:
            self.ring_size = val
        elif off == C["REG_TAIL"]:
            self.tail = val
            self.kick()
        elif off == C["REG_IRQ_STATUS"]:
            self.irq_status &= ~val
            self.update_irq()
        elif off == C["REG_IRQ_MASK"]:
            self.irq_mask = val
            self.update_irq()


# trace replay ----------------------------------------------------------------

def parse_trace(path=TRACE):
    """The trace as a list of (register access, [device records]): every RD
    or WR line with the records the device produced before the next one."""
    steps = []
    for line in path.read_text().splitlines():
        if not line:
            continue
        if line.startswith(("RD ", "WR ")):
            steps.append((line, []))
        else:
            steps[-1][1].append(line)
    return steps


def stage(mem, records):
    """Put in memory what the driver had written before the doorbell: each
    descriptor the device fetched, its source bytes and the destination's old
    contents. A descriptor's status word is not in the trace; 0 is used."""
    for i, rec in enumerate(records):
        if rec.startswith("DESC "):
            d = dict(kv.split("=") for kv in rec.split()[1:])
            addr = int(d["addr"], 16)
            if not mem.ok(addr, C["DESC_SIZE"]):
                continue
            desc = bytearray(C["DESC_SIZE"])
            for name, off, n in (("src", "SRC", 8), ("dst", "DST", 8),
                                 ("len", "LEN", 4), ("flags", "FLAGS", 4),
                                 ("rsvd", "RSVD", 4)):
                o = C["DESC_OFF_" + off]
                desc[o:o + n] = int(d[name], 0).to_bytes(n, "little")
            mem.write(addr, desc)
            src, dst = int(d["src"], 16), int(d["dst"], 16)
            for later in records[i + 1:]:
                if later.startswith("DESC "):
                    break
                tag, _, data = later.partition(" ")
                if tag == "SRC":
                    mem.write(src, bytes.fromhex(data))
                elif tag == "DST_BEFORE":
                    mem.write(dst, bytes.fromhex(data))


def replay(model_cls=Dmaeng, path=TRACE):
    """Replay the trace through a fresh model. Returns (steps checked, first
    mismatch or None)."""
    mem = Memory()
    dev = model_cls(mem)
    steps = parse_trace(path)
    for n, (access, records) in enumerate(steps):
        kind, off, val = access.split()
        off, val = int(off, 16), int(val, 16)
        stage(mem, records)
        dev.events = []
        if kind == "RD":
            got = dev.reg_read(off)
            if got != val:
                return n, f"step {n}: {access}: model read 0x{got:08x}"
        else:
            dev.reg_write(off, val)
        if dev.events != records:
            return n, (f"step {n}: {access}: model did\n  "
                       + "\n  ".join(dev.events or ["(nothing)"])
                       + "\n trace has\n  "
                       + "\n  ".join(records or ["(nothing)"]))
        # the writeback the trace cannot show: status written, OWN cleared
        for rec in records:
            if rec.startswith("DESC "):
                d = dict(kv.split("=") for kv in rec.split()[1:])
                addr = int(d["addr"], 16)
                done = next(r for r in records if r.startswith("DONE "))
                status = int(done.split("=")[1], 16)
                if (mem.read32(addr + C["DESC_OFF_STATUS"]) != status or
                        mem.read32(addr + C["DESC_OFF_FLAGS"]) & C["DESC_OWN"]):
                    return n, f"step {n}: descriptor at 0x{addr:x} not written back"
    return len(steps), None


# planted bugs: each must make the replay fail ---------------------------------

class BugMsiEveryEvent(Dmaeng):
    """MSI on every completion, not on the level's rising edge."""
    def update_irq(self):
        if self.irq_status & self.irq_mask:
            self.events.append("MSI")
        self.irq_level = bool(self.irq_status & self.irq_mask)


class BugLenOffByOne(Dmaeng):
    """Rejects a transfer of exactly MAX_XFER bytes."""
    def bad_len(self, n):
        return n == 0 or n >= C["MAX_XFER_DEFAULT"]


class BugHeadStaysOnError(Dmaeng):
    """Leaves HEAD on a failed owned descriptor instead of advancing."""
    def error(self, code):
        if self.events and self.events[-1].startswith("DONE ") and code:
            self.head = (self.head - 1) & (self.ring_size - 1)
        super().error(code)


class BugResetKeepsMask(Dmaeng):
    """CTRL.RESET leaves IRQ_MASK set."""
    def reset(self):
        mask = getattr(self, "irq_mask", 0)
        super().reset()
        self.irq_mask = mask


class BugNoW1C(Dmaeng):
    """IRQ_STATUS write clears nothing."""
    def reg_write(self, off, val):
        if off == C["REG_IRQ_STATUS"]:
            return
        super().reg_write(off, val)


class BugHeadNoWrap(Dmaeng):
    """HEAD counts past RING_SIZE - 1 instead of wrapping by mask."""
    def advance_head(self):
        self.head += 1


PLANTED = [BugMsiEveryEvent, BugLenOffByOne, BugHeadStaysOnError,
           BugResetKeepsMask, BugNoW1C, BugHeadNoWrap]


# directed checks: what the trace never exercises (its Linux driver always
# clears IRQ_STATUS, reprograms after a reset, and keeps one descriptor in
# flight), each written from the spec text, not from the model ------------------

RING = 0x1000           # 4 KiB aligned
BUF = 0x10000


def setup(model_cls, size=8, mask=3):
    mem = Memory()
    dev = model_cls(mem)
    for off, val in (("RING_BASE_HI", 0), ("RING_BASE_LO", RING),
                     ("RING_SIZE", size), ("IRQ_MASK", mask), ("CTRL", 1)):
        dev.reg_write(C["REG_" + off], val)
    return mem, dev


def put_desc(mem, slot, src, dst, n, flags=None, rsvd=0):
    flags = C["DESC_OWN"] | C["DESC_IRQ"] if flags is None else flags
    addr = RING + slot * C["DESC_SIZE"]
    desc = bytearray(C["DESC_SIZE"])
    for off, val, w in (("SRC", src, 8), ("DST", dst, 8), ("LEN", n, 4),
                        ("FLAGS", flags, 4), ("STATUS", 0xDEADBEEF, 4),
                        ("RSVD", rsvd, 4)):
        desc[C["DESC_OFF_" + off]:C["DESC_OFF_" + off] + w] = val.to_bytes(w, "little")
    mem.write(addr, desc)
    return addr


def check_one_msi_per_edge(cls):
    """Two IRQ descriptors, IRQ_STATUS never cleared: the level rises once,
    so one MSI (spec 5.4 interrupt trigger rule)."""
    mem, dev = setup(cls)
    put_desc(mem, 0, BUF, BUF + 0x100, 16)
    put_desc(mem, 1, BUF, BUF + 0x200, 16)
    dev.events = []
    dev.reg_write(C["REG_TAIL"], 1)
    dev.reg_write(C["REG_TAIL"], 2)
    return dev.events.count("MSI") == 1


def check_max_xfer_boundary(cls):
    """len == MAX_XFER copies; MAX_XFER + 1 fails BAD_LEN."""
    mx = C["MAX_XFER_DEFAULT"]
    mem, dev = setup(cls)
    mem.write(BUF, bytes(range(256)) * (mx // 256))
    a0 = put_desc(mem, 0, BUF, BUF + 2 * mx, mx)
    dev.reg_write(C["REG_TAIL"], 1)
    if (mem.read32(a0 + C["DESC_OFF_STATUS"]) != C["ERR_OK"] or
            mem.read(BUF + 2 * mx, mx) != mem.read(BUF, mx)):
        return False
    a1 = put_desc(mem, 1, BUF, BUF + 2 * mx, mx + 1)
    dev.reg_write(C["REG_TAIL"], 2)
    return (mem.read32(a1 + C["DESC_OFF_STATUS"]) == C["ERR_BAD_LEN"] and
            dev.reg_read(C["REG_ERR_CODE"]) == C["ERR_BAD_LEN"])


def check_head_on_errors(cls):
    """An owned descriptor that fails: status written, OWN cleared, HEAD
    advanced, then stopped (later descriptors untouched). An error before
    ownership (OWN clear at HEAD): HEAD stays, ring untouched (spec 5.5)."""
    mem, dev = setup(cls)
    a0 = put_desc(mem, 0, BUF, BUF + 0x100, 16, rsvd=1)
    a1 = put_desc(mem, 1, BUF, BUF + 0x200, 16)
    dev.reg_write(C["REG_TAIL"], 2)
    owned_ok = (dev.reg_read(C["REG_HEAD"]) == 1 and
                mem.read32(a0 + C["DESC_OFF_STATUS"]) == C["ERR_BAD_DESC"] and
                not mem.read32(a0 + C["DESC_OFF_FLAGS"]) & C["DESC_OWN"] and
                mem.read32(a1 + C["DESC_OFF_FLAGS"]) & C["DESC_OWN"] and
                dev.reg_read(C["REG_STATUS"]) == C["STATUS_ERROR"])
    mem, dev = setup(cls)
    a0 = put_desc(mem, 0, BUF, BUF + 0x100, 16, flags=0)
    before = mem.read(a0, C["DESC_SIZE"])
    dev.reg_write(C["REG_TAIL"], 1)
    unowned_ok = (dev.reg_read(C["REG_HEAD"]) == 0 and
                  mem.read(a0, C["DESC_SIZE"]) == before and
                  dev.reg_read(C["REG_ERR_CODE"]) == C["ERR_BAD_DESC"])
    return owned_ok and unowned_ok


def check_reset_clears_all(cls):
    """CTRL.RESET clears every register (the driver must reprogram)."""
    mem, dev = setup(cls)
    put_desc(mem, 0, BUF, BUF + 0x100, 16, rsvd=1)
    dev.reg_write(C["REG_TAIL"], 1)
    dev.reg_write(C["REG_CTRL"], C["CTRL_RESET"])
    rw = ["CTRL", "STATUS", "RING_BASE_LO", "RING_BASE_HI", "RING_SIZE",
          "HEAD", "TAIL", "IRQ_STATUS", "IRQ_MASK", "ERR_CODE"]
    return all(dev.reg_read(C["REG_" + r]) == 0 for r in rw)


def check_batch_wraps(cls):
    """Five descriptors in one doorbell on a ring of 4 starting at slot 2:
    HEAD wraps by mask, every copy lands, LAST changes nothing."""
    mem, dev = setup(cls, size=4)
    dev.head = dev.tail = 2          # as if two were already consumed
    ok = True
    # ring of 4 holds 3 at once (one slot always free): 3, then 2 more
    for batch in ((2, 3, 0), (1, 2)):
        for slot in batch:
            src = BUF + slot * 0x40
            mem.write(src, bytes([slot + 1] * 32))
            last = C["DESC_LAST"] if slot == batch[-1] else 0
            put_desc(mem, slot, src, BUF + 0x1000 + slot * 0x40, 32,
                     flags=C["DESC_OWN"] | last)
        dev.reg_write(C["REG_TAIL"], (batch[-1] + 1) & 3)
        ok &= dev.reg_read(C["REG_HEAD"]) == (batch[-1] + 1) & 3
        ok &= all(mem.read(BUF + 0x1000 + s * 0x40, 32) == bytes([s + 1] * 32)
                  for s in batch)
    return ok and dev.reg_read(C["REG_STATUS"]) == 0


DIRECTED = [check_one_msi_per_edge, check_max_xfer_boundary,
            check_head_on_errors, check_reset_clears_all, check_batch_wraps]


def caught(bug):
    """Where a planted bug is caught: the trace step, or a directed check."""
    n, err = replay(bug)
    if err:
        return f"trace step {n}"
    failed = [chk.__name__ for chk in DIRECTED if not chk(bug)]
    return ", ".join(failed) if failed else None


def main():
    steps = parse_trace()
    descs = sum(r.startswith("DESC ") for _, rs in steps for r in rs)
    n, err = replay()
    if err:
        print(f"FAIL: golden trace, {err}")
        return 1
    print(f"PASS: golden trace, {n} register accesses, {descs} descriptors, "
          "every record matched")
    ok = True
    for chk in DIRECTED:
        good = chk(Dmaeng)
        ok &= good
        print(f"{'PASS' if good else 'FAIL'}: {chk.__name__}")
    for bug in PLANTED:
        where = caught(bug)
        ok &= where is not None
        print(f"{'PASS' if where else 'FAIL'}: planted {bug.__name__} "
              f"{'caught by ' + where if where else 'NOT caught'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
