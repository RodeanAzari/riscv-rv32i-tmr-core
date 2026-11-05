/* See gemm.h. */
#include <stddef.h>
#include "gemm.h"

static uint32_t ceil_div(uint32_t a, uint32_t b)
{
    return (a + b - 1) / b;
}

int gemm_fits(uint32_t m, uint32_t k, uint32_t n)
{
    uint32_t kt = ceil_div(k, GEMM_ROWS), nt = ceil_div(n, GEMM_COLS);
    return m && k && n && m <= 0xFFFFu && k <= 0xFFFFu && n <= 0xFFFFu
           && m * kt <= GEMM_BUF_BYTES / GEMM_ROWS
           && k * nt <= GEMM_BUF_BYTES / GEMM_COLS
           && m * nt <= GEMM_BUF_BYTES / (4u * GEMM_COLS);
}

/* rows copies of len bytes, src and dst each advancing by its own stride:
 * one descriptor if both are contiguous, else one a row, as many at a time
 * as the ring takes. */
static int copy_rows(struct dma *d, uintptr_t src, uint32_t sstride,
                     uintptr_t dst, uint32_t dstride, uint32_t len, uint32_t rows)
{
    if (sstride == len && dstride == len) {
        len *= rows;
        rows = 1;
    }
    uint32_t i = 0;
    while (i < rows) {
        int last = -1;
        while (i < rows) {
            int s = dma_submit(d, (const void *)src, (void *)dst, len,
                               i == rows - 1 ? DMAENG_DESC_LAST : 0);
            if (s < 0)
                break;                              /* ring full: drain it */
            last = s;
            src += sstride;
            dst += dstride;
            i++;
        }
        dma_ring(d);
        if (last < 0 || dma_wait(d, last) != DMAENG_ERR_OK)
            return GEMM_E_DMA;
    }
    return 0;
}

int gemm_run(struct dma *d, const int8_t *a, const int8_t *w, int32_t *c,
             uint32_t m, uint32_t k, uint32_t n)
{
    uint32_t ka = ceil_div(k, GEMM_ROWS) * GEMM_ROWS;   /* A's line stride */
    uint32_t nw = ceil_div(n, GEMM_COLS) * GEMM_COLS;   /* W's and C's */

    if (copy_rows(d, (uintptr_t)a, k, GEMM_A, ka, k, m) ||
        copy_rows(d, (uintptr_t)w, n, GEMM_W, nw, n, k))
        return GEMM_E_DMA;

    GEMM_REG(GEMM_M) = m;
    GEMM_REG(GEMM_K) = k;
    GEMM_REG(GEMM_N) = n;
    GEMM_REG(GEMM_CTRL) = 1u;
    uint32_t st;
    while ((st = GEMM_REG(GEMM_STATUS)) & GEMM_ST_BUSY)
        ;
    if (!(st & GEMM_ST_DONE))
        return GEMM_E_SHAPE;

    return copy_rows(d, GEMM_C, 4u * nw, (uintptr_t)c, 4u * n, 4u * n, m) ? GEMM_E_DMA : 0;
}
