/* Fault injection, live: the same sieve run twice, the second time with a
 * bit of copy B's pc flipped every SPACING marks (soc.sv's TMR register).
 * Both runs execute the same instructions -- the first writes 0, which
 * flips nothing -- so their cycle counts compare directly. With TMR the
 * answers match, the cycles match, and the mismatch counter shows that the
 * voter saw every flip; on a single core the writes do nothing and the
 * counter stays at 0.
 */
#include "demo.h"

#define N       163840u
#define SPACING 64u

static uint32_t flips, detected, last;

/* One flip: the word to TMR, then two nops. The flip reaches copy B's pc
 * two cycles after the store; were a taken branch in EX then (the loop's,
 * here), its target would replace the flipped pc before anything used it
 * and the fault would be masked. The nops make the flipped pc the one B
 * fetches from next, so the voter has to outvote it. A flip counts as
 * detected if the mismatch counter has moved by the next one (one flip can
 * show as more than one disagreement: the fetch address, then a branch
 * target computed from the wrong pc). No branches here, so both runs take
 * the same cycles whatever is detected. */
static inline void flip(uint32_t bits)
{
    uint32_t now = TMR;
    detected += (now != last);
    last = now;
    flips++;
    __asm__ volatile("sw %0, 0(%1)\n nop\n nop" : : "r"(bits), "r"(&TMR) : "memory");
}

/* Count the primes up to N, flipping (1 << random bit) & on every SPACING
 * marks. Same sieve as primes.c, in scratch. */
static uint32_t sieve(uint32_t on)
{
    uint32_t k = 0, count = 1;
    for (uint32_t w = 0; w < SCRATCH_WORDS; w++)
        scratch[w] = 0;
    for (uint32_t p = 3; p * p <= N; p += 2) {
        uint32_t i = (p - 3) >> 1;
        if ((scratch[i >> 5] >> (i & 31u)) & 1u)
            continue;
        for (uint32_t m = p * p; m <= N; m += 2 * p) {
            i = (m - 3) >> 1;
            scratch[i >> 5] |= 1u << (i & 31u);
            if (++k % SPACING == 0)
                flip((1u << (rand32() & 31u)) & on);
        }
    }
    flip(0);                                /* settles the last flip's count */
    for (uint32_t i = 0; i < (N - 1) / 2; i++)
        count += !((scratch[i >> 5] >> (i & 31u)) & 1u);
    return count;
}

static void run(const char *what, uint32_t on, uint32_t *primes, uint32_t *cycles)
{
    uint32_t t, m = TMR;
    seed(1);
    flips = detected = 0;
    last = m;
    t = CYCLE;
    *primes = sieve(on);
    t = CYCLE - t;
    *cycles = t;
    flips--;                                /* the settling flip(0) */
    printf_("  %s  primes to %u: %u   %u cycles   flips %u, detected %u\r\n",
            what, N, *primes, t, on ? flips : 0, detected);
}

void demo_tmr(void)
{
    uint32_t p0, c0, p1, c1;
    puts_("TMR: each flip hits a random bit of copy B's pc\r\n\r\n");
    run("clean   ", 0, &p0, &c0);
    run("injected", ~0u, &p1, &c1);
    if (TMR == 0)
        puts_("\r\n  one core: nothing to flip (make impl TMR=1)\r\n");
    else
        printf_("\r\n  answer %s, cycles %s: every flip outvoted\r\n"
                "  disagreements since reset: %u\r\n",
                p0 == p1 ? "identical" : "DIFFERENT", c0 == c1 ? "identical" : "DIFFERENT", TMR);
    wait_key();
}
