/* RV32I golden model: see rv32i_iss.h for what it models and why. */
#include "rv32i_iss.h"

#include <string.h>

enum {
    OP_LUI = 0x37, OP_AUIPC = 0x17, OP_JAL = 0x6F, OP_JALR = 0x67,
    OP_BRANCH = 0x63, OP_LOAD = 0x03, OP_STORE = 0x23,
    OP_IMM = 0x13, OP_OP = 0x33, OP_MISC_MEM = 0x0F, OP_SYSTEM = 0x73,
};
#define INSN_ECALL  0x00000073u
#define INSN_EBREAK 0x00100073u

static uint32_t x[32];
static uint32_t defined;      /* bit r: x[r] written since reset (x0 always) */
static uint32_t pc;
static int      halted;
static int      m_ext;        /* RV32IM: M encodings execute instead of trapping */
static uint8_t  mem[RV_MEM_BYTES];

static int32_t sext(uint32_t v, int bits)
{
    uint32_t m = 1u << (bits - 1);
    v &= (bits == 32) ? 0xFFFFFFFFu : ((1u << bits) - 1);
    return (int32_t)((v ^ m) - m);
}

void rv_reset(uint32_t start_pc)
{
    memset(x, 0, sizeof x);
    defined = 1u;
    pc = start_pc;
    halted = 0;
}

void rv_set_m(int on) { m_ext = on != 0; }

/* MUL MULH MULHSU MULHU DIV DIVU REM REMU, by funct3. */
static uint32_t muldiv(uint32_t f3, uint32_t a, uint32_t b)
{
    int32_t sa = (int32_t)a, sb = (int32_t)b;
    switch (f3) {
    case 0: return a * b;
    case 1: return (uint32_t)((uint64_t)((int64_t)sa * sb) >> 32);
    case 2: return (uint32_t)((uint64_t)((int64_t)sa * (int64_t)b) >> 32);
    case 3: return (uint32_t)(((uint64_t)a * b) >> 32);
    case 4:
        if (b == 0) return 0xFFFFFFFFu;
        if (a == 0x80000000u && b == 0xFFFFFFFFu) return a;   /* overflow, UB in C */
        return (uint32_t)(sa / sb);
    case 5: return b == 0 ? 0xFFFFFFFFu : a / b;
    case 6:
        if (b == 0) return a;
        if (a == 0x80000000u && b == 0xFFFFFFFFu) return 0;
        return (uint32_t)(sa % sb);
    default: return b == 0 ? a : a % b;
    }
}

void rv_mem_clear(void) { memset(mem, 0, sizeof mem); }

void rv_mem_write32(uint32_t addr, uint32_t word)
{
    if (addr + 4 > RV_MEM_BYTES || (addr & 3))
        return;
    for (int i = 0; i < 4; i++)
        mem[addr + i] = (uint8_t)(word >> (8 * i));
}

uint32_t rv_mem_read32(uint32_t addr)
{
    if (addr + 4 > RV_MEM_BYTES || (addr & 3))
        return 0;
    return (uint32_t)mem[addr] | (uint32_t)mem[addr + 1] << 8
         | (uint32_t)mem[addr + 2] << 16 | (uint32_t)mem[addr + 3] << 24;
}

uint32_t rv_reg(uint32_t r) { return x[r & 31]; }
uint32_t rv_pc(void) { return pc; }

static void wr(uint32_t rd, uint32_t v, rv_rec_t *r)
{
    if (rd == 0)
        return;
    x[rd] = v;
    defined |= 1u << rd;
    r->rd_addr = rd;
    r->rd_wdata = v;
}

static int trap(rv_rec_t *r)
{
    r->trap = r->halt = 1;
    r->pc_wdata = pc;      /* unconstrained for a trap; the core's is not compared */
    halted = 1;
    return RV_HALTED;
}

/* Take a branch or jump. 0 if the target is misaligned (the caller traps). */
static int jump(uint32_t target)
{
    if (target & 3)
        return 0;
    pc = target;
    return 1;
}

int rv_step(rv_rec_t *r)
{
    if (halted)
        return RV_STOPPED;
    if (pc + 4 > RV_MEM_BYTES || (pc & 3))
        return RV_BAD_ADDR;

    uint32_t in = rv_mem_read32(pc);
    uint32_t opcode = in & 0x7F, rd = (in >> 7) & 31, f3 = (in >> 12) & 7;
    uint32_t a1 = (in >> 15) & 31, a2 = (in >> 20) & 31, f7 = in >> 25;
    uint32_t v1 = x[a1], v2 = x[a2];

    memset(r, 0, sizeof *r);
    r->insn = in;
    r->pc_rdata = pc;
    r->rs1_addr = a1; r->rs1_rdata = v1; r->rs1_defined = (defined >> a1) & 1;
    r->rs2_addr = a2; r->rs2_rdata = v2; r->rs2_defined = (defined >> a2) & 1;

    int32_t imm_i = sext(in >> 20, 12);
    int32_t imm_s = sext((f7 << 5) | rd, 12);
    int32_t imm_b = sext(((in >> 31) & 1) << 12 | ((in >> 7) & 1) << 11
                         | ((in >> 25) & 0x3F) << 5 | ((in >> 8) & 0xF) << 1, 13);
    int32_t imm_j = sext(((in >> 31) & 1) << 20 | ((in >> 12) & 0xFF) << 12
                         | ((in >> 20) & 1) << 11 | ((in >> 21) & 0x3FF) << 1, 21);
    uint32_t imm_u = in & 0xFFFFF000u;
    uint32_t next = pc + 4;

    switch (opcode) {
    case OP_LUI:   wr(rd, imm_u, r); break;
    case OP_AUIPC: wr(rd, pc + imm_u, r); break;

    case OP_JAL:
        if (!jump(pc + (uint32_t)imm_j))
            return trap(r);
        wr(rd, next, r);
        r->pc_wdata = pc;
        return RV_OK;

    case OP_JALR:
        if (f3 != 0)
            return trap(r);
        if (!jump((v1 + (uint32_t)imm_i) & ~1u))   /* rs1 read before rd is written */
            return trap(r);
        wr(rd, next, r);
        r->pc_wdata = pc;
        return RV_OK;

    case OP_BRANCH: {
        int t;
        switch (f3) {
        case 0: t = v1 == v2; break;
        case 1: t = v1 != v2; break;
        case 4: t = (int32_t)v1 <  (int32_t)v2; break;
        case 5: t = (int32_t)v1 >= (int32_t)v2; break;
        case 6: t = v1 <  v2; break;
        case 7: t = v1 >= v2; break;
        default: return trap(r);
        }
        if (t) {
            if (!jump(pc + (uint32_t)imm_b))
                return trap(r);
        } else {
            pc = next;
        }
        r->pc_wdata = pc;
        return RV_OK;
    }

    case OP_LOAD: {
        uint32_t size = 1u << (f3 & 3), a = v1 + (uint32_t)imm_i;
        if (f3 == 3 || f3 > 5)
            return trap(r);
        if (a & (size - 1))
            return trap(r);
        if (a + size > RV_MEM_BYTES)
            return RV_BAD_ADDR;
        uint32_t word = rv_mem_read32(a & ~3u), sh = (a & 3) * 8;
        uint32_t raw = (size == 4) ? word : (word >> sh) & ((1u << (8 * size)) - 1);
        uint32_t v = (f3 & 4) ? raw : (uint32_t)sext(raw, 8 * (int)size);
        r->mem_addr = a & ~3u;
        r->mem_rmask = ((1u << size) - 1) << (a & 3);
        r->mem_rdata = word;
        wr(rd, v, r);
        break;
    }

    case OP_STORE: {
        uint32_t size = 1u << (f3 & 3), a = v1 + (uint32_t)imm_s;
        if (f3 > 2)
            return trap(r);
        if (a & (size - 1))
            return trap(r);
        if (a + size > RV_MEM_BYTES)
            return RV_BAD_ADDR;
        uint32_t sh = (a & 3) * 8;
        r->mem_addr = a & ~3u;
        r->mem_wmask = ((1u << size) - 1) << (a & 3);
        r->mem_wdata = v2 << sh;
        for (uint32_t i = 0; i < size; i++)
            mem[a + i] = (uint8_t)(v2 >> (8 * i));
        break;
    }

    case OP_IMM: {
        uint32_t b = (uint32_t)imm_i, shamt = a2, v;
        switch (f3) {
        case 0: v = v1 + b; break;
        case 2: v = (int32_t)v1 < imm_i; break;
        case 3: v = v1 < b; break;
        case 4: v = v1 ^ b; break;
        case 6: v = v1 | b; break;
        case 7: v = v1 & b; break;
        case 1:
            if (f7 != 0) return trap(r);
            v = v1 << shamt; break;
        case 5:
            if (f7 == 0x00)      v = v1 >> shamt;
            else if (f7 == 0x20) v = (uint32_t)((int32_t)v1 >> shamt);
            else return trap(r);
            break;
        default: return trap(r);
        }
        wr(rd, v, r);
        break;
    }

    case OP_OP: {
        uint32_t s = v2 & 31, v;
        if (f7 == 0x00) {
            switch (f3) {
            case 0: v = v1 + v2; break;
            case 1: v = v1 << s; break;
            case 2: v = (int32_t)v1 < (int32_t)v2; break;
            case 3: v = v1 < v2; break;
            case 4: v = v1 ^ v2; break;
            case 5: v = v1 >> s; break;
            case 6: v = v1 | v2; break;
            default: v = v1 & v2; break;
            }
        } else if (f7 == 0x01 && m_ext) {
            v = muldiv(f3, v1, v2);
        } else if (f7 == 0x20 && f3 == 0) {
            v = v1 - v2;
        } else if (f7 == 0x20 && f3 == 5) {
            v = (uint32_t)((int32_t)v1 >> s);
        } else {
            return trap(r);
        }
        wr(rd, v, r);
        break;
    }

    case OP_MISC_MEM:
        if (f3 != 0)                       /* FENCE only; FENCE.I is Zifencei */
            return trap(r);
        break;

    case OP_SYSTEM:
        if (in == INSN_ECALL || in == INSN_EBREAK)
            return trap(r);
        return trap(r);

    default:
        return trap(r);
    }

    pc = next;
    r->pc_wdata = pc;
    return RV_OK;
}
