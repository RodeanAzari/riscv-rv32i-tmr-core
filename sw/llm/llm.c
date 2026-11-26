/* Tiny-LLM inference, integer only: see llm.h. Every step mirrors
 * IntModel in sw/model/llm_model.py; the comment there gives each format.
 * Shifts of signed values are arithmetic (GCC on both targets), and every
 * division has non-negative operands. */
#include "llm.h"

#define L    LLM_N_LAYERS
#define DIM  LLM_DIM
#define HID  LLM_HIDDEN
#define KVD  LLM_KV_DIM
#define HS   LLM_HEAD_SIZE

llm_matmul_fn llm_matmul = llm_matmul_sw;

static int16_t kc[L][LLM_SEQ][KVD], vc[L][LLM_SEQ][KVD];

#define BLOB(type, off) ((const type *)(llm_blob + (off)))

static inline int64_t rsh(int64_t v, int s)
{
    return (v + ((int64_t)1 << (s - 1))) >> s;
}

void llm_matmul_sw(const int8_t *qa, const int8_t *w, int32_t *acc,
                   uint32_t k, uint32_t n)
{
    for (uint32_t j = 0; j < n; j++)
        acc[j] = 0;
    for (uint32_t i = 0; i < k; i++) {
        int32_t a = qa[i];
        const int8_t *row = w + i * n;
        if (a == 0)
            continue;
        for (uint32_t j = 0; j < n; j++)
            acc[j] += a * row[j];
    }
}

/* y[0..n) = W x through INT8: quantize x, the products block by block,
 * then each column's rescale. */
static void matvec(int32_t *y, const int32_t *x, const struct llm_mat *mt)
{
    static int8_t qa[HID > DIM ? HID : DIM];
    static int32_t acc[LLM_VOCAB];
    uint32_t k = mt->k, n = mt->n, nb = mt->nb;
    int32_t amax = 0;

    for (uint32_t i = 0; i < k; i++) {
        int32_t a = x[i] < 0 ? -x[i] : x[i];
        if (a > amax)
            amax = a;
    }
    if (amax == 0) {
        for (uint32_t j = 0; j < n; j++)
            y[j] = 0;
        return;
    }
    int64_t r = (int64_t)(((uint64_t)127 << 32) / (uint32_t)amax);
    for (uint32_t i = 0; i < k; i++) {
        int64_t q = rsh(x[i] * r, 32);
        qa[i] = (int8_t)(q > 127 ? 127 : q < -127 ? -127 : q);
    }
    for (uint32_t n0 = 0; n0 < n; n0 += nb) {
        uint32_t w = n - n0 < nb ? n - n0 : nb;
        llm_matmul(qa, BLOB(int8_t, mt->w + n0 * k), acc + n0, k, w);
    }
    const int32_t *m = BLOB(int32_t, mt->m);
    for (uint32_t j = 0; j < n; j++) {
        int64_t t = rsh((int64_t)acc[j] * m[j], 24);
        y[j] = (int32_t)rsh(t * amax, 16);
    }
}

static uint32_t isqrt64(uint64_t v)
{
    uint64_t r = 0, bit = (uint64_t)1 << 62;
    while (bit > v)
        bit >>= 2;
    while (bit) {
        if (v >= r + bit) {
            v -= r + bit;
            r = (r >> 1) + bit;
        } else {
            r >>= 1;
        }
        bit >>= 2;
    }
    return (uint32_t)r;
}

static void rmsnorm(int32_t *y, const int32_t *x, const int32_t *g)
{
    int64_t ss = 0;
    for (int i = 0; i < DIM; i++)
        ss += (int64_t)x[i] * x[i];
    uint32_t s = isqrt64((uint64_t)(ss / DIM + LLM_EPS_Q32));
    int64_t inv = (int64_t)(((uint64_t)1 << 46) / s);
    for (int i = 0; i < DIM; i++)
        y[i] = (int32_t)rsh(rsh((int64_t)x[i] * g[i], 16) * inv, 30);
}

static void rope(int32_t *v, uint32_t pos, int n)
{
    const int32_t *co = BLOB(int32_t, LLM_OFF_ROPE_COS) + pos * (HS / 2);
    const int32_t *si = BLOB(int32_t, LLM_OFF_ROPE_SIN) + pos * (HS / 2);
    for (int i = 0; i < n; i += 2) {
        int f = (i % HS) / 2;
        int64_t a = v[i], b = v[i + 1];
        v[i]     = (int32_t)rsh(a * co[f] - b * si[f], 30);
        v[i + 1] = (int32_t)rsh(a * si[f] + b * co[f], 30);
    }
}

static int32_t exp_neg(int32_t d)        /* exp(-d), d >= 0, Q16 */
{
    const int32_t *lut = BLOB(int32_t, LLM_OFF_EXP2_LUT);
    if (d >= (16 << 16))
        return 0;
    int64_t t = rsh((int64_t)d * LLM_LOG2E_Q16, 16);
    int n = (int)(t >> 16);
    int f = (int)(t & 0xFFFF), idx = f >> 8, frac = f & 0xFF;
    int64_t v = lut[idx] + ((((int64_t)lut[idx + 1] - lut[idx]) * frac + 128) >> 8);
    return (int32_t)((v + ((int64_t)1 << (n + 13))) >> (n + 14));
}

static int16_t store16(int32_t v, int s)
{
    int64_t r = rsh(v, s);
    return (int16_t)(r > 32767 ? 32767 : r < -32768 ? -32768 : r);
}

void llm_reset(void)
{
    for (int l = 0; l < L; l++)
        for (int p = 0; p < LLM_SEQ; p++)
            for (int i = 0; i < KVD; i++)
                kc[l][p][i] = vc[l][p][i] = 0;
}

void llm_forward(uint32_t tok, uint32_t pos, int32_t *logits)
{
    static int32_t x[DIM], xb[DIM], q[DIM], k[KVD], v[KVD], out[DIM], y[DIM];
    static int32_t h1[HID], h3[HID];
    static int32_t sc[LLM_SEQ];
    const struct llm_mat *emb = &llm_mats[L * LLM_N_MATS];

    /* the embedding: token tok's column of the classifier, rescaled */
    {
        uint32_t n0 = tok / emb->nb * emb->nb;
        uint32_t w = emb->n - n0 < emb->nb ? emb->n - n0 : emb->nb;
        const int8_t *blk = BLOB(int8_t, emb->w + n0 * emb->k);
        int32_t e = BLOB(int32_t, LLM_OFF_EMB_E)[tok];
        for (int i = 0; i < DIM; i++)
            x[i] = (int32_t)rsh((int64_t)blk[i * w + (tok - n0)] * e, 8);
    }

    for (int l = 0; l < L; l++) {
        const struct llm_mat *mt = &llm_mats[l * LLM_N_MATS];
        rmsnorm(xb, x, BLOB(int32_t, LLM_OFF_RMS_ATT) + l * DIM);
        matvec(q, xb, &mt[LLM_WQ]);
        matvec(k, xb, &mt[LLM_WK]);
        matvec(v, xb, &mt[LLM_WV]);
        rope(q, pos, DIM);
        rope(k, pos, KVD);
        for (int i = 0; i < KVD; i++) {
            kc[l][pos][i] = store16(k[i], LLM_K_SHIFT);
            vc[l][pos][i] = store16(v[i], LLM_V_SHIFT);
        }

        for (int h = 0; h < LLM_N_HEADS; h++) {
            int kh = h / (LLM_N_HEADS / LLM_N_KV_HEADS) * HS;
            const int32_t *qh = q + h * HS;
            int32_t mx = 0;
            for (uint32_t t = 0; t <= pos; t++) {
                int64_t dot = 0;
                for (int i = 0; i < HS; i++)
                    dot += (int64_t)qh[i] * kc[l][t][kh + i];
                sc[t] = (int32_t)rsh(dot * LLM_SCORE_C, 25);
                if (t == 0 || sc[t] > mx)
                    mx = sc[t];
            }
            int32_t sum = 0;
            for (uint32_t t = 0; t <= pos; t++) {
                sc[t] = exp_neg(mx - sc[t]);
                sum += sc[t];
            }
            int64_t inv = (int64_t)(((uint64_t)1 << 40) / (uint32_t)sum);
            for (int i = 0; i < HS; i++) {
                int64_t acc = 0;
                for (uint32_t t = 0; t <= pos; t++)
                    acc += rsh(sc[t] * inv, 24) * vc[l][t][kh + i];
                out[h * HS + i] = (int32_t)rsh(acc, 11);
            }
        }
        matvec(y, out, &mt[LLM_WO]);
        for (int i = 0; i < DIM; i++)
            x[i] += y[i];

        rmsnorm(xb, x, BLOB(int32_t, LLM_OFF_RMS_FFN) + l * DIM);
        matvec(h1, xb, &mt[LLM_W1]);
        matvec(h3, xb, &mt[LLM_W3]);
        for (int i = 0; i < HID; i++) {
            int32_t hv = h1[i];
            uint32_t e = (uint32_t)exp_neg(hv < 0 ? -hv : hv);
            uint32_t sig = hv >= 0 ? (1u << 31) / (65536u + e)
                                   : (e << 15) / (65536u + e);
            h1[i] = (int32_t)rsh(rsh((int64_t)hv * sig, 15) * h3[i], 16);
        }
        matvec(y, h1, &mt[LLM_W2]);
        for (int i = 0; i < DIM; i++)
            x[i] += y[i];
    }
    rmsnorm(xb, x, BLOB(int32_t, LLM_OFF_RMS_FINAL));
    matvec(logits, xb, emb);
}

uint32_t llm_argmax(const int32_t *logits)
{
    uint32_t best = 0;
    for (uint32_t i = 1; i < LLM_VOCAB; i++)
        if (logits[i] > logits[best])
            best = i;
    return best;
}

const char *llm_piece(uint32_t prev, uint32_t tok, uint32_t *len)
{
    const uint16_t *offs = BLOB(uint16_t, LLM_OFF_VOCAB_OFFS);
    const char *p = (const char *)llm_blob + LLM_OFF_VOCAB_TEXT + offs[tok];
    *len = offs[tok + 1] - offs[tok];
    if (*len == 6 && p[0] == '<' && p[1] == '0' && p[2] == 'x' && p[5] == '>') {
        static char byte;                /* a raw byte token, "<0x0A>" */
        int v = 0;
        for (int i = 3; i < 5; i++)
            v = v * 16 + (p[i] <= '9' ? p[i] - '0' : (p[i] | 0x20) - 'a' + 10);
        byte = (char)v;
        *len = 1;
        return &byte;
    }
    if (prev == 1 && *len && p[0] == ' ') {
        p++;
        (*len)--;
    }
    return p;
}

uint32_t llm_prompt(uint32_t i)
{
    return BLOB(uint16_t, LLM_OFF_PROMPT)[i];
}

uint32_t llm_crc32(const void *p, uint32_t n)
{
    const uint8_t *b = p;
    uint32_t c = 0xFFFFFFFFu;
    while (n--) {
        c ^= *b++;
        for (int i = 0; i < 8; i++)
            c = (c >> 1) ^ (0xEDB88320u & -(c & 1u));
    }
    return ~c;
}
