/* The tiny-LLM demo on the SoC (Phase H): stories260K (sw/llm/llm.h) from
 * the prompt "Once upon a time", greedy, twice: the matrix products on the
 * core (RV32IM software), then on the accelerator (gemm_run: DMA in, job,
 * DMA out). Everything else (norms, RoPE, attention, SiLU) is the core's
 * in both runs, so the two must give identical tokens and logits.
 *
 * Per position it prints
 *   llm: <sw|array> <pos> <next token> <CRC-32 of the logits> <cycles>
 * with the cycles of that forward pass alone (the CYCLE register, around
 * llm_forward), then the text and a total. tb/cocotb/test_llm.py and
 * scripts/llm_board_check.py compare the lines with the golden model's
 * vectors (llm_vectors.txt); the latter turns the cycles into tokens/s.
 *
 * Needs the LLM build: 384 KiB of RAM (make impl M=1 LLM=1). LLM_RUN_POS
 * positions per run (all LLM_SEQ - 1 by default; the simulation image runs
 * fewer).
 */
#include "gemm.h"
#include "io.h"
#include "llm.h"

#ifndef LLM_RUN_POS
#define LLM_RUN_POS (LLM_SEQ - 1)
#endif

#define RING_SIZE 8

static volatile struct dma_desc ring[RING_SIZE] __attribute__((aligned(DMAENG_RING_ALIGN)));
static struct dma dma;
static int32_t logits[LLM_VOCAB];
static int failed;

static void matmul_array(const int8_t *qa, const int8_t *w, int32_t *acc,
                         uint32_t k, uint32_t n)
{
    int rc = gemm_run(&dma, qa, w, acc, 1, k, n);
    if (rc != 0 && !failed) {
        printf_("llm: FAIL gemm_run %d (k %u, n %u)\r\n", rc, k, n);
        failed = 1;
    }
}

static void run(const char *name, llm_matmul_fn mm)
{
    static char text[1024];
    uint32_t tok = llm_prompt(0), prev, len, tl = 0, total = 0;

    llm_matmul = mm;
    llm_reset();
    for (uint32_t pos = 0; pos < LLM_RUN_POS; pos++) {
        uint32_t t0 = CYCLE;
        llm_forward(tok, pos, logits);
        uint32_t dt = CYCLE - t0;
        total += dt;
        prev = tok;
        tok = pos + 1 < LLM_PROMPT_LEN ? llm_prompt(pos + 1) : llm_argmax(logits);
        printf_("llm: %s %u %u %08x %u\r\n", name, pos, tok,
                llm_crc32(logits, sizeof logits), dt);
        const char *p = llm_piece(prev, tok, &len);
        for (uint32_t i = 0; i < len && tl + 1 < sizeof text; i++)
            text[tl++] = p[i] == '\n' ? '|' : p[i];      /* one line */
    }
    text[tl] = 0;
    printf_("llm: %s text: %s\r\n", name, text);
    printf_("llm: %s total %u positions %u cycles\r\n", name, LLM_RUN_POS, total);
}

int main(void)
{
    BUSERR = 0;
    if (dma_init(&dma, ring, RING_SIZE) != 0) {
        printf_("llm: FAIL no DMA engine\r\n");
        return 1;
    }
    printf_("llm: stories260K, %u layers, dim %u, vocab %u, context %u\r\n",
            LLM_N_LAYERS, LLM_DIM, LLM_VOCAB, LLM_SEQ);
    run("sw", llm_matmul_sw);
    run("array", matmul_array);
    if (BUSERR & 1u) {
        printf_("llm: FAIL bus error\r\n");
        failed = 1;
    }
    printf_("llm: done%s\r\n", failed ? ", FAILED" : "");
    return failed;
}
