/* Bare-metal driver for the SoC's GEMM accelerator (rtl/accel/gemm_accel.sv).
 *
 * C = A @ W with A (M x K) and W (K x N) INT8, C INT32, all row-major and
 * dense in RAM. gemm_run() moves A and W into the accelerator's buffers with
 * the DMA (sw/lib/dma.h), one descriptor per row when the buffer's padded
 * row differs from the matrix's, runs the job, waits, and moves C back.
 * Requantization to INT8 is software's for now.
 *
 * Buffer layout and registers: sw/model/accel_model.py, the golden model.
 * Each matrix's rows are padded to whole lines there (A to GEMM_ROWS bytes,
 * W to GEMM_COLS bytes, C to GEMM_COLS words); the padding needs no
 * clearing.
 */
#ifndef GEMM_H
#define GEMM_H

#include <stdint.h>
#include "dma.h"
#include "soc.h"

#define GEMM_ROWS      16u
#define GEMM_COLS      16u
#define GEMM_BUF_BYTES 16384u
#define GEMM_A         (GEMM_BUF)
#define GEMM_W         (GEMM_BUF + GEMM_BUF_BYTES)
#define GEMM_C         (GEMM_BUF + 2u * GEMM_BUF_BYTES)

#define GEMM_REG(off)  REG(GEMM_BASE + (off))
#define GEMM_CTRL      0x00u           /* W: bit 0 START */
#define GEMM_STATUS    0x04u           /* R: the bits below */
#define GEMM_M         0x08u
#define GEMM_K         0x0Cu
#define GEMM_N         0x10u
#define GEMM_CYCLES    0x14u           /* R: busy cycles of the last job */

#define GEMM_ST_BUSY   1u
#define GEMM_ST_DONE   2u
#define GEMM_ST_ERROR  4u              /* the shape did not fit: nothing ran */

/* gemm_run's results, besides 0 */
#define GEMM_E_SHAPE   1               /* refused by the accelerator */
#define GEMM_E_DMA     2               /* a copy failed */

/* Whether the shape fits the buffers (the accelerator's own check). */
int gemm_fits(uint32_t m, uint32_t k, uint32_t n);

/* C = A @ W. 0, or GEMM_E_*. The DMA must be initialised (dma_init). */
int gemm_run(struct dma *d, const int8_t *a, const int8_t *w, int32_t *c,
             uint32_t m, uint32_t k, uint32_t n);

#endif /* GEMM_H */
