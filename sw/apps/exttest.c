/* External window self-test (soc EXT_EN, fpga-coord 0014): the core reads
 * and writes a register block on the ext_* ports through the crossbar.
 * Run by tb/cocotb/test_ext.py on the SoC built with EXT_EN, against a
 * register model that stalls READY; on the board (make impl EXT=1) against
 * rtl/periph/axil_regfile.sv, 16 words aliasing through the window.
 *
 *   1. word stores to four offsets spread over the window (distinct words
 *      in a 16-word file too), each read back
 *   2. byte and halfword stores into one word: only their lanes change;
 *      byte and halfword loads see them
 *   3. BUSERR still clear after all of it
 *   4. a load past every window (0x2000_3000): DECERR, reads 0, BUSERR
 *      set; writing clears it
 *
 * Then, not counted: a store and a load at the window's last word, which
 * the simulation's slave answers SLVERR; the line reports whether BUSERR
 * rose (1 in simulation, 0 against the board's register file, which never
 * errs). Summary "exttest: N/N ok".
 */
#include "io.h"

#define EXT(off) REG(SOC_EXT_BASE + (off))

static uint32_t passed, total;

static void check(int ok, const char *what)
{
    total++;
    if (ok)
        passed++;
    else
        printf_("exttest: FAIL %s\r\n", what);
}

int main(void)
{
    static const uint32_t off[4] = {0x000u, 0x004u, 0x7FCu, 0xFF8u};
    static const uint32_t val[4] = {0x01234567u, 0x89ABCDEFu, 0xDEADBEEFu, 0x5A5AA5A5u};
    uint32_t before;

    BUSERR = 0;

    before = passed;
    for (int i = 0; i < 4; i++)
        EXT(off[i]) = val[i];
    for (int i = 0; i < 4; i++)
        check(EXT(off[i]) == val[i], "word read back");
    printf_("exttest: words %u/4\r\n", passed - before);

    before = passed;
    volatile uint8_t *b = (volatile uint8_t *)(SOC_EXT_BASE + 0x010u);
    volatile uint16_t *h = (volatile uint16_t *)(SOC_EXT_BASE + 0x010u);
    EXT(0x010u) = 0x11223344u;
    b[1] = 0xAAu;
    check(EXT(0x010u) == 0x1122AA44u, "sb lane 1 only");
    h[1] = 0xBEEFu;
    check(EXT(0x010u) == 0xBEEFAA44u, "sh upper half only");
    check(b[0] == 0x44u && b[1] == 0xAAu && h[1] == 0xBEEFu, "lbu, lhu");
    check(EXT(off[0]) == val[0], "other words untouched");
    printf_("exttest: lanes %u/4\r\n", passed - before);

    check(BUSERR == 0, "no bus error from the window");

    before = passed;
    uint32_t v = REG(SOC_EXT_BASE + 0x1000u);
    check(v == 0 && (BUSERR & 1u), "0x2000_3000: DECERR");
    BUSERR = 0;
    check(BUSERR == 0, "BUSERR cleared");
    printf_("exttest: decode error %u/2\r\n", passed - before);

    EXT(0xFFCu) = 1u;
    uint32_t werr = BUSERR & 1u;
    BUSERR = 0;
    (void)EXT(0xFFCu);
    uint32_t rerr = BUSERR & 1u;
    BUSERR = 0;
    printf_("exttest: slverr store %u load %u\r\n", werr, rerr);

    printf_("exttest: %u/%u ok\r\n", passed, total);
    return passed != total;
}
