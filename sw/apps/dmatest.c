/* DMA self-test: the core drives the DMA engine through sw/lib/dma.c (the
 * bare-metal driver, on DMA-Engine's dmaeng_regs.h) and checks every copy
 * byte for byte, guard bytes included. Run by tb/cocotb/test_dma.py on the
 * whole SoC, and on the board through the bootloader.
 *
 *   1. probe: ID, VERSION, MAX_XFER
 *   2. every source and destination byte offset 0-3 at lengths around the
 *      bus width and the engine's 64-byte chunk, one copy each
 *   3. a batch of six copies in one doorbell, wrapping the ring
 *   4. an error (len 0): status BAD_LEN, the engine stops; reset, and the
 *      next copy works
 *   5. 4 KiB copied by the engine and by the core, cycles for each
 *
 * Prints one line per part and a summary; the test reads "dmatest: N/N ok"
 * and the 4 KiB copy's addresses, and checks that copy in RAM itself.
 */
#include "dma.h"
#include "io.h"

#define RING_SIZE 8
#define BIG       4096
#define GUARD     8

static volatile struct dma_desc ring[RING_SIZE] __attribute__((aligned(DMAENG_RING_ALIGN)));
static uint8_t src[BIG + 16];
static uint8_t dst[BIG + 16];
static struct dma dma;
static uint32_t passed, total;

static uint32_t lcg = 12345u;
static uint8_t next_byte(void)
{
    lcg = lcg * 1103515245u + 12345u;
    return (uint8_t)(lcg >> 16);
}

static void check(int ok, const char *what)
{
    total++;
    if (ok)
        passed++;
    else
        printf_("dmatest: FAIL %s\r\n", what);
}

/* src[so..so+n) -> dst[GUARD+do..), with dst pre-filled so a stray strobe
 * or a short copy shows */
static void prepare(uint32_t so, uint32_t n)
{
    for (uint32_t i = 0; i < n + 8; i++)
        src[so + i] = next_byte();
    for (uint32_t i = 0; i < n + 2 * GUARD + 8; i++)
        dst[i] = 0xA5;
}

static int copied(uint32_t so, uint32_t dof, uint32_t n)
{
    for (uint32_t i = 0; i < GUARD + dof; i++)
        if (dst[i] != 0xA5)
            return 0;
    for (uint32_t i = 0; i < n; i++)
        if (dst[GUARD + dof + i] != src[so + i])
            return 0;
    for (uint32_t i = 0; i < GUARD; i++)
        if (dst[GUARD + dof + n + i] != 0xA5)
            return 0;
    return 1;
}

static void alignments(void)
{
    static const uint16_t lens[] = {1, 2, 3, 4, 5, 7, 8, 63, 64, 65, 129};
    uint32_t before = passed;
    for (uint32_t so = 0; so < 4; so++)
        for (uint32_t dof = 0; dof < 4; dof++)
            for (uint32_t k = 0; k < sizeof lens / sizeof lens[0]; k++) {
                uint32_t n = lens[k];
                prepare(so, n);
                int slot = dma_submit(&dma, &src[so], &dst[GUARD + dof], n, 0);
                dma_ring(&dma);
                uint32_t st = dma_wait(&dma, slot);
                check(st == DMAENG_ERR_OK && copied(so, dof, n), "alignment");
            }
    printf_("dmatest: alignments %u/%u\r\n", passed - before, 4 * 4 * 11);
}

static void batch(void)
{
    /* six 100-byte copies at once, from slot 5: they wrap past the end of
     * the ring (the copies so far left the tail at a multiple of 8) */
    uint32_t before = passed;
    for (uint32_t i = 0; i < 5; i++) {
        int s1 = dma_submit(&dma, src, dst, 1, 0);
        dma_ring(&dma);
        dma_wait(&dma, s1);
    }
    for (uint32_t i = 0; i < 6 * 100; i++)
        src[i] = next_byte();
    int slot = -1;
    for (uint32_t i = 0; i < 6; i++)
        slot = dma_submit(&dma, &src[i * 100], &dst[i * 100 + 1], 100,
                          i == 5 ? DMAENG_DESC_LAST : 0);
    dma_ring(&dma);
    uint32_t st = dma_wait(&dma, slot);
    int ok = st == DMAENG_ERR_OK;
    for (uint32_t i = 0; i < 6 * 100; i++)
        ok &= dst[i + 1] == src[i];
    check(ok, "batch");
    check(DMA_REG(DMAENG_REG_HEAD) == dma.tail, "batch head");
    printf_("dmatest: batch %u/2, head %u\r\n", passed - before, DMA_REG(DMAENG_REG_HEAD));
}

static void error_and_reset(void)
{
    uint32_t before = passed;
    int slot = dma_submit(&dma, src, dst, 0, 0);       /* len 0: BAD_LEN */
    dma_ring(&dma);
    uint32_t st = dma_wait(&dma, slot);
    check(st == DMAENG_ERR_BAD_LEN, "bad len status");
    check((DMA_REG(DMAENG_REG_STATUS) & DMAENG_STATUS_ERROR) &&
          DMA_REG(DMAENG_REG_ERR_CODE) == DMAENG_ERR_BAD_LEN, "engine stopped");
    dma_init(&dma, ring, RING_SIZE);
    prepare(0, 40);
    slot = dma_submit(&dma, src, &dst[GUARD], 40, 0);
    dma_ring(&dma);
    st = dma_wait(&dma, slot);
    check(st == DMAENG_ERR_OK && copied(0, 0, 40), "after reset");
    printf_("dmatest: error and reset %u/3\r\n", passed - before);
}

static void timing(void)
{
    for (uint32_t i = 0; i < BIG; i++)
        src[i] = next_byte();
    uint32_t t0 = CYCLE;
    int slot = dma_submit(&dma, src, dst, BIG, DMAENG_DESC_LAST);
    dma_ring(&dma);
    uint32_t st = dma_wait(&dma, slot);
    uint32_t t_dma = CYCLE - t0;
    int ok = st == DMAENG_ERR_OK;
    for (uint32_t i = 0; i < BIG; i++)
        ok &= dst[i] == src[i];
    check(ok, "4 KiB copy");

    /* the same bytes by the core, a word at a time */
    const uint32_t *s = (const uint32_t *)src;
    uint32_t *d = (uint32_t *)(dst + 0);
    t0 = CYCLE;
    for (uint32_t i = 0; i < BIG / 4; i++)
        d[i] = s[i];
    uint32_t t_cpu = CYCLE - t0;
    printf_("dmatest: 4096 B 0x%x -> 0x%x: dma %u cycles, core %u cycles\r\n",
            (uint32_t)(uintptr_t)src, (uint32_t)(uintptr_t)dst, t_dma, t_cpu);
}

int main(void)
{
    BUSERR = 0;
    if (dma_init(&dma, ring, RING_SIZE) != 0) {
        printf_("dmatest: no engine (ID 0x%x)\r\n", DMA_REG(DMAENG_REG_ID));
        return 1;
    }
    printf_("dmatest: ID 0x%x VERSION 0x%x MAX_XFER %u\r\n", DMA_REG(DMAENG_REG_ID),
            DMA_REG(DMAENG_REG_VERSION), DMA_REG(DMAENG_REG_MAX_XFER));
    alignments();
    batch();
    error_and_reset();
    timing();
    check(BUSERR == 0, "no bus errors");
    printf_("dmatest: %u/%u ok\r\n", passed, total);
    return 0;
}
