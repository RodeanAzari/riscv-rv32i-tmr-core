/* GEMM accelerator self-test: software on the core configures and launches
 * accelerator jobs (buildplan Phase G) through sw/lib/gemm.c, which moves
 * the matrices with the DMA, and checks every result against the core's own
 * matrix multiply. Run by tb/cocotb/test_gemm.py on the whole SoC, and on
 * the board through the bootloader.
 *
 *   1. probe: the accelerator idle, M reads back what was written
 *   2. shapes from 1x1x1 to several tiles each way, K and N on and off the
 *      16-lane edges: C exact, the job's cycles from CYCLES, the whole call's
 *      (DMA in, job, DMA out) and the core's own multiply, timed
 *   3. a shape the buffers cannot hold: refused, nothing run
 *
 * Prints a line per shape and a summary; the test reads "gemmtest: N/N ok",
 * each shape's job cycles (which must equal the golden model's), and the
 * last shape's matrix addresses, and checks that C in RAM itself.
 */
#include "gemm.h"
#include "io.h"

#define RING_SIZE 8
#define MAX_A     (24 * 40)
#define MAX_W     (40 * 24)
#define MAX_C     (24 * 24)

static volatile struct dma_desc ring[RING_SIZE] __attribute__((aligned(DMAENG_RING_ALIGN)));
static int8_t a[MAX_A], w[MAX_W];
static int32_t c[MAX_C], ref[MAX_C];
static struct dma dma;
static uint32_t passed, total;

static uint32_t lcg = 2026u;
static int8_t next_i8(void)
{
    lcg = lcg * 1103515245u + 12345u;
    return (int8_t)(lcg >> 16);
}

static void check(int ok, const char *what)
{
    total++;
    if (ok)
        passed++;
    else
        printf_("gemmtest: FAIL %s\r\n", what);
}

/* x * y for INT8 operands: shift and add over |y|'s 7 bits, much faster
 * than libgcc's general multiply on RV32I (no M extension) */
static int32_t mul8(int32_t x, int32_t y)
{
    int32_t neg = y < 0;
    uint32_t u = (uint32_t)(neg ? -y : y), acc = 0, s = (uint32_t)x;
    while (u) {
        if (u & 1u)
            acc += s;
        s <<= 1;
        u >>= 1;
    }
    return neg ? -(int32_t)acc : (int32_t)acc;
}

static void core_gemm(uint32_t m, uint32_t k, uint32_t n)
{
    for (uint32_t i = 0; i < m; i++)
        for (uint32_t j = 0; j < n; j++) {
            int32_t s = 0;
            for (uint32_t l = 0; l < k; l++)
                s += mul8(a[i * k + l], w[l * n + j]);
            ref[i * n + j] = s;
        }
}

static void one(uint32_t m, uint32_t k, uint32_t n)
{
    for (uint32_t i = 0; i < m * k; i++)
        a[i] = next_i8();
    for (uint32_t i = 0; i < k * n; i++)
        w[i] = next_i8();
    for (uint32_t i = 0; i < m * n; i++)
        c[i] = 0x5A5A5A5A;

    uint32_t t0 = CYCLE;
    int rc = gemm_run(&dma, a, w, c, m, k, n);
    uint32_t t_acc = CYCLE - t0;
    uint32_t job = GEMM_REG(GEMM_CYCLES);
    t0 = CYCLE;
    core_gemm(m, k, n);
    uint32_t t_core = CYCLE - t0;

    int ok = rc == 0;
    for (uint32_t i = 0; i < m * n; i++)
        ok &= c[i] == ref[i];
    check(ok, "result");
    printf_("gemmtest: %ux%ux%u %s, job %u cycles, call %u, core %u\r\n",
            m, k, n, ok ? "ok" : "WRONG", job, t_acc, t_core);
}

int main(void)
{
    BUSERR = 0;
    if (dma_init(&dma, ring, RING_SIZE) != 0) {
        printf_("gemmtest: no DMA engine\r\n");
        return 1;
    }
    check(GEMM_REG(GEMM_STATUS) == 0, "idle after reset");
    GEMM_REG(GEMM_M) = 0x1234u;
    check(GEMM_REG(GEMM_M) == 0x1234u, "M reads back");
    printf_("gemmtest: %ux%u array, %u-byte buffers, status 0x%x\r\n",
            GEMM_ROWS, GEMM_COLS, GEMM_BUF_BYTES, GEMM_REG(GEMM_STATUS));

    static const uint8_t shapes[][3] = {
        {1, 1, 1}, {16, 16, 16}, {5, 7, 9}, {3, 33, 17}, {2, 40, 3}, {24, 20, 24},
    };
    for (uint32_t i = 0; i < sizeof shapes / sizeof shapes[0]; i++)
        one(shapes[i][0], shapes[i][1], shapes[i][2]);
    printf_("gemmtest: last a 0x%x w 0x%x c 0x%x\r\n",
            (uint32_t)(uintptr_t)a, (uint32_t)(uintptr_t)w, (uint32_t)(uintptr_t)c);

    /* M = 1025 is over A's 1024 lines and C's 256 */
    check(!gemm_fits(1025, 1, 1), "driver refuses");
    GEMM_REG(GEMM_M) = 1025;
    GEMM_REG(GEMM_K) = 1;
    GEMM_REG(GEMM_N) = 1;
    GEMM_REG(GEMM_CTRL) = 1;
    while (GEMM_REG(GEMM_STATUS) & GEMM_ST_BUSY)
        ;
    check(GEMM_REG(GEMM_STATUS) == GEMM_ST_ERROR, "accelerator refuses");
    check(BUSERR == 0, "no bus errors");
    printf_("gemmtest: %u/%u ok\r\n", passed, total);
    return 0;
}
