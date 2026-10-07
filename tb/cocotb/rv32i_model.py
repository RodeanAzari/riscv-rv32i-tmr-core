"""RV32I golden model: one instruction at a time, no pipeline, no timing.

Written from the ISA specification, not from the RTL, so it can disagree with
the core -- that is the point (CLAUDE.md 11, golden model before RTL). It has no
notion of stages, forwarding or stalls: whatever the pipeline does to get there,
the architectural result of a program must match this.

Memory matches the core's documented misalignment assumption (docs/PROGRESS.md):
address bits below the access size are ignored. That is this core's chosen
behaviour, not RV32I's, and it is the one place the model follows a design
decision rather than the spec.

Not yet modelled: branches, JAL/JALR, FENCE, ECALL/EBREAK. They raise rather
than guess, so a random generator that emits one fails loudly.
"""

MASK32 = 0xFFFF_FFFF
NOP = 0x0000_0013

OP, OP_IMM, LUI, AUIPC = 0b0110011, 0b0010011, 0b0110111, 0b0010111
LOAD, STORE = 0b0000011, 0b0100011


def sext(value, bits):
    sign = 1 << (bits - 1)
    return ((value & ((1 << bits) - 1)) ^ sign) - sign


def signed(value):
    return sext(value, 32)


def alu(funct3, alt, a, b):
    shamt = b & 0x1F
    if funct3 == 0b000:
        return (a - b if alt else a + b) & MASK32
    if funct3 == 0b001:
        return (a << shamt) & MASK32
    if funct3 == 0b010:
        return int(signed(a) < signed(b))
    if funct3 == 0b011:
        return int(a < b)
    if funct3 == 0b100:
        return a ^ b
    if funct3 == 0b101:
        return (signed(a) >> shamt) & MASK32 if alt else a >> shamt
    if funct3 == 0b110:
        return a | b
    return a & b


class RV32I:
    """Architectural state: pc, x0-x31, and data memory.

    mem maps word-aligned byte addresses to 32-bit words; absent reads as 0.
    """

    def __init__(self, mem=None):
        self.pc = 0
        self.x = [0] * 32
        self.mem = dict(mem or {})

    def _write(self, rd, value):
        if rd:
            self.x[rd] = value & MASK32

    def _access(self, addr, funct3):
        size = 1 << (funct3 & 0b11)
        addr &= MASK32 & ~(size - 1)            # the misalignment assumption
        return addr & ~0b11, (addr & 0b11) * 8, size * 8

    def step(self, instr):
        """Execute one instruction. Returns (rd, value) if it writes a
        register -- x0 included, as the core's WB reports it -- else None."""
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        funct3 = (instr >> 12) & 0x7
        rs1 = self.x[(instr >> 15) & 0x1F]
        rs2 = self.x[(instr >> 20) & 0x1F]
        imm_i = sext(instr >> 20, 12)
        imm_s = sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
        imm_u = instr & 0xFFFF_F000

        if opcode == OP:
            result = alu(funct3, (instr >> 30) & 1, rs1, rs2)
        elif opcode == OP_IMM:
            # instr[30] is a mode bit only for the shifts; elsewhere it is imm[10]
            alt = (instr >> 30) & 1 if funct3 in (0b001, 0b101) else 0
            result = alu(funct3, alt, rs1, imm_i & MASK32)
        elif opcode == LUI:
            result = imm_u
        elif opcode == AUIPC:
            result = (self.pc + imm_u) & MASK32
        elif opcode == LOAD:
            word, shift, bits = self._access(rs1 + imm_i, funct3)
            value = (self.mem.get(word, 0) >> shift) & ((1 << bits) - 1)
            result = value if funct3 & 0b100 else sext(value, bits) & MASK32
        elif opcode == STORE:
            word, shift, bits = self._access(rs1 + imm_s, funct3)
            lane = ((1 << bits) - 1) << shift
            old = self.mem.get(word, 0)
            self.mem[word] = (old & ~lane & MASK32) | ((rs2 << shift) & lane)
            self.pc += 4
            return None
        else:
            raise NotImplementedError(f"model: opcode {opcode:#09b} in {instr:#010x}")

        self._write(rd, result)
        self.pc += 4
        return rd, result & MASK32


def run_model(program, mem=None):
    """Run program from address 0 to its end. Returns (writebacks, model)."""
    model = RV32I(mem)
    writebacks = []
    while model.pc // 4 < len(program):
        wb = model.step(program[model.pc // 4])
        if wb is not None:
            writebacks.append(wb)
    return writebacks, model
