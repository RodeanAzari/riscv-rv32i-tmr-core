/* Mandelbrot in ASCII, two ways: integer fixed point and software float.
 *
 * The view (centre and step) is kept in Q12 fixed point, and both renderers
 * start each pixel from the same Q12 coordinates, so the pictures match
 * except where float's extra precision changes an escape. Fixed point needs
 * only integer multiplies -- in software here, RV32I has no M -- and float
 * needs libgcc's soft-float routines for every add and multiply; the cycle
 * counts show what each costs. Only the arithmetic is timed, not the UART.
 *
 * Q12 is enough: inside the escape test |z| <= 2, and the pan and zoom
 * limits keep |Re c| < 3.2 and |Im c| < 2.2, so the next z's parts stay
 * under 11 (45056 in Q12) and every product under 2^31. Zooming in stops when
 * a pixel is one Q12 unit wide.
 *
 * Keys: w a s d pan, + - zoom, f fixed/float, r reset, q back.
 */
#include "demo.h"

#define W     76
#define H     22
#define MAXIT 32
#define Q     12

static const char palette[] = " .,'~:;!+=*%$&#@";   /* i >> 1, i < MAXIT */

static char fixed_px(int32_t cr, int32_t ci)
{
    int32_t zr = 0, zi = 0;
    for (int i = 0; i < MAXIT; i++) {
        int32_t zr2 = (zr * zr) >> Q;
        int32_t zi2 = (zi * zi) >> Q;
        if (zr2 + zi2 > (4 << Q))
            return palette[i >> 1];
        zi = ((zr * zi) >> (Q - 1)) + ci;
        zr = zr2 - zi2 + cr;
    }
    return '@';
}

static char float_px(float cr, float ci)
{
    float zr = 0.0f, zi = 0.0f;
    for (int i = 0; i < MAXIT; i++) {
        float zr2 = zr * zr;
        float zi2 = zi * zi;
        if (zr2 + zi2 > 4.0f)
            return palette[i >> 1];
        zi = (2.0f * zr) * zi + ci;
        zr = (zr2 - zi2) + cr;
    }
    return '@';
}

/* One frame into buf (H rows of W), returns the cycles spent computing. */
static uint32_t render(char *buf, int32_t cx, int32_t cy, int32_t step, int use_float)
{
    int32_t x0 = cx - (W / 2) * step;
    int32_t y0 = cy - (H / 2) * 2 * step;      /* a character is about twice as tall */
    uint32_t t = CYCLE;
    for (int r = 0; r < H; r++) {
        int32_t ci = y0 + r * 2 * step;
        for (int c = 0; c < W; c++) {
            int32_t cr = x0 + c * step;
            buf[r * W + c] = use_float
                ? float_px((float)cr * (1.0f / (1 << Q)), (float)ci * (1.0f / (1 << Q)))
                : fixed_px(cr, ci);
        }
    }
    return CYCLE - t;
}

void demo_mandel(void)
{
    char *buf = (char *)scratch;
    int32_t cx = -(3 << Q) / 4, cy = 0, step = (3 << Q) / W;   /* -0.75, 0, 3/W */
    int use_float = 0;
    puts_(CLS HIDE_CUR);
    for (;;) {
        uint32_t cycles = render(buf, cx, cy, step, use_float);
        puts_(HOME);
        for (int r = 0; r < H; r++) {
            for (int c = 0; c < W; c++)
                putc_(buf[r * W + c]);
            puts_("\r\n");
        }
        printf_("%s  step %d/4096  %u cycles (", use_float ? "software float " : "fixed point Q12",
                step, cycles);
        print_ms(cycles);
        puts_(")       \r\nwasd pan  + - zoom  f fixed/float  r reset  q back  ");

        int k = getc_();
        if (k == 'q')
            break;
        switch (k) {
        case 'w': cy -= 4 * step; break;
        case 's': cy += 4 * step; break;
        case 'a': cx -= 8 * step; break;
        case 'd': cx += 8 * step; break;
        case '+': case '=': if (step > 1) step >>= 1; break;
        case '-': if (step < 128) step <<= 1; break;
        case 'f': use_float = !use_float; break;
        case 'r': cx = -(3 << Q) / 4; cy = 0; step = (3 << Q) / W; use_float = 0; break;
        default: break;
        }
        /* Keep the view inside the bounds the Q12 note above relies on. */
        if (cx < -(2 << Q)) cx = -(2 << Q);
        if (cx > (1 << Q)) cx = 1 << Q;
        if (cy < -(3 << Q) / 2) cy = -(3 << Q) / 2;
        if (cy > (3 << Q) / 2) cy = (3 << Q) / 2;
    }
    puts_(SHOW_CUR);
}
