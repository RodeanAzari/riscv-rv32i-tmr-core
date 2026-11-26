/* Tiny-LLM inference, integer only (Phase H demo): llama2.c's stories260K.
 *
 * Bit-exact with its golden model, sw/model/llm_model.py (IntModel), whose
 * header lists every fixed-point format; this file and llm.c follow it line
 * by line. Portable C: the same source runs on the core (sw/llm/llm_app.c) and
 * natively (sw/llm/llm_host.c, `make llm-host`), which checks it against the
 * model's vectors.
 *
 * The weights are one blob (llm_blob.bin, from `llm_model.py export`),
 * linked in by llm_blob.S; llm_blob.h, generated with it, holds the sizes
 * and offsets.
 */
#ifndef LLM_H
#define LLM_H

#include <stdint.h>
#include "llm_blob.h"

/* One dense INT8 product, acc[0..n) = qa[0..k) @ w (k x n, row-major).
 * llm_matmul_sw is the core's own; the firmware can point llm_matmul at
 * the accelerator instead. */
typedef void (*llm_matmul_fn)(const int8_t *qa, const int8_t *w, int32_t *acc,
                              uint32_t k, uint32_t n);
extern llm_matmul_fn llm_matmul;
void llm_matmul_sw(const int8_t *qa, const int8_t *w, int32_t *acc,
                   uint32_t k, uint32_t n);

extern const uint8_t llm_blob[];

/* Forget every position (the KV cache). */
void llm_reset(void);

/* Logits (Q16) of the token after `tok` at position `pos` < LLM_SEQ. */
void llm_forward(uint32_t tok, uint32_t pos, int32_t *logits);

/* The first index of the largest logit. */
uint32_t llm_argmax(const int32_t *logits);

/* Token `tok`'s text and its length, following token `prev` (a leading
 * space is dropped after BOS, as llama2.c does). */
const char *llm_piece(uint32_t prev, uint32_t tok, uint32_t *len);

/* The prompt's tokens (LLM_PROMPT_LEN, BOS first). */
uint32_t llm_prompt(uint32_t i);

/* zlib's CRC-32 of n bytes. */
uint32_t llm_crc32(const void *p, uint32_t n);

#endif /* LLM_H */
