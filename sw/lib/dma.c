/* See dma.h. */
#include <stddef.h>
#include "dma.h"

_Static_assert(sizeof(struct dma_desc) == DMAENG_DESC_SIZE, "descriptor size");
_Static_assert(offsetof(struct dma_desc, src_lo) == DMAENG_DESC_OFF_SRC, "src");
_Static_assert(offsetof(struct dma_desc, dst_lo) == DMAENG_DESC_OFF_DST, "dst");
_Static_assert(offsetof(struct dma_desc, len) == DMAENG_DESC_OFF_LEN, "len");
_Static_assert(offsetof(struct dma_desc, flags) == DMAENG_DESC_OFF_FLAGS, "flags");
_Static_assert(offsetof(struct dma_desc, status) == DMAENG_DESC_OFF_STATUS, "status");
_Static_assert(offsetof(struct dma_desc, rsvd) == DMAENG_DESC_OFF_RSVD, "rsvd");

int dma_init(struct dma *d, volatile struct dma_desc *ring, uint32_t size)
{
    if (DMA_REG(DMAENG_REG_ID) != DMAENG_ID_MAGIC)
        return -1;
    DMA_REG(DMAENG_REG_CTRL) = DMAENG_CTRL_RESET;     /* clears every register */
    for (uint32_t i = 0; i < size; i++)
        ring[i].flags = 0;
    d->ring = ring;
    d->size = size;
    d->tail = 0;
    /* _HI first, then _LO (DMA-Engine rule 3) */
    DMA_REG(DMAENG_REG_RING_BASE_HI) = 0;
    DMA_REG(DMAENG_REG_RING_BASE_LO) = (uint32_t)(uintptr_t)ring;
    DMA_REG(DMAENG_REG_RING_SIZE) = size;
    DMA_REG(DMAENG_REG_IRQ_MASK) = 0;                 /* no interrupts: polled */
    DMA_REG(DMAENG_REG_CTRL) = DMAENG_CTRL_ENABLE;
    return 0;
}

int dma_submit(struct dma *d, const void *src, void *dst, uint32_t len, uint32_t flags)
{
    uint32_t next = (d->tail + 1) & (d->size - 1);
    if (next == DMA_REG(DMAENG_REG_HEAD))
        return -1;                                     /* one slot stays empty */
    volatile struct dma_desc *e = &d->ring[d->tail];
    e->src_lo = (uint32_t)(uintptr_t)src;
    e->src_hi = 0;
    e->dst_lo = (uint32_t)(uintptr_t)dst;
    e->dst_hi = 0;
    e->len = len;
    e->status = 0;
    e->rsvd = 0;
    e->flags = flags | DMAENG_DESC_OWN;                /* last: hands it over */
    int slot = (int)d->tail;
    d->tail = next;
    return slot;
}

void dma_ring(struct dma *d)
{
    /* The descriptors are already in RAM: this core's stores complete in
     * order, and the doorbell is a store after them. */
    DMA_REG(DMAENG_REG_TAIL) = d->tail;
}

uint32_t dma_wait(struct dma *d, int slot)
{
    volatile struct dma_desc *e = &d->ring[slot];
    /* OWN clear means status is valid (rule 5). Each STATUS read waits on
     * the bus, which leaves the RAM port to the engine meanwhile. */
    while (e->flags & DMAENG_DESC_OWN) {
        if (DMA_REG(DMAENG_REG_STATUS) & DMAENG_STATUS_ERROR) {
            if (!(e->flags & DMAENG_DESC_OWN))
                break;                                 /* it was this one's */
            return DMA_STOPPED | DMA_REG(DMAENG_REG_ERR_CODE);
        }
    }
    return e->status;
}
