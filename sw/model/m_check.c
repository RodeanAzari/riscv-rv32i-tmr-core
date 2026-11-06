/* Check the C golden model's M extension against spike's reference vectors
 * (sw/model/m_vectors.txt, from scripts/m_vectors.py), before it is trusted to
 * judge the RTL.
 *
 *   m_check <m_vectors.txt>
 *
 * Each vector runs as a program through rv_step, the model's only way in:
 * lui/addi load the two operands, then the M instruction. Every M encoding is
 * also checked to trap with M off, as on the RV32I core. Exits 1 on any
 * failure.
 */
#include <stdio.h>
#include <string.h>

#include "rv32i_iss.h"

static const char *const OPS[8] = {
    "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu",
};

/* lui rd, hi; addi rd, rd, lo -- the usual li split, lo sign-extended. */
static void li(uint32_t *p, uint32_t rd, uint32_t v)
{
    uint32_t hi = (v + 0x800u) & 0xFFFFF000u;
    p[0] = hi | rd << 7 | 0x37;
    p[1] = (v - hi) << 20 | rd << 15 | rd << 7 | 0x13;
}

static uint32_t m_insn(uint32_t f3)  /* <op> x3, x1, x2 */
{
    return 0x01u << 25 | 2u << 20 | 1u << 15 | f3 << 12 | 3u << 7 | 0x33;
}

/* Run the 5-instruction program for one vector; 0 and *out on success. */
static int run(uint32_t f3, uint32_t a, uint32_t b, uint32_t *out, rv_rec_t *r)
{
    uint32_t prog[5];
    li(prog, 1, a);
    li(prog + 2, 2, b);
    prog[4] = m_insn(f3);
    for (int i = 0; i < 5; i++)
        rv_mem_write32(4u * (uint32_t)i, prog[i]);
    rv_reset(0);
    for (int i = 0; i < 5; i++) {
        int s = rv_step(r);
        if (s != RV_OK)
            return s;
    }
    *out = rv_reg(3);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: m_check <m_vectors.txt>\n");
        return 2;
    }
    FILE *f = fopen(argv[1], "r");
    if (!f) {
        printf("FAIL: cannot open %s\n", argv[1]);
        return 1;
    }
    rv_mem_clear();
    int fails = 0, n = 0;
    rv_rec_t r;

    /* M off: every M encoding is illegal and traps without writing x3. */
    rv_set_m(0);
    for (uint32_t f3 = 0; f3 < 8; f3++) {
        uint32_t out;
        int s = run(f3, 7, 3, &out, &r);
        if (s != RV_HALTED || !r.trap || r.rd_addr != 0) {
            printf("FAIL %s with M off: status %d trap %u rd %u\n",
                   OPS[f3], s, r.trap, r.rd_addr);
            fails++;
        }
    }

    rv_set_m(1);
    char line[128], op[16];
    unsigned a, b, want;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#')
            continue;
        if (sscanf(line, "%15s %x %x %x", op, &a, &b, &want) != 4) {
            printf("FAIL: bad line: %s", line);
            fails++;
            continue;
        }
        uint32_t f3 = 0;
        while (f3 < 8 && strcmp(op, OPS[f3]) != 0)
            f3++;
        uint32_t got = 0;
        int s = f3 < 8 ? run(f3, a, b, &got, &r) : -1;
        n++;
        if (s != 0 || got != want || r.rd_addr != 3 || r.rd_wdata != want) {
            if (fails < 20)
                printf("FAIL %s %08x %08x: status %d got %08x want %08x\n",
                       op, a, b, s, got, want);
            fails++;
        }
    }
    fclose(f);
    if (n == 0) {
        printf("FAIL: no vectors in %s\n", argv[1]);
        return 1;
    }
    printf("%d / %d M vectors match spike, 8 / 8 trap with M off: %s\n",
           n - fails, n, fails ? "FAIL" : "pass");
    return fails != 0;   /* not the count: exit status keeps only its low 8 bits */
}
