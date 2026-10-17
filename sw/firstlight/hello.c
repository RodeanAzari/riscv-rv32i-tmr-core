/* First light: the three things the board has to show (docs/PROGRESS.md).
 *
 *   1. text over the UART      -- a greeting
 *   2. a compiled C program    -- a sum, printed in decimal
 *   3. the LEDs                -- a counter, also printed, forever
 *
 * RV32I has no multiply or divide, and nothing here links libgcc, so the
 * code uses neither: decimal printing subtracts powers of ten.
 *
 * DELAY_LOOPS sets the pause between counts. The board build uses the
 * default (about a third of a second at 50 MHz); `make fw` also builds a
 * simulation image with a short one, which the cocotb test runs.
 */
#include <stdint.h>

#ifndef DELAY_LOOPS
#define DELAY_LOOPS 4000000u
#endif

/* Memory map: rtl/top/soc.sv. */
#define LED     (*(volatile uint32_t *)0x10000000u)
#define UART_TX (*(volatile uint32_t *)0x10000004u)
#define UART_ST (*(volatile uint32_t *)0x10000008u)
#define UART_READY 1u

static void putc_(char c)
{
    while (!(UART_ST & UART_READY))
        ;
    UART_TX = (uint8_t)c;
}

static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

static void put_dec(uint32_t v)
{
    static const uint32_t pow10[] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u,
    };
    int started = 0;
    for (unsigned i = 0; i < sizeof pow10 / sizeof pow10[0]; i++) {
        char d = '0';
        while (v >= pow10[i]) {
            v -= pow10[i];
            d++;
        }
        if (d != '0' || started || pow10[i] == 1u) {
            putc_(d);
            started = 1;
        }
    }
}

static void delay(uint32_t loops)
{
    /* volatile, or -O2 deletes the loop. */
    for (volatile uint32_t i = 0; i < loops; i++)
        ;
}

int main(void)
{
    puts_("\r\nhello from rv32i\r\n");

    uint32_t sum = 0;
    for (uint32_t i = 1; i <= 100; i++)
        sum += i;
    puts_("sum 1..100 = ");
    put_dec(sum);
    puts_("\r\n");

    for (uint32_t n = 0;; n++) {
        LED = n;
        puts_("count ");
        put_dec(n);
        puts_("\r\n");
        delay(DELAY_LOOPS);
    }
}
