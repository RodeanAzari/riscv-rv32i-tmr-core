/* The inference code (llm.c) built natively, against the golden model's
 * llm_vectors.txt (`make llm-host` diffs the two):
 *   - greedy decoding from the prompt, one line per position: position,
 *     next token, CRC-32 of the logits; the text goes to stderr
 *   - each kernel's CRC-32 over the sweep kernel_crcs() in llm_model.py
 *     describes, which reaches rounding cases one trace never meets
 * llm.c is included, not linked, so its static kernels can be called. */
#include <stdio.h>
#include "llm.c"

static uint32_t crc_u32(uint32_t crc, uint32_t v)    /* running zlib CRC */
{
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    crc = ~crc;
    for (int k = 0; k < 4; k++) {
        crc ^= b[k];
        for (int i = 0; i < 8; i++)
            crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
    }
    return ~crc;
}

int main(void)
{
    static int32_t logits[LLM_VOCAB];
    static char text[4096];
    uint32_t tok = llm_prompt(0), prev, len, tl = 0;

    llm_reset();
    for (uint32_t pos = 0; pos + 1 < LLM_SEQ; pos++) {
        llm_forward(tok, pos, logits);
        prev = tok;
        tok = pos + 1 < LLM_PROMPT_LEN ? llm_prompt(pos + 1) : llm_argmax(logits);
        printf("%u %u %08x\n", pos, tok, llm_crc32(logits, sizeof logits));
        const char *p = llm_piece(prev, tok, &len);
        for (uint32_t i = 0; i < len && tl + 1 < sizeof text; i++)
            text[tl++] = p[i];
    }
    text[tl] = 0;
    fprintf(stderr, "%s\n", text);

    uint32_t c = 0;
    for (int32_t d = 0; d < (17 << 16); d++)
        c = crc_u32(c, (uint32_t)exp_neg(d));
    printf("kernel exp_neg %08x\n", c);
    c = 0;
    for (int32_t hv = -(20 << 16); hv < (20 << 16); hv++) {
        uint32_t e = (uint32_t)exp_neg(hv < 0 ? -hv : hv);
        c = crc_u32(c, hv >= 0 ? (1u << 31) / (65536u + e) : (e << 15) / (65536u + e));
    }
    printf("kernel sigmoid %08x\n", c);
    c = 0;
    uint64_t x = 0x9E3779B97F4A7C15ull;
    for (int i = 0; i < 100000; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        c = crc_u32(c, isqrt64(x >> (i % 64)));
    }
    printf("kernel isqrt %08x\n", c);
    return 0;
}
