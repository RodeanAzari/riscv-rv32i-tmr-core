"""RV32I golden model, optionally RV32IM: one instruction at a time, no
pipeline, no timing.

Written from the ISA specification, not from the RTL, so it can disagree with
the core -- that is the point (CLAUDE.md 11, golden model before RTL). It has no
notion of stages, forwarding or stalls: whatever the pipeline does to get there,
the architectural result of a program must match this.

Where RV32I raises an exception, the core has no handler to enter (no trap
machinery is in scope), so it halts -- one rule, followed here
(docs/PROGRESS.md):

- ECALL and EBREAK.
- An illegal instruction: any word that is not one of the 40 RV32I encodings
  (CSR accesses, MRET, WFI, FENCE.I and the all-zero word included), plus the
  8 M encodings when the model is built with m_ext.
- A load or store whose address is not a multiple of its size.
- A taken branch or jump whose target is not 4-byte aligned. (JALR clears
  bit 0 first, as the spec says; a branch that is not taken never traps.)

A trapping instruction retires marked trap and halt, as RVFI defines them,
with no register write and no memory access, and nothing after it executes.

FENCE is a NOP, which is the spec's own meaning for one hart with no caches.

The M extension (m_ext=True) follows the spec's own table for the two cases
that do not trap in RISC-V: division by zero gives DIV/DIVU all ones and
REM/REMU the dividend; signed overflow (INT_MIN / -1) gives DIV INT_MIN and
REM 0. With m_ext off (the default) the M encodings are illegal, as they are
for the RV32I core.

Each step also leaves an RVFI-shaped record of what the instruction did in
self.trace, for per-retirement comparison against the core's RVFI port.
"""

MASK32 = 0xFFFF_FFFF
NOP = 0x0000_0013

OP, OP_IMM, LUI, AUIPC = 0b0110011, 0b0010011, 0b0110111, 0b0010111
LOAD, STORE = 0b0000011, 0b0100011
BRANCH, JAL, JALR = 0b1100011, 0b1101111, 0b1100111
MISC_MEM = 0b0001111
ECALL, EBREAK = 0x0000_0073, 0x0010_0073
MULDIV = 0x01                   # funct7 of every M instruction (opcode OP)


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


def muldiv(funct3, a, b):
    """MUL MULH MULHSU MULHU DIV DIVU REM REMU, by funct3, from the spec's
    definitions in unbounded integers: no carry tricks to get wrong."""
    sa, sb = signed(a), signed(b)
    if funct3 == 0b000:
        return (a * b) & MASK32
    if funct3 == 0b001:
        return ((sa * sb) >> 32) & MASK32
    if funct3 == 0b010:
        return ((sa * b) >> 32) & MASK32
    if funct3 == 0b011:
        return (a * b) >> 32
    if funct3 & 0b001:                              # unsigned: DIVU, REMU
        if b == 0:
            return MASK32 if funct3 == 0b101 else a
        return a // b if funct3 == 0b101 else a % b
    if b == 0:                                      # signed: DIV, REM
        return MASK32 if funct3 == 0b100 else a
    # Python's // floors; RISC-V truncates toward zero.
    q = abs(sa) // abs(sb) * (1 if (sa < 0) == (sb < 0) else -1)
    if funct3 == 0b100:
        return q & MASK32                           # INT_MIN / -1 wraps to INT_MIN
    return (sa - q * sb) & MASK32                   # remainder takes the dividend's sign


def legal(instr, m_ext=False):
    """True for exactly the 40 RV32I encodings, plus the 8 M encodings if
    m_ext; anything else traps."""
    opcode, funct3, funct7 = instr & 0x7F, (instr >> 12) & 0x7, instr >> 25
    if opcode in (LUI, AUIPC, JAL):
        return True
    if opcode == JALR:
        return funct3 == 0b000
    if opcode == BRANCH:
        return funct3 not in (0b010, 0b011)
    if opcode == LOAD:
        return funct3 in (0b000, 0b001, 0b010, 0b100, 0b101)
    if opcode == STORE:
        return funct3 in (0b000, 0b001, 0b010)
    if opcode == OP:
        return (funct7 == 0 or (funct7 == 0x20 and funct3 in (0b000, 0b101))
                or (m_ext and funct7 == MULDIV))
    if opcode == OP_IMM:
        return (funct3 not in (0b001, 0b101) or funct7 == 0
                or (funct7 == 0x20 and funct3 == 0b101))
    if opcode == MISC_MEM:
        return funct3 == 0b000                       # FENCE.I is Zifencei
    return instr in (ECALL, EBREAK)


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

    def __init__(self, mem=None, m_ext=False):
        self.m_ext = m_ext
        self.pc = 0
        self.x = [0] * 32
        self.mem = dict(mem or {})
        self.taken = 0          # redirects: taken branches and jumps
        # Registers with a known value. The core's register file has no reset,
        # so a register never written holds whatever the simulator put there;
        # the model's 0 is not a prediction of it.
        self.defined = {0}
        self.halted = False     # an ECALL or EBREAK has retired
        self.trace = None

    def _write(self, rd, value):
        if rd:
            self.x[rd] = value & MASK32
            self.defined.add(rd)

    def _access(self, addr, funct3):
        """(word address, bit shift, bits) for an access, or None if it is
        misaligned and traps."""
        size = 1 << (funct3 & 0b11)
        addr &= MASK32
        if addr & (size - 1):
            return None
        return addr & ~0b11, (addr & 0b11) * 8, size * 8

    def _trap(self):
        """An exception with no handler: retire marked, then stop. pc_wdata
        is left at pc -- RVFI leaves it unconstrained for a trap."""
        self.trace.update(trap=1, halt=1)
        self.halted = True
        return None

    def _trace_mem(self, word, shift, bits, rmask):
        mask = ((1 << (bits // 8)) - 1) << (shift // 8)
        self.trace.update(mem_addr=word, mem_rdata=self.mem.get(word, 0),
                          **{"mem_rmask" if rmask else "mem_wmask": mask})

    def _jump(self, target):
        """Take a branch or jump. False if the target is misaligned and the
        instruction traps instead."""
        if target & 0b11:
            return False
        self.pc = target & MASK32
        self.taken += 1
        return True

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
            "mem_rdata": 0, "mem_wdata": 0, "trap": 0, "halt": 0,
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

        if instr in (ECALL, EBREAK) or not legal(instr, self.m_ext):
            return self._trap()
        if opcode == MISC_MEM and funct3 == 0b000:      # FENCE
            self.pc += 4
            return None
        if opcode == BRANCH:
            if not branch_taken(funct3, rs1, rs2):
                self.pc += 4
            elif not self._jump(self.pc + imm_b):
                return self._trap()
            return None
        if opcode in (JAL, JALR):
            link = (self.pc + 4) & MASK32
            target = self.pc + imm_j if opcode == JAL else (rs1 + imm_i) & ~1
            if not self._jump(target):
                return self._trap()
            self._write(rd, link)      # after reading rs1: jalr x1, 0(x1) is legal
            return rd, link

        if opcode == OP and instr >> 25 == MULDIV:
            result = muldiv(funct3, rs1, rs2)
        elif opcode == OP:
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
            access = self._access(rs1 + imm_i, funct3)
            if access is None:
                return self._trap()
            word, shift, bits = access
            self._trace_mem(word, shift, bits, rmask=True)
            value = (self.mem.get(word, 0) >> shift) & ((1 << bits) - 1)
            result = value if funct3 & 0b100 else sext(value, bits) & MASK32
        elif opcode == STORE:
            access = self._access(rs1 + imm_s, funct3)
            if access is None:
                return self._trap()
            word, shift, bits = access
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


def run_model(program, mem=None, max_steps=100_000, traces=None, m_ext=False):
    """Run program from address 0 until it halts or the pc leaves it -- past
    the end, as a forward jump can. Returns (writebacks, model). max_steps stops a program
    that loops forever from hanging the test instead of failing it. Pass a
    list as traces to collect every retirement's RVFI record. m_ext=True
    models RV32IM."""
    model = RV32I(mem, m_ext)
    writebacks = []
    for _ in range(max_steps):
        if model.pc // 4 >= len(program):
            break
        wb = model.step(program[model.pc // 4])
        if traces is not None:
            traces.append(model.trace)
        if wb is not None:
            writebacks.append(wb)
        if model.halted:
            break
    else:
        raise RuntimeError(f"model: still running after {max_steps} instructions")
    return writebacks, model
