/* System info, a RAM test, and the pipeline's costs measured live.
 *
 * Each microbenchmark is a block of straight-line instructions between two
 * reads of the cycle counter. Both reads are loads issued from EX, so their
 * difference counts exactly the cycles between them; an empty block measures
 * the reads' own spacing, which is subtracted. The expected results follow
 * from the pipeline (README, docs/PROGRESS.md): one cycle per instruction, one
 * stall when a load's result is used by the next instruction, two flushed
 * cycles behind every taken branch or jump, nothing for a branch not taken.
 */
#include "demo.h"

extern char __bss_start[], __bss_end[];

#define BENCH(name, block)                                               \
    static uint32_t name(void)                                           \
    {                                                                    \
        uint32_t a, b;                                                   \
        __asm__ volatile("lw %0, 0(%2)\n" block "lw %1, 0(%2)\n"         \
                         : "=&r"(a), "=&r"(b)                            \
                         : "r"(&CYCLE)                                   \
                         : "t0", "t1", "memory");                        \
        return b - a;                                                    \
    }

BENCH(b_empty,     "")
BENCH(b_alu,       ".rept 100\n addi t0, t0, 1\n .endr\n")
BENCH(b_load_use,  ".rept 50\n lw t0, 0(sp)\n addi t0, t0, 1\n .endr\n")
BENCH(b_load_gap,  ".rept 50\n lw t0, 0(sp)\n addi t1, t1, 1\n addi t0, t0, 1\n .endr\n")
BENCH(b_jump,      ".rept 50\n j 1f\n 1:\n .endr\n")
BENCH(b_taken,     ".rept 50\n beq zero, zero, 1f\n 1:\n .endr\n")
BENCH(b_not_taken, ".rept 50\n bne zero, zero, 1f\n 1:\n .endr\n")

static void row(const char *what, uint32_t instrs, uint32_t cycles, const char *why)
{
    uint32_t cpi = cycles * 100u / instrs;
    printf_("  %s %4u instr %4u cycles  CPI %u.%02u  %s\r\n",
            what, instrs, cycles, cpi / 100u, cpi % 100u, why);
}

static int ram_test(void)
{
    static const uint32_t pattern[] = {0x00000000u, 0xFFFFFFFFu, 0xA5A5A5A5u, 0x5A5A5A5Au};
    for (unsigned p = 0; p < 4; p++) {
        for (unsigned i = 0; i < SCRATCH_WORDS; i++)
            scratch[i] = pattern[p] ^ i;
        for (unsigned i = 0; i < SCRATCH_WORDS; i++)
            if (scratch[i] != (pattern[p] ^ i))
                return 0;
    }
    return 1;
}

void demo_sysinfo(void)
{
    uint32_t up = CYCLE;
    uint32_t image = (uint32_t)(__bss_start - (char *)APP_BASE);
    uint32_t bss = (uint32_t)(__bss_end - __bss_start);

    puts_("system\r\n"
          "  RV32I, all 40 instructions; 5-stage pipeline, full forwarding,\r\n"
          "  branches resolved in EX (static not-taken), every exception halts\r\n");
    printf_("  core clock %u MHz (as built; the cycle counter counts it)\r\n", CLK_HZ / 1000000u);
    printf_("  RAM 32 KiB: bootloader 4 KiB, this program %u bytes + %u bytes of data,\r\n"
            "  stack from the top\r\n", image, bss);
    printf_("  cycles since reset %u (", up);
    print_ms(up);
    puts_(")\r\n\r\n");

    printf_("RAM test, %u KiB scratch buffer, 4 patterns: ", SCRATCH_WORDS * 4u / 1024u);
    puts_(ram_test() ? "pass\r\n\r\n" : "FAIL\r\n\r\n");

    uint32_t base = b_empty();
    puts_("pipeline, measured now with the cycle counter\r\n");
    row("ALU ops               ", 100, b_alu() - base, "one per cycle");
    row("load, used next       ", 100, b_load_use() - base, "1 stall per load");
    row("load, used one later  ", 150, b_load_gap() - base, "forwarded, no stall");
    row("taken jumps           ",  50, b_jump() - base, "2 flushed cycles each");
    row("taken branches        ",  50, b_taken() - base, "2 flushed cycles each");
    row("branches not taken    ",  50, b_not_taken() - base, "free: predicted");
    wait_key();
}
