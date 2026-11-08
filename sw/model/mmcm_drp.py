"""Golden model of the array MMCM's dynamic reconfiguration (Phase H box 4).

The array clock comes from its own MMCME2_ADV (rtl/top/arty_a7_top.sv), which
software reprograms through the DRP behind the ACLK register
(rtl/periph/array_clk_ctl.sv). This model is what the tests judge by:

  - divider(d): the two DRP words of an integer output counter at 50 % duty
    and no phase shift, a port of AMD's mmcm_pll_divider/mmcm_pll_count_calc
    (clk_wiz's mmcm_pll_drp_func_7s_mmcm.vh, the XAPP888 reference); checked
    against AMD's own Verilog by `make aclk-check`;
  - UPDATES: the read-modify-write list AMD's reference state machine
    (clk_wiz mmcm_pll_drp_v) uses for CLKOUT0, masks included, which
    sw/lib/aclk.c follows;
  - Mmcm: the registers that set the output frequency, the rules a DRP
    master must keep (one access at a time, writes only while RST is high),
    and the frequency the registers give.

The board's array MMCM: 100 MHz in, VCO 800 MHz (x8, /1), CLKOUT0 /8 =
100 MHz. Only CLKOUT0's divider changes at run time: /10 is 80 MHz. The VCO
and so the lock and filter settings stay as Vivado set them.

Run as a script: self-checks, then exits 0.
"""

from __future__ import annotations

import sys

# DRP addresses (UG472, XAPP888)
CLKOUT0_REG1, CLKOUT0_REG2 = 0x08, 0x09
CLKFBOUT_REG1, CLKFBOUT_REG2 = 0x14, 0x15
DIVCLK_REG = 0x16
POWER_REG = 0x28

# The board's array MMCM (arty_a7_top.sv g_array_clk), and its limits for
# the -1 speed grade (DS181: VCO 600-1200 MHz, PFD 10-450 MHz)
IN_PS = 10_000
MULT, DIVCLK, OUT0_DIV = 8, 1, 8
VCO_MIN_PS, VCO_MAX_PS = 833, 1667          # 1200 MHz, 600 MHz
DIV_MAX = 128

def divider(d: int) -> tuple[int, int]:
    """(REG1, REG2) value bits for an integer divide d, 50 % duty, phase 0.

    REG1: PHASE_MUX[15:13]=0, [12] kept, HIGH_TIME[11:6], LOW_TIME[5:0].
    REG2: MX[9:8]=0, EDGE[7], NO_COUNT[6], DELAY_TIME[5:0]=0.
    """
    if not 1 <= d <= DIV_MAX:
        raise ValueError(f"divide {d} outside 1..{DIV_MAX}")
    if d == 1:
        high, low, edge, no_count = 1, 1, 0, 1
    else:
        # duty 0.5 * d rounded to a half: the half is EDGE
        half = d  # (0.5 * d) in halves
        high, edge = half // 2, half % 2
        if high == 0:
            high, edge = 1, 0
        if high == d:
            high, edge = d - 1, 1
        low = d - high
        no_count = 0
    reg1 = ((high & 0x3F) << 6) | (low & 0x3F)
    reg2 = (edge << 7) | (no_count << 6)
    return reg1, reg2


def updates(d: int) -> list[tuple[int, int, int]]:
    """The DRP read-modify-writes that set CLKOUT0 to /d, as AMD's reference
    does them: (address, mask of bits kept, value bits), the register read
    first and (read & mask) | value written back; POWER first. REG2's mask
    is the reference's fractional variant (0x8000): it writes FRAC_EN and
    the fraction to 0 rather than keeping whatever was there."""
    reg1, reg2 = divider(d)
    return [
        (POWER_REG, 0x0000, 0xFFFF),
        (CLKOUT0_REG1, 0x1000, reg1),
        (CLKOUT0_REG2, 0x8000, reg2),
    ]


def decode(reg1: int, reg2: int) -> int:
    """The divide a counter's two words give: HIGH + LOW, or 1 with NO_COUNT."""
    if (reg2 >> 6) & 1:
        return 1
    high, low = (reg1 >> 6) & 0x3F, reg1 & 0x3F
    return (high or 64) + (low or 64)


class DrpError(Exception):
    """A DRP master broke a rule of the primitive (UG472, XAPP888)."""


class Mmcm:
    """The registers and rules of an MMCME2_ADV seen through its DRP.

    Starts as Vivado configures it (MULT, DIVCLK, OUT0_DIV). Only the
    registers that set CLKOUT0's frequency are modelled; any other address
    reads 0 and keeps what is written.
    """

    def __init__(self, mult: int = MULT, divclk: int = DIVCLK, out0: int = OUT0_DIV):
        self.regs: dict[int, int] = {}
        self.regs[CLKOUT0_REG1], self.regs[CLKOUT0_REG2] = divider(out0)
        self.regs[CLKOUT0_REG1] |= 0x1000          # the counter's enable
        self.regs[CLKFBOUT_REG1], self.regs[CLKFBOUT_REG2] = divider(mult)
        self.regs[CLKFBOUT_REG1] |= 0x1000
        r1, r2 = divider(divclk)
        # DIVCLK: one word, {EDGE, NO_COUNT} at [13:12]
        self.regs[DIVCLK_REG] = (((r2 >> 6) & 3) << 12) | r1
        self.rst = True
        self.busy = False

    def access(self, addr: int, we: bool, di: int = 0) -> int:
        """One DRP access (DEN high for one DCLK); returns DO for a read."""
        if self.busy:
            raise DrpError("DEN before DRDY returned")
        if not 0 <= addr < 128 or not 0 <= di < 1 << 16:
            raise DrpError(f"address 0x{addr:x} or data 0x{di:x} out of range")
        if we:
            if not self.rst:
                raise DrpError(f"write to 0x{addr:02x} with RST low")
            self.regs[addr] = di
            return 0
        return self.regs.get(addr, 0)

    def divides(self) -> tuple[int, int, int]:
        """(CLKFBOUT, DIVCLK, CLKOUT0) divides the registers hold."""
        m = decode(self.regs[CLKFBOUT_REG1], self.regs[CLKFBOUT_REG2])
        dv = self.regs[DIVCLK_REG]
        d = 1 if (dv >> 12) & 1 else decode(dv & 0xFFF, 0)
        o = decode(self.regs[CLKOUT0_REG1], self.regs[CLKOUT0_REG2])
        return m, d, o

    def out_period_ps(self, in_ps: int = IN_PS) -> int:
        """CLKOUT0's period; raises if the VCO is out of range or inexact."""
        m, d, o = self.divides()
        vco = in_ps * d
        if vco % m:
            raise DrpError(f"VCO period {in_ps}*{d}/{m} ps is not whole")
        vco //= m
        if not VCO_MIN_PS <= vco <= VCO_MAX_PS:
            raise DrpError(f"VCO period {vco} ps outside {VCO_MIN_PS}-{VCO_MAX_PS}")
        return vco * o


def reprogram(mmcm: Mmcm, d: int) -> None:
    """AMD's flow at the model's level: RST, read-modify-writes, release."""
    mmcm.rst = True
    for addr, mask, bits in updates(d):
        old = mmcm.access(addr, False)
        mmcm.access(addr, True, (old & mask) | bits)
    mmcm.rst = False


def _expect_raise(fn, what: str) -> None:
    try:
        fn()
    except (DrpError, ValueError):
        return
    raise AssertionError(f"not refused: {what}")


def main() -> int:
    # divider: hand-worked values from AMD's function (duty 50 %, phase 0)
    assert divider(1) == ((1 << 6) | 1, 1 << 6)            # NO_COUNT
    assert divider(2) == ((1 << 6) | 1, 0)
    assert divider(5) == ((2 << 6) | 3, 1 << 7)            # odd: EDGE
    assert divider(8) == ((4 << 6) | 4, 0)
    assert divider(10) == ((5 << 6) | 5, 0)
    assert divider(128) == (0, 0)                           # 64 + 64 wraps to 0
    for d in range(1, DIV_MAX + 1):
        r1, r2 = divider(d)
        assert decode(r1, r2) == d, d
        assert r1 & 0xF000 == 0 and r2 & 0xFF00 == 0, d     # only its own fields
    _expect_raise(lambda: divider(0), "divide 0")
    _expect_raise(lambda: divider(129), "divide 129")

    # the board's clock: 100 MHz, then 80, then back
    m = Mmcm()
    assert m.divides() == (8, 1, 8) and m.out_period_ps() == 10_000
    reprogram(m, 10)
    assert m.out_period_ps() == 12_500 and m.regs[CLKOUT0_REG1] & 0x1000
    reprogram(m, 8)
    assert m.out_period_ps() == 10_000

    # the rules
    m = Mmcm()
    m.rst = False
    _expect_raise(lambda: m.access(CLKOUT0_REG1, True, 0), "write with RST low")
    assert m.access(CLKOUT0_REG1, False) == divider(8)[0] | 0x1000   # reads are fine
    m.busy = True
    _expect_raise(lambda: m.access(CLKOUT0_REG1, False), "DEN while busy")
    m = Mmcm(mult=16)                                       # 1600 MHz
    _expect_raise(m.out_period_ps, "VCO above 1200 MHz")
    m = Mmcm(mult=5)                                        # 500 MHz
    _expect_raise(m.out_period_ps, "VCO below 600 MHz")
    m = Mmcm(mult=7)                                        # legal, but not whole ps:
    _expect_raise(m.out_period_ps, "inexact VCO period")    # the model's own limit

    if "--table" in sys.argv:
        # one line per divide, for make aclk-check's comparison with AMD's
        # Verilog: d reg1 reg2 (reg1 without the kept bit 12)
        for d in range(1, DIV_MAX + 1):
            r1, r2 = divider(d)
            print(f"{d} {r1:04x} {r2:04x}")
        return 0
    print("mmcm_drp model: self-checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
