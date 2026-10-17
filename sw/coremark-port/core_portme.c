/* CoreMark port for the first-light SoC: timer, console and the CoreMark/MHz
 * line. Derived from EEMBC's barebones port (Apache-2.0); see core_portme.h.
 */
#include <stdarg.h>
#include <stdint.h>
#include "coremark.h"

#define UART_TX    (*(volatile uint32_t *)0x10000004u)
#define UART_ST    (*(volatile uint32_t *)0x10000008u)
#define CYCLE      (*(volatile uint32_t *)0x10000010u)
#define UART_READY 1u

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

/* ---- time: one tick per core cycle ---- */

static CORETIMETYPE start_time_val, stop_time_val;

void start_time(void) { start_time_val = CYCLE; }
void stop_time(void)  { stop_time_val = CYCLE; }

/* Exact modulo 2^32, so for any run shorter than 2^32 cycles (85 s at
 * 50 MHz) the counter's wrap does not matter. */
CORE_TICKS get_time(void) { return stop_time_val - start_time_val; }

secs_ret time_in_secs(CORE_TICKS ticks) { return ticks / CLK_HZ; }

/* ---- console ---- */

static void putc_(char c)
{
    while (!(UART_ST & UART_READY))
        ;
    UART_TX = (uint8_t)c;
}

static void put_uint(unsigned long v, unsigned base, int width, char pad)
{
    char buf[12];
    int  n = 0;
    do {
        unsigned d = v % base;
        buf[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        v /= base;
    } while (v);
    while (width-- > n)
        putc_(pad);
    while (n)
        putc_(buf[--n]);
}

/* What CoreMark's reports use and no more: %d %u %lu %x %s, with an optional
 * zero-padded width (%04x). "\n" goes out as CR LF for a serial terminal. */
int ee_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            if (*fmt == '\n')
                putc_('\r');
            putc_(*fmt);
            continue;
        }
        char pad = ' ';
        int  width = 0;
        if (*++fmt == '0')
            pad = *fmt++;
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        if (*fmt == 'l')
            fmt++;
        switch (*fmt) {
        case 'd': {
            long v = va_arg(ap, long);
            if (v < 0) {
                putc_('-');
                v = -v;
            }
            put_uint((unsigned long)v, 10, width, pad);
            break;
        }
        case 'u': put_uint(va_arg(ap, unsigned long), 10, width, pad); break;
        case 'x': put_uint(va_arg(ap, unsigned long), 16, width, pad); break;
        case 's':
            for (const char *s = va_arg(ap, const char *); *s; s++)
                putc_(*s);
            break;
        default: putc_('%'); putc_(*fmt); break;
        }
    }
    va_end(ap);
    return 0;
}

/* ---- init / fini ---- */

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    ee_printf("\nCoreMark on rv32i, %u iterations\n", (unsigned)ITERATIONS);
    p->portable_id = 1;
}

/* CoreMark/MHz = iterations / (ticks / 10^6), with ticks in core cycles.
 * Printed to three decimals, computed in 64-bit integers (no FPU). */
void portable_fini(core_portable *p)
{
    uint64_t milli = (uint64_t)ITERATIONS * 1000000000ull / get_time();
    ee_printf("CoreMark/MHz: %u.%03u\n", (unsigned)(milli / 1000),
              (unsigned)(milli % 1000));
    p->portable_id = 0;
}
