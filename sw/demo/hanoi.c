/* Tower of Hanoi, solved recursively and drawn move by move.
 *
 * n disks take 2^n - 1 moves. Keys while it runs: 1-5 speed (5: no delay),
 * space pause, q back.
 */
#include "demo.h"

#define MAXD 8

static int peg[3][MAXD], height[3], ndisks, speed, quit;
static uint32_t moves;

static void draw(void)
{
    puts_(HOME "\r\n");
    for (int level = ndisks - 1; level >= 0; level--) {
        for (int p = 0; p < 3; p++) {
            int d = level < height[p] ? peg[p][level] : 0;
            int pad = d ? MAXD + 1 - d : MAXD;    /* 17 columns either way */
            puts_("  ");
            for (int i = 0; i < pad; i++)
                putc_(' ');
            if (d) {
                for (int i = 0; i < 2 * d - 1; i++)
                    putc_('=');
            } else {
                putc_('|');
            }
            for (int i = 0; i < pad; i++)
                putc_(' ');
        }
        puts_("\r\n");
    }
    puts_("  -----------------  -----------------  -----------------\r\n");
    puts_("          A                  B                  C\r\n\r\n");
    printf_("  moves %u of %u   speed %d   1-5 speed  space pause  q back   \r\n",
            moves, (1u << ndisks) - 1u, speed);
}

static void pace(void)
{
    static const uint32_t delay_ms[] = {0, 600, 300, 120, 40, 0};
    uint32_t start = CYCLE;
    for (;;) {
        int k = try_getc();
        if (k == 'q')
            quit = 1;
        else if (k >= '1' && k <= '5')
            speed = k - '0';
        else if (k == ' ')
            while ((k = getc_()) != ' ' && k != 'q')
                ;
        if (k == 'q')
            quit = 1;
        /* Re-read the speed each time round, so a new one applies at once. */
        if (quit || CYCLE - start >= delay_ms[speed] * (CLK_HZ / 1000u))
            return;
    }
}

static void move(int n, int from, int to, int via)
{
    if (n == 0 || quit)
        return;
    move(n - 1, from, via, to);
    if (quit)
        return;
    peg[to][height[to]++] = peg[from][--height[from]];
    moves++;
    draw();
    pace();
    move(n - 1, via, to, from);
}

void demo_hanoi(void)
{
    puts_("Tower of Hanoi\r\n\r\n");
    ndisks = read_number("how many disks", 1, MAXD, 5);
    speed = 3;
    quit = 0;
    moves = 0;
    height[0] = ndisks;
    height[1] = height[2] = 0;
    for (int i = 0; i < ndisks; i++)
        peg[0][i] = ndisks - i;
    puts_(CLS HIDE_CUR);
    draw();
    pace();
    move(ndisks, 0, 2, 1);
    puts_(SHOW_CUR);
    if (!quit)
        printf_("\r\n  solved: %u moves, 2^%d - 1 = %u\r\n", moves, ndisks, (1u << ndisks) - 1u);
    wait_key();
}
