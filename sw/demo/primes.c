/* Sieve of Eratosthenes over the odd numbers, one bit each, then a prompt
 * that tests any number: by the sieve when it is in range, by trial
 * division (software divides) above it.
 */
#include "demo.h"

#define MAXN (SCRATCH_WORDS * 64u)          /* odd numbers only: 2 per bit */

static int composite(uint32_t n)           /* odd n >= 3, within the sieve */
{
    uint32_t i = (n - 3) >> 1;
    return (scratch[i >> 5] >> (i & 31u)) & 1u;
}

static void sieve(uint32_t n)
{
    for (uint32_t w = 0; w < SCRATCH_WORDS; w++)
        scratch[w] = 0;
    for (uint32_t p = 3; p * p <= n; p += 2)
        if (!composite(p))
            for (uint32_t m = p * p; m <= n; m += 2 * p) {
                uint32_t i = (m - 3) >> 1;
                scratch[i >> 5] |= 1u << (i & 31u);
            }
}

static int is_prime(uint32_t v, uint32_t n)
{
    if (v < 2)
        return 0;
    if (v < 4)
        return 1;
    if (!(v & 1u))
        return 0;
    if (v <= n)
        return !composite(v);
    for (uint32_t d = 3; d <= v / d; d += 2)
        if (v % d == 0)
            return 0;
    return 1;
}

void demo_primes(void)
{
    puts_("prime sieve (Eratosthenes, odd numbers, one bit each)\r\n\r\n");
    uint32_t n = (uint32_t)read_number("sieve up to", 100, (int)MAXN, 100000);
    uint32_t t = CYCLE;
    sieve(n);
    t = CYCLE - t;

    uint32_t count = 1, next = 10, last[8] = {2}, nl = 1;   /* 2, then the odd primes */
    puts_("\r\n      up to     primes\r\n");
    for (uint32_t v = 3; v <= n; v += 2) {
        if (!composite(v)) {
            count++;
            last[nl++ & 7u] = v;
        }
        if (v + 2 > next && next < n) {    /* every odd number up to next is done */
            printf_("  %9u  %9u\r\n", next, count);
            next *= 10;
        }
    }
    printf_("  %9u  %9u\r\n\r\nthe largest up to %u:", n, count, n);
    for (uint32_t i = nl > 8 ? nl - 8 : 0; i < nl; i++)
        printf_(" %u", last[i & 7u]);
    printf_("\r\nsieve: %u cycles (", t);
    print_ms(t);
    puts_(")\r\n\r\n");

    for (;;) {
        int v = read_number("test a number for primality (0 to go back)", 0, 9999999, 0);
        if (v == 0)
            break;
        printf_("  %d is %s\r\n", v, is_prime((uint32_t)v, n) ? "prime" : "not prime");
    }
}
