"""RV32I golden model: one instruction at a time, no pipeline, no timing.

Written from the ISA specification, not from the RTL, so it can disagree with
the core -- that is the point (CLAUDE.md 11, golden model before RTL). It has no
notion of stages, forwarding or stalls: whatever the pipeline does to get there,
the architectural result of a program must match this.

Memory and control flow match the core's documented misalignment assumption
(docs/PROGRESS.md): address bits below the access size are ignored, and a jump
or branch target drops bits [1:0]. RV32I would trap on both instead; this is
the one place the model follows a design decision rather than the spec.

Each step also leaves an RVFI-shaped record of what the instruction did in
self.trace, for per-retirement comparison against the core's RVFI port.

Not yet modelled: FENCE, ECALL/EBREAK. They raise rather than guess, so a
random generator that emits one fails loudly.
"""

MASK32 = 0xFFFF_FFFF
NOP = 0x0000_0013

OP, OP_IMM, LUI, AUIPC = 0b0110011, 0b0010011, 0b0110111, 0b0010111
LOAD, STORE = 0b0000011, 0b0100011
BRANCH, JAL, JALR = 0b1100011, 0b1101111, 0b1100111


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


def branch_taken(funct3, a, b):
    """BEQ BNE - - BLT BGE BLTU BGEU, by funct3. 010/011 are reserved."""
    if funct3 in (0b010, 0b011):
        raise NotImplementedError(f"model: reserved branch funct3 {funct3:#05b}")
    cond = {0b00: a == b, 0b10: signed(a) < signed(b), 0b11: a < b}[funct3 >> 1]
    return cond != bool(funct3 & 1)        # odd funct3 is the negation


class RV32I:
    """Architectural state: pc, x0-x31, and data memory.

    mem maps word-aligned byte addresses to 32-bit words; absent reads as 0.
    """

    def __init__(self, mem=None):
        self.pc = 0
        self.x = [0] * 32
        self.mem = dict(mem or {})
        self.taken = 0          # redirects: taken branches and jumps
        # Registers with a known value. The core's register file has no reset,
        # so a register never written holds whatever the simulator put there;
        # the model's 0 is not a prediction of it.
        self.defined = {0}
        self.trace = None

    def _write(self, rd, value):
        if rd:
            self.x[rd] = value & MASK32
            self.defined.add(rd)

    def _access(self, addr, funct3):
        size = 1 << (funct3 & 0b11)
        addr &= MASK32 & ~(size - 1)            # the misalignment assumption
        return addr & ~0b11, (addr & 0b11) * 8, size * 8

    def _trace_mem(self, word, shift, bits, rmask):
        mask = ((1 << (bits // 8)) - 1) << (shift // 8)
        self.trace.update(mem_addr=word, mem_rdata=self.mem.get(word, 0),
                          **{"mem_rmask" if rmask else "mem_wmask": mask})

    def _jump(self, target):
        self.pc = target & MASK32 & ~0b11       # the misalignment assumption
        self.taken += 1

    def step(self, instr):
        """Execute one instruction. Returns (rd, value) if it writes a
        register -- x0 included, as the core's WB reports it -- else None.

        Leaves self.trace: the RVFI view of the retirement. rs1/rs2 are the
        instruction's register FIELDS whether or not it reads them, as the core
        reports them; *_defined says whether the model knows the value. Memory
        fields are lane-style -- a word address, byte masks, data in its lanes
        -- like the core's port; masks are 0 for a non-memory instruction."""
        rs1_addr, rs2_addr = (instr >> 15) & 0x1F, (instr >> 20) & 0x1F
        t = self.trace = {
            "insn": instr, "pc_rdata": self.pc,
            "rs1_addr": rs1_addr, "rs1_rdata": self.x[rs1_addr],
            "rs1_defined": rs1_addr in self.defined,
            "rs2_addr": rs2_addr, "rs2_rdata": self.x[rs2_addr],
            "rs2_defined": rs2_addr in self.defined,
            "mem_addr": 0, "mem_rmask": 0, "mem_wmask": 0,
            "mem_rdata": 0, "mem_wdata": 0,
        }
        wb = self._execute(instr)
        rd, value = wb if wb is not None and wb[0] != 0 else (0, 0)
        t.update(pc_wdata=self.pc, rd_addr=rd, rd_wdata=value)
        return wb

    def _execute(self, instr):
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        funct3 = (instr >> 12) & 0x7
        rs1 = self.x[(instr >> 15) & 0x1F]
        rs2 = self.x[(instr >> 20) & 0x1F]
        imm_i = sext(instr >> 20, 12)
        imm_s = sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
        imm_u = instr & 0xFFFF_F000
        imm_b = sext((((instr >> 31) & 1) << 12) | (((instr >> 7) & 1) << 11)
                     | (((instr >> 25) & 0x3F) << 5) | (((instr >> 8) & 0xF) << 1), 13)
        imm_j = sext((((instr >> 31) & 1) << 20) | (((instr >> 12) & 0xFF) << 12)
                     | (((instr >> 20) & 1) << 11) | (((instr >> 21) & 0x3FF) << 1), 21)

        if opcode == BRANCH:
            if branch_taken(funct3, rs1, rs2):
                self._jump(self.pc + imm_b)
            else:
                self.pc += 4
            return None
        if opcode in (JAL, JALR):
            link = (self.pc + 4) & MASK32
            self._jump(self.pc + imm_j if opcode == JAL else rs1 + imm_i)
            self._write(rd, link)      # after reading rs1: jalr x1, 0(x1) is legal
            return rd, link

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
            self._trace_mem(word, shift, bits, rmask=True)
            value = (self.mem.get(word, 0) >> shift) & ((1 << bits) - 1)
            result = value if funct3 & 0b100 else sext(value, bits) & MASK32
        elif opcode == STORE:
            word, shift, bits = self._access(rs1 + imm_s, funct3)
            self._trace_mem(word, shift, bits, rmask=False)
            self.trace["mem_wdata"] = (rs2 << shift) & MASK32
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


def run_model(program, mem=None, max_steps=100_000, traces=None):
    """Run program from address 0 until the pc leaves it -- past the end, as a
    forward jump can. Returns (writebacks, model). max_steps stops a program
    that loops forever from hanging the test instead of failing it. Pass a
    list as traces to collect every retirement's RVFI record."""
    model = RV32I(mem)
    writebacks = []
    for _ in range(max_steps):
        if model.pc // 4 >= len(program):
            break
        wb = model.step(program[model.pc // 4])
        if traces is not None:
            traces.append(model.trace)
        if wb is not None:
            writebacks.append(wb)
    else:
        raise RuntimeError(f"model: still running after {max_steps} instructions")
    return writebacks, model
