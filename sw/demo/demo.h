/* The demo reel (sw/demo/): one program, a menu, six demos.
 *
 * Loaded by the bootloader like any program (make apps, scripts/load.py
 * sw/build/apps/demo.bin --term). Each demo reads keys while it runs.
 * Timings are core cycles from the SoC's cycle counter; milliseconds assume
 * the board's 100 MHz (CLK_HZ), which the simulation does not run at.
 */
#ifndef DEMO_H
#define DEMO_H

#include <stdint.h>
#include "io.h"

#ifndef CLK_HZ
#define CLK_HZ 100000000u
#endif

/* One scratch buffer, shared: the demos run one at a time, and 28 KiB of
 * program space does not hold a buffer each. 10 KiB: the code takes about
 * 16, the stack needs 2. */
#define SCRATCH_WORDS 2560u
extern uint32_t scratch[SCRATCH_WORDS];

#define CLS       "\x1b[2J\x1b[H"
#define HOME      "\x1b[H"
#define HIDE_CUR  "\x1b[?25l"
#define SHOW_CUR  "\x1b[?25h"

int  read_number(const char *prompt, int min, int max, int dflt);
void wait_key(void);
void print_ms(uint32_t cycles);      /* "12.345 ms" at CLK_HZ */
uint32_t rand32(void);               /* xorshift; seeded from key timing */
void seed(uint32_t s);

void demo_sysinfo(void);
void demo_mandel(void);
void demo_pi(void);
void demo_life(void);
void demo_hanoi(void);
void demo_primes(void);

#endif /* DEMO_H */
