/* Bare-metal driver for the SoC's DMA engine (rtl/bus/dmaeng.sv).
 *
 * The register map, descriptor layout and codes are DMA-Engine's
 * (https://github.com/RodeanAzari/DMA-Engine), from its generated header
 * include/dmaeng_regs.h (submodule sw/dma-engine/), the same header its
 * Linux driver uses; nothing here retypes an offset. This is the bare-metal
 * counterpart of that driver (DMA-Engine 14.4, "Arty A7"): no interrupts, so
 * completion is polled, and 32-bit addresses (the _HI words are 0).
 *
 * Usage: dma_init() once with a 4 KiB-aligned ring, then dma_submit() as
 * many copies as the ring holds and dma_ring() to start them, then
 * dma_wait() on the last one (they complete in order). A copy is complete
 * only once dma_wait() returns: the engine runs alongside the core.
 */
#ifndef DMA_H
#define DMA_H

#include <stdint.h>
#include "dmaeng_regs.h"
#include "soc.h"

#define DMA_REG(off) REG(DMA_BASE + (off))

struct dma_desc {
    uint32_t src_lo, src_hi, dst_lo, dst_hi, len, flags, status, rsvd;
};

struct dma {
    volatile struct dma_desc *ring;
    uint32_t size;                    /* descriptors, a power of two */
    uint32_t tail;                    /* the next slot to fill */
};

/* Reset the engine and program the ring. 0, or -1 if no engine answers. */
int dma_init(struct dma *d, volatile struct dma_desc *ring, uint32_t size);

/* Fill the next slot (OWN set last); returns it, or -1 if the ring is full.
 * flags: DMAENG_DESC_IRQ / DMAENG_DESC_LAST as wanted (OWN is added). */
int dma_submit(struct dma *d, const void *src, void *dst, uint32_t len, uint32_t flags);

/* Ring the doorbell: the engine takes everything submitted so far. */
void dma_ring(struct dma *d);

/* Wait for a slot's descriptor. Its status (DMAENG_ERR_*), or, if the
 * engine stopped before taking it, DMA_STOPPED | ERR_CODE. */
#define DMA_STOPPED 0x100u
uint32_t dma_wait(struct dma *d, int slot);

#endif /* DMA_H */
