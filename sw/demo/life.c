/* Conway's Game of Life on a wrapping 76 x 21 board, redrawn in place.
 *
 * The LEDs show the generation's low 4 bits. The cycle count is the
 * computation of one generation; drawing is limited by the UART (about 1700
 * characters a frame at 115200 baud, some 7 frames a second).
 *
 * Keys: space pause/run, n one step, r random, g Gosper glider gun,
 * c clear, q back.
 */
#include "demo.h"

#define W 76
#define H 21

static uint8_t *cur, *nxt;

static void randomize(void)
{
    for (int i = 0; i < W * H; i++)
        cur[i] = (rand32() & 3u) == 0;       /* one cell in four */
}

static void clear(void)
{
    for (int i = 0; i < W * H; i++)
        cur[i] = 0;
}

static void gun(void)
{
    static const char *const g[] = {
        "........................O...........",
        "......................O.O...........",
        "............OO......OO............OO",
        "...........O...O....OO............OO",
        "OO........O.....O...OO..............",
        "OO........O...O.OO....O.O...........",
        "..........O.....O.......O...........",
        "...........O...O....................",
        "............OO......................",
    };
    clear();
    for (int r = 0; r < 9; r++)
        for (int c = 0; g[r][c]; c++)
            cur[(r + 2) * W + c + 2] = g[r][c] == 'O';
}

static uint32_t step(void)
{
    uint32_t t = CYCLE;
    for (int r = 0; r < H; r++) {
        int up = (r == 0 ? H - 1 : r - 1) * W, mid = r * W, dn = (r == H - 1 ? 0 : r + 1) * W;
        for (int c = 0; c < W; c++) {
            int l = c == 0 ? W - 1 : c - 1, rr = c == W - 1 ? 0 : c + 1;
            int n = cur[up + l] + cur[up + c] + cur[up + rr] + cur[mid + l] + cur[mid + rr]
                  + cur[dn + l] + cur[dn + c] + cur[dn + rr];
            nxt[mid + c] = n == 3 || (n == 2 && cur[mid + c]);
        }
    }
    uint8_t *swap = cur;
    cur = nxt;
    nxt = swap;
    return CYCLE - t;
}

void demo_life(void)
{
    cur = (uint8_t *)scratch;
    nxt = cur + W * H;
    gun();
    uint32_t gen = 0, cycles = 0;
    int running = 1;
    puts_(CLS HIDE_CUR);
    for (;;) {
        unsigned pop = 0;
        puts_(HOME);
        for (int r = 0; r < H; r++) {
            for (int c = 0; c < W; c++) {
                putc_(cur[r * W + c] ? 'O' : ' ');
                pop += cur[r * W + c];
            }
            puts_("|\r\n");
        }
        LED = gen & 15u;
        printf_("generation %u  population %u  %u cycles/generation  %s   \r\n"
                "space pause/run  n step  r random  g glider gun  c clear  q back ",
                gen, pop, cycles, running ? "running" : "paused ");

        int k = running ? try_getc() : getc_();
        if (k == 'q')
            break;
        if (k == ' ')
            running = !running;
        else if (k == 'r')
            randomize(), gen = 0;
        else if (k == 'g')
            gun(), gen = 0;
        else if (k == 'c')
            clear(), gen = 0;
        if (running || k == 'n') {
            cycles = step();
            gen++;
        }
    }
    LED = 0;
    puts_(SHOW_CUR);
}
