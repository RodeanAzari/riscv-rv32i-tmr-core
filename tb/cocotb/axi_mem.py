"""AXI4 memory slave for cocotb tests, with protocol checks on the master.

Serves the master ports m_<channel>_o/i of the DUT (dmaeng) from a
dmaeng_model.Memory, the same byte memory the golden model uses, so the RTL
and the model can be compared byte for byte. Pages (4 KiB) can be made to
fail every access ("holes": SLVERR on reads and writes, nothing written) or
only writes ("read-only"), which is how the tests reach the engine's
bus-error paths.

Every cycle it checks what AXI4 requires of a master and the engine
promises (buildplan 6.2, DMA-Engine 14.2):
  - VALID never drops before its READY, and the payload holds while waiting;
  - INCR bursts of full-width beats that never cross 4 KiB;
  - WLAST on exactly the burst's last beat, no W beat beyond it;
  - nothing hangs: an accepted burst gets all its beats.
Ready and valid timing are random (`stall`, a probability per cycle), so
the engine is tested against a slave that stalls.

Driven and sampled at the falling edge, like axil.py: a handshake happens
at the next rising edge when VALID and READY are both high here. The
engine's AXI outputs are all flop outputs, so reading them at the falling
edge sees their value for the coming edge.
"""

from collections import deque

from cocotb.triggers import FallingEdge

PAGE = 4096
OKAY, SLVERR = 0, 2
ERR_DATA = 0xBAD0_BAD0


class AxiMem:
    def __init__(self, dut, mem, rng, data_bytes=4, stall=0.0):
        self.dut = dut
        self.mem = mem
        self.rng = rng
        self.nb = data_bytes
        self.stall = stall
        self.holes = set()       # page numbers: reads and writes fail
        self.read_only = set()   # page numbers: writes fail
        self.reads = deque()     # accepted AR: [addr, beats left]
        self.writes = deque()    # accepted AW: [addr, beats, beats taken, error]
        self.w_early = deque()   # W beats before their AW: (data, strb, last)
        self.b_queue = deque()   # responses owed
        self.r_beat = None       # (data, resp, last) being offered
        self.b_resp = None
        self.prev = {}           # master VALIDs and payloads last cycle
        self.errors = []
        self.stats = dict(ar=0, aw=0, r_beats=0, w_beats=0, bytes_written=0)
        self.aw_log = []         # every write burst's address, in bus order

    # --- memory ------------------------------------------------------------
    def page_ok(self, addr, write):
        page = addr // PAGE
        return page not in self.holes and not (write and page in self.read_only)

    def read_beat(self, addr):
        if not self.page_ok(addr, False):
            return ERR_DATA, SLVERR   # junk a master must not write anywhere
        return int.from_bytes(bytes(self.mem.bytes.get(addr + i, 0)
                                    for i in range(self.nb)), "little"), OKAY

    def fail(self, msg):
        self.errors.append(msg)

    # --- the slave -----------------------------------------------------------
    def ready(self):
        return int(self.rng.random() >= self.stall)

    def sig(self, name):
        return int(getattr(self.dut, name).value)

    def check_stable(self, chan, valid, payload):
        """VALID held until READY, payload unchanged while held."""
        prev = self.prev.get(chan)
        if prev is not None and prev[0] and not prev[2]:   # valid, no handshake
            if not valid:
                self.fail(f"{chan}VALID dropped before {chan}READY")
            elif payload != prev[1]:
                self.fail(f"{chan} payload changed while waiting: {prev[1]} -> {payload}")

    def check_burst(self, chan, addr, length, size, burst):
        beats = length + 1
        if burst != 1:
            self.fail(f"{chan}BURST {burst}, expected INCR")
        if 1 << size != self.nb:
            self.fail(f"{chan}SIZE {size} on a {self.nb}-byte bus")
        if addr % self.nb:
            self.fail(f"{chan}ADDR 0x{addr:x} not aligned to the bus")
        if addr // PAGE != (addr + beats * self.nb - 1) // PAGE:
            self.fail(f"{chan} burst at 0x{addr:x}, {beats} beats, crosses 4 KiB")

    async def run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk_i)
            self.step()

    def step(self):
        d = self.dut
        # ---- AR
        arvalid = self.sig("m_arvalid_o")
        ar = (self.sig("m_araddr_o"), self.sig("m_arlen_o"),
              self.sig("m_arsize_o"), self.sig("m_arburst_o"))
        self.check_stable("AR", arvalid, ar)
        arready = self.ready()
        d.m_arready_i.value = arready
        ar_hs = arvalid and arready
        if ar_hs:
            self.check_burst("AR", ar[0], ar[1], ar[2], ar[3])
            self.reads.append([ar[0], ar[1] + 1])
            self.stats["ar"] += 1
        self.prev["AR"] = (arvalid, ar, ar_hs)

        # ---- R: offer a beat, hold it until RREADY
        rready = self.sig("m_rready_o")
        if self.r_beat is None and self.reads and self.rng.random() >= self.stall:
            rd = self.reads[0]
            data, resp = self.read_beat(rd[0])
            rd[1] -= 1
            last = rd[1] == 0
            rd[0] += self.nb
            if last:
                self.reads.popleft()
            self.r_beat = (data, resp, last)
        if self.r_beat is not None:
            d.m_rvalid_i.value = 1
            d.m_rdata_i.value = self.r_beat[0]
            d.m_rresp_i.value = self.r_beat[1]
            d.m_rlast_i.value = int(self.r_beat[2])
            if rready:
                self.stats["r_beats"] += 1
                self.r_beat = None        # taken at the coming edge
        else:
            d.m_rvalid_i.value = 0
            d.m_rlast_i.value = 0

        # ---- AW
        awvalid = self.sig("m_awvalid_o")
        aw = (self.sig("m_awaddr_o"), self.sig("m_awlen_o"),
              self.sig("m_awsize_o"), self.sig("m_awburst_o"))
        self.check_stable("AW", awvalid, aw)
        awready = self.ready()
        d.m_awready_i.value = awready
        aw_hs = awvalid and awready
        self.prev["AW"] = (awvalid, aw, aw_hs)

        # ---- W
        wvalid = self.sig("m_wvalid_o")
        w = (self.sig("m_wdata_o"), self.sig("m_wstrb_o"), self.sig("m_wlast_o"))
        self.check_stable("W", wvalid, w)
        wready = self.ready()
        d.m_wready_i.value = wready
        w_hs = wvalid and wready
        self.prev["W"] = (wvalid, w, w_hs)

        if aw_hs:
            self.check_burst("AW", aw[0], aw[1], aw[2], aw[3])
            self.writes.append([aw[0], aw[1] + 1, 0, False])
            self.aw_log.append(aw[0])
            self.stats["aw"] += 1
            while self.w_early:
                self.take_w(*self.w_early.popleft())
        if w_hs:
            if self.writes and self.writes[-1][2] < self.writes[-1][1]:
                self.take_w(*w)
            else:
                self.w_early.append(w)

        # ---- B
        bready = self.sig("m_bready_o")
        if self.b_resp is None and self.b_queue and self.rng.random() >= self.stall:
            self.b_resp = self.b_queue.popleft()
        if self.b_resp is not None:
            d.m_bvalid_i.value = 1
            d.m_bresp_i.value = self.b_resp
            if bready:
                self.b_resp = None
        else:
            d.m_bvalid_i.value = 0

    def take_w(self, data, strb, last):
        wr = next((x for x in self.writes if x[2] < x[1]), None)
        if wr is None:
            self.fail("W beat with no burst to belong to")
            return
        addr = wr[0] + wr[2] * self.nb
        wr[2] += 1
        self.stats["w_beats"] += 1
        if bool(last) != (wr[2] == wr[1]):
            self.fail(f"WLAST {last} on beat {wr[2]} of {wr[1]}")
        if not self.page_ok(addr, True):
            wr[3] = True
        else:
            for i in range(self.nb):
                if strb >> i & 1:
                    self.mem.bytes[addr + i] = data >> (8 * i) & 0xFF
                    self.stats["bytes_written"] += 1
        if wr[2] == wr[1]:
            self.b_queue.append(SLVERR if wr[3] else OKAY)
            self.writes.remove(wr)

    def idle(self):
        return not (self.reads or self.writes or self.w_early or self.b_queue
                    or self.r_beat is not None or self.b_resp is not None)


def init_ports(dut):
    for s in ("m_arready_i", "m_rvalid_i", "m_rlast_i", "m_awready_i",
              "m_wready_i", "m_bvalid_i"):
        getattr(dut, s).value = 0
    dut.m_rdata_i.value = 0
    dut.m_rresp_i.value = 0
    dut.m_bresp_i.value = 0
