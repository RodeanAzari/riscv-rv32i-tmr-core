/* Console I/O over the SoC's UART (sw/lib/io.h), and the two library
 * functions GCC may call on its own even in a freestanding build: it turns
 * clearing or copying loops into memset and memcpy. */
#include <stdarg.h>
#include <stddef.h>
#include "io.h"

void *memset(void *d, int c, size_t n)
{
    unsigned char *p = d;
    while (n--)
        *p++ = (unsigned char)c;
    return d;
}

void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *p = d;
    const unsigned char *q = s;
    while (n--)
        *p++ = *q++;
    return d;
}

void putc_(char c)
{
    while (!(UART_ST & UART_TX_READY))
        ;
    UART_TX = (uint8_t)c;
}

void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

/* Read, then acknowledge (a write): reading the RX register changes nothing.
 * Overrun and framing errors drop a byte; they are acknowledged and skipped. */
int try_getc(void)
{
    uint32_t st = UART_ST;
    if (st & UART_RX_VALID) {
        int c = (uint8_t)UART_RX;
        UART_RX = 0;
        return c;
    }
    if (st & (UART_RX_OVERRUN | UART_RX_FRAME_ERR))
        UART_RX = 0;
    return -1;
}

int getc_(void)
{
    int c;
    while ((c = try_getc()) < 0)
        ;
    return c;
}

static void put_num(uint32_t v, unsigned base, int neg, int width, char pad)
{
    char buf[12];
    int n = 0;
    do {
        buf[n++] = "0123456789abcdef"[v % base];
        v /= base;
    } while (v);
    if (neg)
        buf[n++] = '-';
    while (width-- > n)
        putc_(pad);
    while (n)
        putc_(buf[--n]);
}

void printf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            putc_(*fmt);
            continue;
        }
        char pad = ' ';
        int width = 0;
        if (*++fmt == '0')
            pad = '0', fmt++;
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        switch (*fmt) {
        case 'c': putc_((char)va_arg(ap, int)); break;
        case 's': puts_(va_arg(ap, const char *)); break;
        case 'u': put_num(va_arg(ap, uint32_t), 10, 0, width, pad); break;
        case 'x': put_num(va_arg(ap, uint32_t), 16, 0, width, pad); break;
        case 'd': {
            int32_t v = va_arg(ap, int32_t);
            put_num(v < 0 ? -(uint32_t)v : (uint32_t)v, 10, v < 0, width, pad);
            break;
        }
        case '%': putc_('%'); break;
        case '\0': fmt--; break;
        default: putc_('%'); putc_(*fmt); break;
        }
    }
    va_end(ap);
}
