/* The array clock's divider through the MMCM's DRP: see aclk.h. */
#include "aclk.h"

/* LOCKED within this many core cycles of the release, or the change failed
 * (DS181: lock within 100 us; this is 10 ms at 100 MHz) */
#define LOCK_CYCLES 1000000u

static uint32_t drp(uint32_t word)
{
    ACLK = ACLK_RST | ACLK_GO | word;
    uint32_t st;
    while ((st = ACLK) & ACLK_BUSY)
        ;
    return st & 0xFFFFu;
}

static void rmw(uint32_t addr, uint32_t keep, uint32_t bits)
{
    uint32_t old = drp(ACLK_ADDR(addr));
    drp(ACLK_WE | ACLK_ADDR(addr) | (old & keep) | bits);
}

int aclk_present(void)
{
    return (ACLK & ACLK_LOCKED) != 0;
}

int aclk_set_divide(uint32_t d)
{
    if (d < 1 || d > ACLK_DIV_MAX || !aclk_present())
        return -1;
    /* mmcm_drp.divider(d): 50 % duty, no phase; an odd divide puts the
     * half cycle in EDGE; divide 1 is NO_COUNT */
    uint32_t high = d >> 1, low = d - high, edge = d & 1u, no_count = 0;
    if (d == 1) {
        high = 1;
        low = 1;
        edge = 0;
        no_count = 1;
    }
    uint32_t reg1 = ((high & 0x3Fu) << 6) | (low & 0x3Fu);
    uint32_t reg2 = (edge << 7) | (no_count << 6);

    ACLK = ACLK_RST;
    rmw(0x28, 0x0000u, 0xFFFFu);       /* POWER */
    rmw(0x08, 0x1000u, reg1);          /* CLKOUT0 REG1 */
    rmw(0x09, 0x8000u, reg2);          /* CLKOUT0 REG2 */
    ACLK = 0;

    uint32_t t0 = CYCLE;
    while (!(ACLK & ACLK_LOCKED))
        if (CYCLE - t0 > LOCK_CYCLES)
            return -2;
    return 0;
}
