/* Digits of pi, streamed as they are found: the Rabinowitz-Wagon spigot.
 *
 * Integers only, but every step divides, and RV32I has no divide: each one is
 * a libgcc call. The work grows with the square of the digit count. A digit
 * can only be printed once the next one shows it will not carry, so runs of
 * 9s are held back (the predigit); output still arrives digit by digit.
 * q stops it early.
 */
#include "demo.h"

static int count;

static void emit(int d)
{
    putc_((char)('0' + d));
    if (++count == 1)
        puts_(".");
    else if ((count - 1) % 50 == 0)
        puts_("\r\n  ");
    else if ((count - 1) % 10 == 0)
        putc_(' ');
}

void demo_pi(void)
{
    puts_("digits of pi, by a spigot algorithm (integers only)\r\n\r\n");
    int n = read_number("how many digits", 10, 750, 300);   /* n*10/3+1 words of scratch */
    int len = n * 10 / 3 + 1;
    int32_t *a = (int32_t *)scratch;
    for (int i = 0; i < len; i++)
        a[i] = 2;
    count = 0;
    puts_("\r\n");

    uint32_t t = CYCLE;
    int nines = 0, pre = 0, stopped = 0;
    for (int j = 1; j <= n && !stopped; j++) {
        int32_t q = 0;
        for (int i = len; i > 0; i--) {
            int32_t x = 10 * a[i - 1] + q * i;
            a[i - 1] = x % (2 * i - 1);
            q = x / (2 * i - 1);
        }
        a[0] = q % 10;
        q /= 10;
        if (q == 9) {
            nines++;
        } else if (q == 10) {
            emit(pre + 1);
            for (; nines; nines--)
                emit(0);
            pre = 0;
        } else {
            if (j > 1)
                emit(pre);
            pre = q;
            for (; nines; nines--)
                emit(9);
        }
        stopped = try_getc() == 'q';
    }
    if (!stopped)
        emit(pre);
    t = CYCLE - t;
    printf_("\r\n\r\n%d digits in %u cycles (", count, t);
    print_ms(t);
    puts_(", UART time included)\r\n");
    wait_key();
}
