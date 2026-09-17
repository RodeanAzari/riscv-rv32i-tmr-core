"""Decoder: register address extraction and immediate generation.

Purely combinational, so there is no clock here -- drive instr_i, settle, check.

The immediate cases deliberately sit on the boundaries CLAUDE.md 5.6 names:
zero, maximum positive, maximum negative, and the bit either side of the sign
change. An immediate decoder that drops the sign extension still passes on
small positive values, which is most of what random stimulus produces.
"""

import cocotb
from cocotb.triggers import Timer

OPCODE_LOAD   = 0b0000011
OPCODE_OP_IMM = 0b0010011
OPCODE_STORE  = 0b0100011
OPCODE_BRANCH = 0b1100011
OPCODE_LUI    = 0b0110111
OPCODE_AUIPC  = 0b0010111
OPCODE_JAL    = 0b1101111
OPCODE_OP     = 0b0110011

MASK32 = 0xFFFF_FFFF


def u32(value):
    """Two's-complement 32-bit view of a Python int."""
    return value & MASK32


# --- instruction encoders --------------------------------------------------
# Written from the RV32I spec rather than derived from the RTL, so a mistake in
# the decoder's bit picking cannot cancel out against the same mistake here.

def enc_i(imm, rs1=0, funct3=0, rd=0, opcode=OPCODE_OP_IMM):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def enc_s(imm, rs1=0, rs2=0, funct3=0, opcode=OPCODE_STORE):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) \
        | (funct3 << 12) | ((imm & 0x1F) << 7) | opcode


def enc_b(imm, rs1=0, rs2=0, funct3=0, opcode=OPCODE_BRANCH):
    return (((imm >> 12) & 0x1) << 31) | (((imm >> 5) & 0x3F) << 25) \
        | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) \
        | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 0x1) << 7) | opcode


def enc_u(imm, rd=0, opcode=OPCODE_LUI):
    return (imm & 0xFFFF_F000) | (rd << 7) | opcode


def enc_j(imm, rd=0, opcode=OPCODE_JAL):
    return (((imm >> 20) & 0x1) << 31) | (((imm >> 1) & 0x3FF) << 21) \
        | (((imm >> 11) & 0x1) << 20) | (((imm >> 12) & 0xFF) << 12) \
        | (rd << 7) | opcode


async def decode(dut, instr):
    dut.instr_i.value = instr
    await Timer(1, unit="ns")


# --- register fields -------------------------------------------------------

@cocotb.test()
async def test_register_fields(dut):
    """rs1, rs2 and rd come from fixed positions in every format."""
    # R-type with distinct, bit-pattern-distinguishable register numbers.
    await decode(dut, enc_i(0, rs1=0b10101, rd=0b01010, opcode=OPCODE_OP)
                 | (0b11111 << 20))
    assert int(dut.rs1_addr_o.value) == 0b10101
    assert int(dut.rs2_addr_o.value) == 0b11111
    assert int(dut.rd_addr_o.value) == 0b01010


@cocotb.test()
async def test_register_fields_all_values(dut):
    """Every register number decodes on every port -- catches stuck address bits."""
    for reg in range(32):
        await decode(dut, enc_i(0, rs1=reg, rd=reg, opcode=OPCODE_OP)
                     | (reg << 20))
        assert int(dut.rs1_addr_o.value) == reg, f"rs1 {reg}"
        assert int(dut.rs2_addr_o.value) == reg, f"rs2 {reg}"
        assert int(dut.rd_addr_o.value) == reg, f"rd {reg}"


# --- immediates ------------------------------------------------------------

@cocotb.test()
async def test_i_immediate(dut):
    """12-bit signed, range -2048..2047."""
    for imm in (0, 1, -1, 2047, -2048, 42, -42):
        await decode(dut, enc_i(imm))
        assert int(dut.imm_o.value) == u32(imm), (
            f"I-type {imm}: got {int(dut.imm_o.value):#010x}"
        )


@cocotb.test()
async def test_i_immediate_sign_boundary(dut):
    """2047 and -2048 are adjacent encodings but sit either side of zero."""
    await decode(dut, enc_i(2047))
    assert int(dut.imm_o.value) == 0x0000_07FF
    await decode(dut, enc_i(-2048))
    assert int(dut.imm_o.value) == 0xFFFF_F800, "sign extension dropped"


@cocotb.test()
async def test_s_immediate(dut):
    """Same 12-bit range as I-type, but split across two instruction fields."""
    for imm in (0, 1, -1, 2047, -2048, 1365, -1366):
        await decode(dut, enc_s(imm))
        assert int(dut.imm_o.value) == u32(imm), (
            f"S-type {imm}: got {int(dut.imm_o.value):#010x}"
        )


@cocotb.test()
async def test_b_immediate(dut):
    """13-bit signed, always even -- bit 0 is not encoded."""
    for imm in (0, 2, -2, 4094, -4096, 2048, -2048):
        await decode(dut, enc_b(imm))
        assert int(dut.imm_o.value) == u32(imm), (
            f"B-type {imm}: got {int(dut.imm_o.value):#010x}"
        )


@cocotb.test()
async def test_b_immediate_bit_zero_is_always_clear(dut):
    """No B encoding can produce an odd offset."""
    for imm in (2, -2, 4094, -4096):
        await decode(dut, enc_b(imm))
        assert int(dut.imm_o.value) & 1 == 0, "B-type produced an odd offset"


@cocotb.test()
async def test_u_immediate(dut):
    """Upper 20 bits placed directly; low 12 bits zero. No sign extension."""
    for imm in (0x0000_0000, 0xFFFF_F000, 0x1234_5000, 0x8000_0000):
        await decode(dut, enc_u(imm))
        assert int(dut.imm_o.value) == imm, (
            f"U-type {imm:#010x}: got {int(dut.imm_o.value):#010x}"
        )


@cocotb.test()
async def test_u_immediate_auipc_uses_same_form(dut):
    """AUIPC shares the U format with LUI."""
    await decode(dut, enc_u(0xABCD_E000, opcode=OPCODE_AUIPC))
    assert int(dut.imm_o.value) == 0xABCD_E000


@cocotb.test()
async def test_j_immediate(dut):
    """21-bit signed, always even."""
    for imm in (0, 2, -2, 1048574, -1048576, 4096, -4096):
        await decode(dut, enc_j(imm))
        assert int(dut.imm_o.value) == u32(imm), (
            f"J-type {imm}: got {int(dut.imm_o.value):#010x}"
        )


@cocotb.test()
async def test_load_uses_i_form(dut):
    """Loads are I-type even though they are not OP-IMM."""
    await decode(dut, enc_i(-4, opcode=OPCODE_LOAD))
    assert int(dut.imm_o.value) == u32(-4)


@cocotb.test()
async def test_shift_immediate_shamt_in_low_bits(dut):
    """SLLI/SRLI/SRAI take shamt from the low 5 bits of the I immediate.

    SRAI sets instr[30], which lands in the I immediate's bit 10. The decoder
    does not mask it -- EX takes shamt from imm[4:0] and reads the mode bit
    from the instruction -- so the check here is that the shamt bits survive.
    """
    await decode(dut, enc_i(0b0100000_11111, funct3=0b101))  # srai x0, x0, 31
    assert int(dut.imm_o.value) & 0x1F == 31


# --- EX control ------------------------------------------------------------

F3_ADD_SUB = 0b000
F3_SLL     = 0b001
F3_SRL_SRA = 0b101
F3_XOR     = 0b100

FUNCT7_ALT = 0b0100000   # the funct7 that selects SUB and SRA


def enc_r(funct3, rs1=1, rs2=2, rd=3, funct7=0):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) \
        | (rd << 7) | OPCODE_OP


@cocotb.test()
async def test_op_sets_register_operands(dut):
    """add rd, rs1, rs2 -- both operands from registers, writes rd."""
    await decode(dut, enc_r(F3_ADD_SUB))
    assert int(dut.rd_we_o.value) == 1
    assert int(dut.alu_a_sel_zero_o.value) == 0
    assert int(dut.alu_a_sel_pc_o.value) == 0
    assert int(dut.alu_b_sel_imm_o.value) == 0
    assert int(dut.funct3_o.value) == F3_ADD_SUB
    assert int(dut.alu_alt_o.value) == 0


@cocotb.test()
async def test_op_sub_sets_alt(dut):
    await decode(dut, enc_r(F3_ADD_SUB, funct7=FUNCT7_ALT))
    assert int(dut.alu_alt_o.value) == 1, "sub did not set alt"


@cocotb.test()
async def test_op_sra_sets_alt(dut):
    await decode(dut, enc_r(F3_SRL_SRA, funct7=FUNCT7_ALT))
    assert int(dut.alu_alt_o.value) == 1, "sra did not set alt"
    await decode(dut, enc_r(F3_SRL_SRA, funct7=0))
    assert int(dut.alu_alt_o.value) == 0, "srl set alt"


@cocotb.test()
async def test_op_imm_takes_immediate_operand(dut):
    await decode(dut, enc_i(5, funct3=F3_ADD_SUB))
    assert int(dut.rd_we_o.value) == 1
    assert int(dut.alu_b_sel_imm_o.value) == 1
    assert int(dut.alu_a_sel_zero_o.value) == 0


@cocotb.test()
async def test_addi_negative_immediate_is_not_a_subtract(dut):
    """The classic alt-bit bug.

    -1 encodes as instr[31:20] = 0xFFF, so instr[30] is set. On OP-IMM that bit
    is immediate bit 10, NOT a mode bit. A decoder that forwards instr[30] to
    alt unconditionally turns `addi rd, rs1, -1` into a subtract -- and does so
    only for immediates with bit 10 set, which small positive test values never
    produce.
    """
    for imm in (-1, -2, -1024, 1024, 2047, -2048):
        await decode(dut, enc_i(imm, funct3=F3_ADD_SUB))
        assert int(dut.alu_alt_o.value) == 0, (
            f"addi with imm={imm} decoded as a subtract"
        )


@cocotb.test()
async def test_non_shift_op_imm_never_sets_alt(dut):
    """Same trap for the other non-shift OP-IMM instructions."""
    for funct3 in (F3_ADD_SUB, 0b010, 0b011, F3_XOR, 0b110, 0b111):
        await decode(dut, enc_i(-1, funct3=funct3))
        assert int(dut.alu_alt_o.value) == 0, f"funct3 {funct3:#05b} set alt"


@cocotb.test()
async def test_shift_immediate_does_use_instr30(dut):
    """SRAI is the one OP-IMM form where instr[30] genuinely is a mode bit."""
    await decode(dut, enc_i((FUNCT7_ALT << 5) | 4, funct3=F3_SRL_SRA))
    assert int(dut.alu_alt_o.value) == 1, "srai did not set alt"
    await decode(dut, enc_i(4, funct3=F3_SRL_SRA))
    assert int(dut.alu_alt_o.value) == 0, "srli set alt"
    await decode(dut, enc_i(4, funct3=F3_SLL))
    assert int(dut.alu_alt_o.value) == 0, "slli set alt"


@cocotb.test()
async def test_lui_is_zero_plus_immediate(dut):
    await decode(dut, enc_u(0x1234_5000))
    assert int(dut.rd_we_o.value) == 1
    assert int(dut.alu_a_sel_zero_o.value) == 1
    assert int(dut.alu_b_sel_imm_o.value) == 1
    assert int(dut.alu_alt_o.value) == 0
    assert int(dut.funct3_o.value) == F3_ADD_SUB


@cocotb.test()
async def test_auipc_is_pc_plus_immediate(dut):
    await decode(dut, enc_u(0x1234_5000, opcode=OPCODE_AUIPC))
    assert int(dut.rd_we_o.value) == 1
    assert int(dut.alu_a_sel_pc_o.value) == 1
    assert int(dut.alu_a_sel_zero_o.value) == 0
    assert int(dut.alu_b_sel_imm_o.value) == 1


@cocotb.test()
async def test_unimplemented_classes_are_inert(dut):
    """Branches, jumps, loads and stores write no register until their stages
    exist. Inert beats plausibly wrong -- a half-implemented instruction that
    writes something is what riscv-formal would later blame on forwarding."""
    for instr in (enc_b(8), enc_j(8), enc_i(4, opcode=OPCODE_LOAD), enc_s(4)):
        await decode(dut, instr)
        assert int(dut.rd_we_o.value) == 0, f"{instr:#010x} writes a register"
