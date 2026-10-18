/* The demo reel's menu (sw/demo/demo.h). q returns to the bootloader. */
#include "demo.h"

uint32_t scratch[SCRATCH_WORDS];

static uint32_t rng = 0x2545F491u;

void seed(uint32_t s) { rng = s ? s : 0x2545F491u; }

uint32_t rand32(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

void wait_key(void)
{
    puts_("\r\n[press a key]");
    seed(CYCLE ^ (uint32_t)getc_());
}

void print_ms(uint32_t cycles)
{
    uint32_t us = cycles / (CLK_HZ / 1000000u);
    printf_("%u.%03u ms", us / 1000u, us % 1000u);
}

/* Digits, backspace, Enter; empty or out of range gives dflt. */
int read_number(const char *prompt, int min, int max, int dflt)
{
    printf_("%s [%d-%d, Enter for %d]: ", prompt, min, max, dflt);
    int v = 0, n = 0;
    for (;;) {
        int c = getc_();
        if (c == '\r' || c == '\n')
            break;
        if ((c == 8 || c == 127) && n) {
            v /= 10;
            n--;
            puts_("\b \b");
        } else if (c >= '0' && c <= '9' && n < 7) {
            v = v * 10 + (c - '0');
            n++;
            putc_((char)c);
        }
    }
    puts_("\r\n");
    return (n == 0 || v < min || v > max) ? dflt : v;
}

static void menu(void)
{
    puts_(CLS SHOW_CUR
          "  ____  __     __ _____  ____   ___ \r\n"
          " |  _ \\ \\ \\   / /|___ / |___ \\ |_ _|   a 5-stage pipelined CPU\r\n"
          " | |_) | \\ \\ / /   |_ \\   __) | | |    written from scratch,\r\n"
          " |  _ <   \\ V /   ___) | / __/  | |    formally verified, running\r\n"
          " |_| \\_\\   \\_/   |____/ |_____||___|   on an Arty A7 at 100 MHz\r\n"
          "\r\n"
          "  1  system info and pipeline microbenchmarks\r\n"
          "  2  Mandelbrot: fixed point vs software floating point\r\n"
          "  3  digits of pi\r\n"
          "  4  Conway's Game of Life\r\n"
          "  5  Tower of Hanoi\r\n"
          "  6  prime sieve\r\n"
          "  q  back to the bootloader\r\n"
          "\r\n> ");
}

int main(void)
{
    for (;;) {
        menu();
        int c = getc_();
        seed(CYCLE ^ (uint32_t)c);
        puts_(CLS);
        switch (c) {
        case '1': demo_sysinfo(); break;
        case '2': demo_mandel(); break;
        case '3': demo_pi(); break;
        case '4': demo_life(); break;
        case '5': demo_hanoi(); break;
        case '6': demo_primes(); break;
        case 'q': LED = 0; return 0;
        default: break;
        }
    }
}
