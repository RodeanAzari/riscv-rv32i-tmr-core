/* Echo: the smallest interactive program. Each key comes back upper-cased
 * and shows on the LEDs; q returns to the bootloader. Loaded by the
 * bootloader test (tb/cocotb/test_boot.py) as well as by hand.
 */
#include "io.h"

int main(void)
{
    puts_("echo: type, q to quit\r\n");
    for (;;) {
        int c = getc_();
        if (c == 'q')
            break;
        LED = (uint32_t)c;
        putc_(c >= 'a' && c <= 'z' ? (char)(c - 32) : (char)c);
    }
    printf_("\r\necho: bye after %u cycles\r\n", CYCLE);
    return 0;
}
