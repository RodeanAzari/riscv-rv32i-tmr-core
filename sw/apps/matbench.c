/* Accelerator against software matmul on the same core (buildplan Phase H:
 * "benchmarked against software matmul on the same core, several matrix
 * sizes").
 *
 * For each shape, C = A @ W (INT8 in, INT32 out) three ways, each timed by
 * the core's cycle counter:
 *   sw    the core alone, the best plain C for the core it is built for:
 *         RV32I, an INT8 shift-add multiply (much faster than libgcc's
 *         general one); RV32IM (built with -march=rv32im), the mul
 *         instruction
 *   call  sw/lib/gemm.c: DMA A and W into the accelerator's buffers, run
 *         the job, DMA C back
 *   job   the accelerator's CYCLES register, the job alone
 * The two results must agree: one C buffer (an app has 28 KiB), so the
 * software result is hashed, then the accelerator's overwrites it and is
 * hashed, and the hashes compared ("ok" or "WRONG"). The accelerator's
 * results are checked against the golden model elsewhere (gemmtest).
 *
 * Prints "matbench: MxKxN ok, sw S, call C, job J, speedup X.Y / Z.W" (call,
 * then job, against sw) and a summary "matbench: N/N ok".
 */
#include "gemm.h"
#include "io.h"

#define RING_SIZE 8
#define MAX_A     (56 * 56)     /* largest shape: 56x56x56, or 128x16x16 */
#define MAX_W     (56 * 56)
#define MAX_C     (56 * 56)

static volatile struct dma_desc ring[RING_SIZE] __attribute__((aligned(DMAENG_RING_ALIGN)));
static int8_t a[MAX_A], w[MAX_W];
static int32_t c[MAX_C];
static struct dma dma;

static uint32_t lcg = 2026u;
static int8_t next_i8(void)
{
    lcg = lcg * 1103515245u + 12345u;
    return (int8_t)(lcg >> 16);
}

#ifdef __riscv_mul
#define MUL8(x, y) ((x) * (y))
#define SW_KIND    "rv32im mul"
#else
/* x * y for INT8 operands: shift and add over |y|'s 7 bits */
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
#define MUL8(x, y) mul8((x), (y))
#define SW_KIND    "rv32i shift-add"
#endif

static void sw_gemm(uint32_t m, uint32_t k, uint32_t n)
{
    for (uint32_t i = 0; i < m; i++)
        for (uint32_t j = 0; j < n; j++) {
            int32_t s = 0;
            for (uint32_t l = 0; l < k; l++)
                s += MUL8((int32_t)a[i * k + l], (int32_t)w[l * n + j]);
            c[i * n + j] = s;
        }
}

/* FNV-1a over the words of C */
static uint32_t hash_c(uint32_t words)
{
    uint32_t h = 2166136261u;
    for (uint32_t i = 0; i < words; i++) {
        h ^= (uint32_t)c[i];
        h *= 16777619u;
    }
    return h;
}

/* x / y to one decimal, as "I.F". 32-bit (a 64-bit division pulls libgcc's
 * .eh_frame, which the app link script does not place): exact while
 * x < 4e8, far above any time here. */
static void ratio(uint32_t x, uint32_t y)
{
    uint32_t t = (x * 10u + y / 2u) / y;
    printf_("%u.%u", t / 10u, t % 10u);
}

static uint32_t passed, total;

static void one(uint32_t m, uint32_t k, uint32_t n)
{
    for (uint32_t i = 0; i < m * k; i++)
        a[i] = next_i8();
    for (uint32_t i = 0; i < k * n; i++)
        w[i] = next_i8();

    uint32_t t0 = CYCLE;
    sw_gemm(m, k, n);
    uint32_t t_sw = CYCLE - t0;
    uint32_t h_sw = hash_c(m * n);

    for (uint32_t i = 0; i < m * n; i++)
        c[i] = 0x5A5A5A5A;
    t0 = CYCLE;
    int rc = gemm_run(&dma, a, w, c, m, k, n);
    uint32_t t_call = CYCLE - t0;
    uint32_t job = GEMM_REG(GEMM_CYCLES);

    int ok = rc == 0 && hash_c(m * n) == h_sw;
    total++;
    passed += (uint32_t)ok;
    printf_("matbench: %ux%ux%u %s, sw %u, call %u, job %u, speedup ",
            m, k, n, ok ? "ok" : "WRONG", t_sw, t_call, job);
    ratio(t_sw, t_call);
    printf_(" / ");
    ratio(t_sw, job);
    printf_("\r\n");
}

int main(void)
{
    BUSERR = 0;
    if (dma_init(&dma, ring, RING_SIZE) != 0) {
        printf_("matbench: no DMA engine\r\n");
        return 1;
    }
    printf_("matbench: %ux%u array, software %s\r\n", GEMM_ROWS, GEMM_COLS, SW_KIND);

    static const uint8_t shapes[][3] = {
        {8, 8, 8}, {16, 16, 16}, {32, 32, 32}, {48, 48, 48}, {56, 56, 56},
        {128, 16, 16}, {20, 50, 30},
    };
    for (uint32_t i = 0; i < sizeof shapes / sizeof shapes[0]; i++)
        one(shapes[i][0], shapes[i][1], shapes[i][2]);

    printf_("matbench: %u/%u ok\r\n", passed, total);
    return passed == total ? 0 : 1;
}
