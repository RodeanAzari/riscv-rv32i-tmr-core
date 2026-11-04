"""AXI4-Lite master for cocotb tests: one write or read at a time, with
chosen delays on every channel. The slave's ports are named s_<channel>_i/o
(dmaeng_regs, dmaeng)."""

from cocotb.triggers import FallingEdge

OKAY, SLVERR = 0, 2
MASK32 = 0xFFFF_FFFF


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
