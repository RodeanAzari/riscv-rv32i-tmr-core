/* Serial bootloader: receive a program over the UART into RAM and run it.
 *
 * In the bitstream at address 0, so it is what the core runs after RESET.
 * It prints a prompt, then waits for an image from scripts/load.py:
 *
 *   "RVLD"  len (u32, little-endian)  crc (u32)  len bytes of program
 *
 * The program is stored at APP_BASE as it arrives. If its CRC-32 (zlib's)
 * matches, the bootloader replies "OK" and jumps to APP_BASE; otherwise it
 * replies "ERR" and waits again. Bytes before the magic are ignored, so a
 * terminal's stray keystrokes or a half-sent image cannot wedge it.
 *
 * Pressing 'r' reruns the last good image, if its CRC still checks: a
 * program whose main returns comes back here (sw/app/crt0.S), and RESET
 * comes back here too, without the image having to be sent again.
 *
 * No libgcc: RV32I has no multiply or divide, and nothing here needs them.
 * No initialised data either: the bitstream sets it only once, and the
 * bootloader runs again on every return.
 */
#include "soc.h"

#define MAGIC 0x444C5652u            /* "RVLD", little-endian */

static void putc_(char c)
{
    while (!(UART_ST & UART_TX_READY))
        ;
    UART_TX = (uint8_t)c;
}

static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

static void put_hex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4)
        putc_("0123456789abcdef"[(v >> i) & 15u]);
}

/* A byte from the UART. Overrun or framing errors drop that byte (the
 * receiver has already); they are acknowledged and the wait goes on. */
static uint8_t getc_(void)
{
    for (;;) {
        uint32_t st = UART_ST;
        if (st & UART_RX_VALID) {
            uint8_t c = (uint8_t)UART_RX;
            UART_RX = 0;
            return c;
        }
        if (st & (UART_RX_OVERRUN | UART_RX_FRAME_ERR))
            UART_RX = 0;
    }
}

static uint32_t get_u32(void)
{
    uint32_t v = 0;
    for (int i = 0; i < 32; i += 8)
        v |= (uint32_t)getc_() << i;
    return v;
}

static uint32_t crc32_byte(uint32_t crc, uint8_t b)
{
    crc ^= b;
    for (int i = 0; i < 8; i++)
        crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
    return crc;
}

static uint32_t crc32(const volatile uint8_t *p, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    while (len--)
        crc = crc32_byte(crc, *p++);
    return ~crc;
}

static void run(void)
{
    puts_("OK\r\n");
    while (!(UART_ST & UART_TX_READY))   /* let the reply finish sending */
        ;
    ((void (*)(void))APP_BASE)();
}

int main(void)
{
    volatile uint8_t *app = (volatile uint8_t *)APP_BASE;

    LED = 0;
    puts_("\r\nrv32i bootloader: send a program (scripts/load.py)");
    if (SAVED_MAGIC == MAGIC)
        puts_(", or r to rerun the last one");
    puts_("\r\n");

    uint32_t window = 0;
    for (;;) {
        uint8_t c = getc_();
        if (c == 'r' && SAVED_MAGIC == MAGIC) {
            if (crc32(app, SAVED_LEN) == SAVED_CRC)
                run();
            puts_("ERR rerun: the last program was overwritten\r\n");
            SAVED_MAGIC = 0;
            continue;
        }
        window = (window >> 8) | ((uint32_t)c << 24);
        if (window != MAGIC)
            continue;
        window = 0;

        uint32_t len = get_u32();
        uint32_t want = get_u32();
        if (len == 0 || len > APP_MAX) {
            puts_("ERR length ");
            put_hex(len);
            puts_("\r\n");
            continue;
        }
        SAVED_MAGIC = 0;                 /* the old image is being overwritten */
        uint32_t crc = 0xFFFFFFFFu;
        for (uint32_t i = 0; i < len; i++) {
            uint8_t b = getc_();
            app[i] = b;
            crc = crc32_byte(crc, b);
        }
        crc = ~crc;
        if (crc != want) {
            puts_("ERR crc ");
            put_hex(crc);
            puts_("\r\n");
            continue;
        }
        SAVED_LEN = len;
        SAVED_CRC = crc;
        SAVED_MAGIC = MAGIC;
        run();
    }
}
