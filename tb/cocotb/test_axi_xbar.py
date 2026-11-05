"""The AXI4 crossbar (rtl/bus/axi_xbar.sv): 3 masters, 2 slaves, DECERR.

Built here with slave 0 at 0x0xxx_xxxx (mask 0xF000_0000, as the SoC's RAM)
and slave 1 at 0x2000_0000-0x2000_0FFF (as the DMA's registers); everything
else is unmapped. Python masters issue random INCR bursts of 1-16 beats to
both slaves and to unmapped space, each into its own window of each slave,
so the expected data is exact; Python slaves are byte memories. Every
VALID and READY on every port is random-delayed.

What matters and why:
  - every transaction reaches the slave its address decodes to and comes
    back to the master that issued it, data exact: the SoC's masters share
    the slaves through this block;
  - unmapped addresses answer DECERR on every beat, with RLAST in place, and
    write nothing anywhere;
  - a master gets no second read (or write) while one is in flight
    (MAX_OUTSTANDING = 1): the masters here try, every time;
  - round-robin: with every master hammering one slave, none is passed over
    more than N - 1 times (no starvation);
  - the crossbar's own outputs keep AXI's rules: VALID held to READY with
    its payload stable, RLAST on the burst's last beat, B only after WLAST.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

N, M = 3, 2
AW, DW, NB = 32, 32, 4
OKAY, SLVERR, DECERR = 0, 2, 3
BASES = [0x0000_0000, 0x2000_0000]
UNMAPPED = 0x4000_0000
WINDOW = 0x400                       # bytes per master per slave


def rng_for(dut):
    seed = int(os.environ.get("SEED", "1"))
    dut._log.info(f"random seed {seed} (rerun with SEED={seed})")
    return random.Random(seed)


def get(sig, i, w):
    return (int(sig.value) >> (i * w)) & ((1 << w) - 1)


def put(vals, w):
    v = 0
    for i, x in enumerate(vals):
        v |= (x & ((1 << w) - 1)) << (i * w)
    return v


class Master:
    """Issues one read and one write at a time, and tries the next one as
    soon as the previous address is taken, to test the outstanding limit."""

    def __init__(self, idx, rng, bench):
        self.i, self.rng, self.b = idx, rng, bench
        self.shadow = {}                 # byte addr -> value, what it wrote
        self.ar = None                   # (addr, beats, target) being offered
        self.rd = None                   # read in flight: [addr, beats, got, target]
        self.aw = None
        self.wr = None                   # write in flight: [addr, beats, sent, data, target]
        self.w_beats = []                # W beats still to send
        self.wr_w = 0
        self.reads = self.writes = self.decerrs = 0
        self.ar_since = None             # cycle the current AR was first offered
        self.prev_w = False              # a W beat offered and not yet taken

    def target_addr(self, beats, avoid=()):
        """avoid: the targets of this master's transactions in the other
        direction, in flight or waiting: AXI does not order a read against a
        write, so overlapping them would make the expected data ambiguous."""
        choices = [t for t in (0, 0, 1, 1, 2) if t not in avoid or t == 2]
        t = self.rng.choice(choices) if not self.b.hammer else 0
        if t == 2:
            return UNMAPPED + self.rng.randrange(0, 0x1000, 4), t
        base = BASES[t] + self.i * WINDOW
        return base + 4 * self.rng.randrange(0, WINDOW // 4 - beats), t

    def new_read(self):
        beats = self.rng.randrange(1, 17)
        avoid = tuple(w[2] for w in (self.aw, self.wr) if w)
        addr, t = self.target_addr(beats, avoid)
        self.ar = (addr, beats, t)
        self.ar_since = self.b.cycle
        self.b.trace(f"master {self.i} new read 0x{addr:x} x{beats} to {t} (avoiding {avoid})", addr, 4 * beats)

    def new_write(self):
        beats = self.rng.randrange(1, 17)
        # a read can be in flight with the next one already waiting: both
        avoid = tuple(x for x in ((self.rd[3] if self.rd else None),
                                  (self.ar[2] if self.ar else None)) if x is not None)
        addr, t = self.target_addr(beats, avoid)
        data = [self.rng.getrandbits(32) for _ in range(beats)]
        strb = [self.rng.choice([0xF, 0xF, 0xF, self.rng.randrange(16)]) for _ in range(beats)]
        self.aw = (addr, beats, t)
        self.w_beats = list(zip(data, strb))
        self.b.trace(f"master {self.i} new write 0x{addr:x} x{beats} to {t} (avoid {avoid}, rd {self.rd and self.rd[:2]}, ar {self.ar})", addr, 4 * beats)
        self.wr_plan = (addr, beats, t, data, strb)


class Slave:
    """A byte memory: one read and one write at a time, random delays."""

    def __init__(self, idx, rng):
        self.i, self.rng = idx, rng
        self.mem = {}
        self.rd = None                   # [addr, beats left]
        self.wr = None                   # [addr, beats, taken]
        self.b_pending = False
        self.r_beat = None


class Bench:
    def __init__(self, dut, rng):
        self.dut, self.rng = dut, rng
        self.cycle = 0
        self.hammer = False
        self.stall = 0.3
        self.masters = [Master(i, rng, self) for i in range(N)]
        self.slaves = [Slave(s, rng) for s in range(M)]
        self.errors = []
        self.prev = {}                   # protocol: last cycle's VALID/payload/handshake
        self.grants = []                 # (cycle, master) of every AR taken at slave 0
        self.waits = []                  # other grants a master waited behind
        self.slave_owner = {}            # (slave, 'r'/'w') -> master, from the address

    def fail(self, msg):
        self.errors.append(f"cycle {self.cycle}: {msg}")

    # XBAR_TRACE=<hex address>: log every write and read touching that word
    TRACE = int(os.environ.get("XBAR_TRACE", "-1"), 16)

    def trace(self, msg, lo, n):
        if lo <= self.TRACE < lo + n:
            self.dut._log.info(f"cycle {self.cycle}: {msg}")

    def owner_of(self, addr):
        return (addr & 0xFFFF) // WINDOW

    def stable(self, key, valid, payload, hs):
        p = self.prev.get(key)
        if p and p[0] and not p[2]:
            if not valid:
                self.fail(f"{key} VALID dropped before READY")
            elif payload != p[1]:
                self.fail(f"{key} payload changed while waiting")
        self.prev[key] = (valid, payload, hs)

    async def run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk_i)
            self.cycle += 1
            r = self.rng
            # ---- masters drive
            arv, ara, arl, awv, awa, awl = [], [], [], [], [], []
            wv, wd, ws, wl, rr, br = [], [], [], [], [], []
            for m in self.masters:
                if m.ar is None and r.random() < 0.5:
                    m.new_read()
                # hammering measures reads alone: a read and a write of one
                # master to one slave would leave the expected data ambiguous
                # the next write may start (AW and its W beats offered) while
                # the last one still waits for B: the crossbar must hold both
                if m.aw is None and not m.w_beats and not self.hammer and r.random() < 0.5:
                    m.new_write()
                arv.append(int(m.ar is not None))
                ara.append(m.ar[0] if m.ar else 0)
                arl.append(m.ar[1] - 1 if m.ar else 0)
                awv.append(int(m.aw is not None))
                awa.append(m.aw[0] if m.aw else 0)
                awl.append(m.aw[1] - 1 if m.aw else 0)
                # W beats offered from the start, AW or not (AXI allows it)
                # once offered, a W beat is held until taken
                wvalid = bool(m.w_beats) and (m.prev_w or r.random() >= self.stall)
                m.prev_w = wvalid
                wv.append(int(wvalid))
                beat = m.w_beats[0] if m.w_beats else (0, 0)
                wd.append(beat[0])
                ws.append(beat[1])
                wl.append(int(len(m.w_beats) == 1))
                rr.append(int(r.random() >= self.stall))
                br.append(int(r.random() >= self.stall))
            d.m_arvalid_i.value = put(arv, 1)
            d.m_araddr_i.value = put(ara, AW)
            d.m_arlen_i.value = put(arl, 8)
            d.m_arsize_i.value = put([2] * N, 3)
            d.m_arburst_i.value = put([1] * N, 2)
            d.m_awvalid_i.value = put(awv, 1)
            d.m_awaddr_i.value = put(awa, AW)
            d.m_awlen_i.value = put(awl, 8)
            d.m_awsize_i.value = put([2] * N, 3)
            d.m_awburst_i.value = put([1] * N, 2)
            d.m_wvalid_i.value = put(wv, 1)
            d.m_wdata_i.value = put(wd, DW)
            d.m_wstrb_i.value = put(ws, NB)
            d.m_wlast_i.value = put(wl, 1)
            d.m_rready_i.value = put(rr, 1)
            d.m_bready_i.value = put(br, 1)
            # ---- slaves drive
            sar, saw, swr, srv, srd, srr, srl, sbv, sbr = [], [], [], [], [], [], [], [], []
            for s in self.slaves:
                sar.append(int(s.rd is None and r.random() >= self.stall))
                saw.append(int(s.wr is None and not s.b_pending and r.random() >= self.stall))
                swr.append(int(s.wr is not None and r.random() >= self.stall))
                if s.r_beat is None and s.rd and r.random() >= self.stall:
                    a = s.rd[0]
                    data = int.from_bytes(bytes(s.mem.get(a + k, 0) for k in range(NB)), "little")
                    s.r_beat = (data, int(s.rd[1] == 1))
                srv.append(int(s.r_beat is not None))
                srd.append(s.r_beat[0] if s.r_beat else 0)
                srl.append(s.r_beat[1] if s.r_beat else 0)
                srr.append(OKAY)
                sbv.append(int(s.b_pending))
                sbr.append(OKAY)
            d.s_arready_i.value = put(sar, 1)
            d.s_awready_i.value = put(saw, 1)
            d.s_wready_i.value = put(swr, 1)
            d.s_rvalid_i.value = put(srv, 1)
            d.s_rdata_i.value = put(srd, DW)
            d.s_rresp_i.value = put(srr, 2)
            d.s_rlast_i.value = put(srl, 1)
            d.s_bvalid_i.value = put(sbv, 1)
            d.s_bresp_i.value = put(sbr, 2)

            await ReadOnly()
            # ---- what the crossbar drives, and the handshakes at the edge
            mo = {k: [get(getattr(d, f"m_{k}_o"), i, w) for i in range(N)]
                  for k, w in (("arready", 1), ("awready", 1), ("wready", 1), ("rvalid", 1),
                               ("rdata", DW), ("rresp", 2), ("rlast", 1), ("bvalid", 1),
                               ("bresp", 2))}
            so = {k: [get(getattr(d, f"s_{k}_o"), i, w) for i in range(M)]
                  for k, w in (("arvalid", 1), ("araddr", AW), ("arlen", 8), ("awvalid", 1),
                               ("awaddr", AW), ("awlen", 8), ("wvalid", 1), ("wdata", DW),
                               ("wstrb", NB), ("wlast", 1), ("rready", 1), ("bready", 1))}
            events = []
            for i, m in enumerate(self.masters):
                self.stable(f"m{i}.R", mo["rvalid"][i], (mo["rdata"][i], mo["rresp"][i], mo["rlast"][i]),
                            mo["rvalid"][i] and rr[i])
                self.stable(f"m{i}.B", mo["bvalid"][i], mo["bresp"][i], mo["bvalid"][i] and br[i])
                if arv[i] and mo["arready"][i]:
                    if m.rd is not None:
                        self.fail(f"master {i}: a second read taken while one is in flight")
                    events.append(("ar", i))
                if awv[i] and mo["awready"][i]:
                    if m.wr is not None:
                        self.fail(f"master {i}: a second write taken while one is in flight")
                    events.append(("aw", i))
                if wv[i] and mo["wready"][i]:
                    events.append(("w", i))
                if mo["rvalid"][i] and rr[i]:
                    events.append(("r", i, mo["rdata"][i], mo["rresp"][i], mo["rlast"][i]))
                if mo["bvalid"][i] and br[i]:
                    events.append(("b", i, mo["bresp"][i]))
            for s, sl in enumerate(self.slaves):
                self.stable(f"s{s}.AR", so["arvalid"][s], (so["araddr"][s], so["arlen"][s]),
                            so["arvalid"][s] and sar[s])
                self.stable(f"s{s}.AW", so["awvalid"][s], (so["awaddr"][s], so["awlen"][s]),
                            so["awvalid"][s] and saw[s])
                self.stable(f"s{s}.W", so["wvalid"][s], (so["wdata"][s], so["wstrb"][s], so["wlast"][s]),
                            so["wvalid"][s] and swr[s])
                if so["arvalid"][s] and sar[s]:
                    events.append(("sar", s, so["araddr"][s], so["arlen"][s]))
                if so["awvalid"][s] and saw[s]:
                    events.append(("saw", s, so["awaddr"][s], so["awlen"][s]))
                if so["wvalid"][s] and swr[s]:
                    events.append(("sw", s, so["wdata"][s], so["wstrb"][s], so["wlast"][s]))
                if srv[s] and so["rready"][s]:
                    events.append(("sr", s))
                if sbv[s] and so["bready"][s]:
                    events.append(("sb", s))

            await RisingEdge(d.clk_i)
            for e in events:
                self.apply(e)

    def apply(self, e):
        kind = e[0]
        if kind == "ar":
            m = self.masters[e[1]]
            addr, beats, t = m.ar
            if t == 0 and self.hammer:
                others = sum(1 for c, g in self.grants if c > m.ar_since and g != m.i)
                self.waits.append(others)
            m.rd = [addr, beats, 0, t]
            m.ar = None
        elif kind == "aw":
            m = self.masters[e[1]]
            m.wr = list(m.wr_plan)
            m.wr_w = 0                     # its W beats taken
            m.aw = None
        elif kind == "w":
            m = self.masters[e[1]]
            if m.aw is not None:
                # this design routes W only after its AW: a beat taken now
                # would belong to no write, or to the one before
                self.fail(f"master {e[1]}: W beat taken before its AW")
                return
            m.w_beats.pop(0)
            m.prev_w = False
            m.wr_w += 1
        elif kind == "r":
            _, i, data, resp, last = e
            m = self.masters[i]
            if m.rd is None:
                self.fail(f"master {i}: R with no read in flight")
                return
            addr, beats, got, t = m.rd
            a = addr + 4 * got
            if t == 2:
                if resp != DECERR:
                    self.fail(f"master {i}: unmapped read answered {resp}")
            else:
                want = int.from_bytes(bytes(m.shadow.get((t, a + k), 0) for k in range(NB)), "little")
                if resp != OKAY or data != want:
                    self.fail(f"master {i}: read slave {t} 0x{a:x}: 0x{data:08x} resp {resp}, want 0x{want:08x}")
            self.trace(f"master {i} R 0x{a:x} = 0x{data:08x} from {t}", a, 4)
            m.rd[2] += 1
            if bool(last) != (m.rd[2] == beats):
                self.fail(f"master {i}: RLAST {last} on beat {m.rd[2]} of {beats}")
            if m.rd[2] == beats or last:
                m.reads += 1
                m.decerrs += t == 2
                m.rd = None
        elif kind == "b":
            _, i, resp = e
            m = self.masters[i]
            if m.wr is None or m.wr_w < m.wr[1]:
                self.fail(f"master {i}: B before the last W beat")
                return
            addr, beats, t, data, strb = m.wr
            if (t == 2) != (resp == DECERR) or (t != 2 and resp != OKAY):
                self.fail(f"master {i}: write to target {t} answered {resp}")
            self.trace(f"master {i} B for write 0x{addr:x} x{beats} to {t}", addr, 4 * beats)
            if t != 2:
                for k, (w, sb) in enumerate(zip(data, strb)):
                    for byte in range(NB):
                        if sb >> byte & 1:
                            m.shadow[(t, addr + 4 * k + byte)] = w >> (8 * byte) & 0xFF
            m.writes += 1
            m.decerrs += t == 2
            m.wr = None
        elif kind == "sar":
            _, s, addr, length = e
            sl = self.slaves[s]
            if not BASES[s] <= addr < BASES[s] + 0x1000 + (0x0FFF_F000 if s == 0 else 0):
                self.fail(f"slave {s}: AR for 0x{addr:x}, not its address")
            sl.rd = [addr, length + 1]
            if s == 0:
                self.grants.append((self.cycle, self.owner_of(addr)))
        elif kind == "saw":
            _, s, addr, length = e
            self.slaves[s].wr = [addr, length + 1, 0]
        elif kind == "sw":
            _, s, data, strb, last = e
            sl = self.slaves[s]
            if sl.wr is None:
                self.fail(f"slave {s}: W with no AW")
                return
            a = sl.wr[0] + 4 * sl.wr[2]
            self.trace(f"slave {s} W 0x{a:x} data 0x{data:08x} strb {strb:x}", a, 4)
            for byte in range(NB):
                if strb >> byte & 1:
                    sl.mem[a + byte] = data >> (8 * byte) & 0xFF
            sl.wr[2] += 1
            if bool(last) != (sl.wr[2] == sl.wr[1]):
                self.fail(f"slave {s}: WLAST {last} on beat {sl.wr[2]} of {sl.wr[1]}")
            if sl.wr[2] == sl.wr[1]:
                sl.wr = None
                sl.b_pending = True
        elif kind == "sr":
            sl = self.slaves[e[1]]
            sl.r_beat = None
            sl.rd[0] += 4
            sl.rd[1] -= 1
            if sl.rd[1] == 0:
                sl.rd = None
        elif kind == "sb":
            self.slaves[e[1]].b_pending = False


async def start(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    for name in ("m_arvalid_i", "m_awvalid_i", "m_wvalid_i", "m_rready_i", "m_bready_i",
                 "s_arready_i", "s_awready_i", "s_wready_i", "s_rvalid_i", "s_bvalid_i"):
        getattr(dut, name).value = 0
    dut.rst_i.value = 1
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    dut.rst_i.value = 0


@cocotb.test()
async def test_random_traffic(dut):
    """Random bursts from three masters to both slaves and unmapped space."""
    await start(dut)
    b = Bench(dut, rng_for(dut))
    cocotb.start_soon(b.run())
    for _ in range(int(os.environ.get("XBAR_CYCLES", "30000"))):
        await RisingEdge(dut.clk_i)
        if b.errors:
            break
    assert not b.errors, "\n".join(b.errors[:10])
    for m in b.masters:
        dut._log.info(f"master {m.i}: {m.reads} reads, {m.writes} writes, {m.decerrs} DECERR")
        assert m.reads > 100 and m.writes > 100 and m.decerrs > 20, "too little traffic"


@cocotb.test()
async def test_round_robin(dut):
    """Every master hammering slave 0: none waits behind more than N - 1
    grants to the others."""
    await start(dut)
    b = Bench(dut, rng_for(dut))
    b.hammer = True
    b.stall = 0.0
    cocotb.start_soon(b.run())
    for _ in range(20000):
        await RisingEdge(dut.clk_i)
        if b.errors:
            break
    assert not b.errors, "\n".join(b.errors[:10])
    assert len(b.waits) > 300, "too few grants"
    worst = max(b.waits)
    dut._log.info(f"{len(b.waits)} grants at slave 0; worst wait {worst} other grants")
    assert worst <= N - 1, f"a master waited behind {worst} grants"
    order = [g for _, g in b.grants[:60]]
    dut._log.info(f"grant order {order}")
