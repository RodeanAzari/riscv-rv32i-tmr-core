"""Load/store lane alignment against a byte-level model of memory.

Purely combinational, so -- like the decoder -- drive, settle, check.

The model works on memory *bytes*, not on the module's output encoding. For a
store it does not ask "is wdata the right pattern?" -- it applies the DUT's
wdata and wstrb to a word of old memory and asks "does memory now hold what the
spec says the store leaves behind?" That is the property that matters, and it
stays true whether the RTL replicates the data across lanes or shifts it into
one. A test that pinned wdata's unwritten lanes would fail on a correct
redesign.

The space is small enough to sweep exhaustively: every width, every signedness,
every lane, against data whose byte and halfword sign bits are both set and
clear in different lanes.
"""

import cocotb
from cocotb.triggers import Timer

MASK32 = 0xFFFF_FFFF

LB, LH, LW, LBU, LHU = 0b000, 0b001, 0b010, 0b100, 0b101
SB, SH, SW = 0b000, 0b001, 0b010

SIZE = {0b00: 1, 0b01: 2, 0b10: 4}

# Each byte differs, and the sign bit of every byte lane and both half lanes is
# exercised both ways across the set.
DATA = [0x8001_7FFF, 0x7F80_FF01, 0xDEAD_BEEF, 0x0000_0000, 0xFFFF_FFFF,
        0x1234_5678]


def word_bytes(word):
    return [(word >> (8 * i)) & 0xFF for i in range(4)]


def bytes_word(bs):
    return sum(b << (8 * i) for i, b in enumerate(bs))


def aligned_offset(addr_lo, size):
    """The documented misalignment rule: address bits below the size are ignored."""
    return addr_lo & ~(size - 1) & 0b11


def ref_store(old_word, funct3, addr_lo, data):
    size = SIZE[funct3 & 0b11]
    off = aligned_offset(addr_lo, size)
    mem = word_bytes(old_word)
    for i in range(size):
        mem[off + i] = (data >> (8 * i)) & 0xFF
    return bytes_word(mem)


def ref_load(word, funct3, addr_lo):
    size = SIZE[funct3 & 0b11]
    off = aligned_offset(addr_lo, size)
    value = (word >> (8 * off)) & ((1 << (8 * size)) - 1)
    unsigned = funct3 & 0b100
    sign_bit = 1 << (8 * size - 1)
    if not unsigned and value & sign_bit:
        value |= MASK32 & ~((1 << (8 * size)) - 1)
    return value


def apply_strobes(old_word, wdata, wstrb):
    """What a byte-enabled memory holds after the write -- e.g. a BRAM's WEA."""
    mem = word_bytes(old_word)
    new = word_bytes(wdata)
    for i in range(4):
        if (wstrb >> i) & 1:
            mem[i] = new[i]
    return bytes_word(mem)


async def settle():
    await Timer(1, unit="ns")


@cocotb.test()
async def test_store_every_width_and_lane(dut):
    """Every store width at every address offset leaves memory as the spec says."""
    old = 0xA5A5_A5A5
    for funct3 in (SB, SH, SW):
        for addr_lo in range(4):
            for data in DATA:
                dut.st_size_i.value = funct3
                dut.st_addr_lo_i.value = addr_lo
                dut.st_data_i.value = data
                await settle()
                got = apply_strobes(old, int(dut.st_wdata_o.value),
                                    int(dut.st_wstrb_o.value))
                want = ref_store(old, funct3, addr_lo, data)
                assert got == want, (
                    f"funct3={funct3:03b} addr_lo={addr_lo} data={data:#010x}: "
                    f"memory {got:#010x}, expected {want:#010x}"
                )


@cocotb.test()
async def test_store_strobe_counts(dut):
    """SB writes one byte, SH two, SW four -- never more.

    apply_strobes() would accept an extra strobe on a lane whose wdata happens
    to equal the old memory byte. Counting strobes closes that gap.
    """
    for funct3, n in ((SB, 1), (SH, 2), (SW, 4)):
        for addr_lo in range(4):
            dut.st_size_i.value = funct3
            dut.st_addr_lo_i.value = addr_lo
            dut.st_data_i.value = 0
            await settle()
            strb = int(dut.st_wstrb_o.value)
            assert bin(strb).count("1") == n, (
                f"funct3={funct3:03b} addr_lo={addr_lo}: wstrb={strb:04b}"
            )


@cocotb.test()
async def test_load_every_width_lane_and_sign(dut):
    """Every load form at every offset selects the right lane and extends it right."""
    for funct3 in (LB, LH, LW, LBU, LHU):
        for addr_lo in range(4):
            for word in DATA:
                dut.ld_funct3_i.value = funct3
                dut.ld_addr_lo_i.value = addr_lo
                dut.ld_rdata_i.value = word
                await settle()
                got = int(dut.ld_data_o.value)
                want = ref_load(word, funct3, addr_lo)
                assert got == want, (
                    f"funct3={funct3:03b} addr_lo={addr_lo} word={word:#010x}: "
                    f"got {got:#010x}, expected {want:#010x}"
                )


@cocotb.test()
async def test_lb_and_lbu_differ_only_on_negative_bytes(dut):
    """The directed version of the signedness trap, so a failure names itself.

    0x80 is the smallest byte with bit 7 set: LB must give -128, LBU 128.
    """
    dut.ld_addr_lo_i.value = 0
    dut.ld_rdata_i.value = 0x0000_0080
    dut.ld_funct3_i.value = LB
    await settle()
    assert int(dut.ld_data_o.value) == 0xFFFF_FF80, "LB did not sign-extend"
    dut.ld_funct3_i.value = LBU
    await settle()
    assert int(dut.ld_data_o.value) == 0x0000_0080, "LBU sign-extended"

    dut.ld_rdata_i.value = 0x0000_8000
    dut.ld_funct3_i.value = LH
    await settle()
    assert int(dut.ld_data_o.value) == 0xFFFF_8000, "LH did not sign-extend"
    dut.ld_funct3_i.value = LHU
    await settle()
    assert int(dut.ld_data_o.value) == 0x0000_8000, "LHU sign-extended"
