/* Run riscv-tests rv32ui (or, with -m, rv32um) binaries on the golden model
 * alone, before it is trusted to judge the RTL.
 *
 *   rv32ui_check [-m] <test.bin>...
 *
 * -m turns the model's M extension on.
 *
 * Each flat binary is loaded at address 0 and run until it halts. The
 * environment (sw/riscv-tests-env/riscv_test.h) ends every test in ECALL with
 * gp = 1 for a pass, (n << 1) | 1 for a failure at test case n. Exit status
 * is the number of tests that did not pass.
 */
#include <stdio.h>
#include <string.h>

#include "rv32i_iss.h"

#define MAX_STEPS 1000000

static int run(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        printf("FAIL %s: cannot open\n", path);
        return 1;
    }
    rv_mem_clear();
    unsigned char b[4];
    uint32_t addr = 0;
    size_t n;
    while ((n = fread(b, 1, 4, f)) > 0) {
        for (size_t i = n; i < 4; i++)
            b[i] = 0;
        rv_mem_write32(addr, b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24);
        addr += 4;
    }
    fclose(f);

    rv_reset(0);
    rv_rec_t r;
    for (long i = 0; i < MAX_STEPS; i++) {
        int s = rv_step(&r);
        if (s == RV_OK)
            continue;
        if (s == RV_HALTED && r.insn == 0x00000073u && rv_reg(3) == 1) {
            printf("pass %s (%ld instructions)\n", path, i + 1);
            return 0;
        }
        printf("FAIL %s: status %d at pc %#x insn %#010x, gp %#x\n",
               path, s, r.pc_rdata, r.insn, rv_reg(3));
        return 1;
    }
    printf("FAIL %s: no halt in %d instructions\n", path, MAX_STEPS);
    return 1;
}

int main(int argc, char **argv)
{
    int fails = 0, first = 1;
    if (argc > 1 && strcmp(argv[1], "-m") == 0) {
        rv_set_m(1);
        first = 2;
    }
    for (int i = first; i < argc; i++)
        fails += run(argv[i]);
    printf("%d / %d passed\n", argc - first - fails, argc - first);
    return fails;
}
