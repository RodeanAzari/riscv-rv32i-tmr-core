#!/usr/bin/env python3
"""Golden model of the tiny-LLM demo (Phase H): llama2.c's stories260K, integer only.

Written before the firmware (sw/llm/llm_app.c), which must match it bit for bit.

The model is Karpathy's stories260K (llama2.c, MIT licence; weights from
huggingface.co/karpathy/tinyllamas, checked by SHA-256 below): dim 64, hidden
172, 5 layers, 8 heads, 4 KV heads, vocabulary 512, shared classifier.

Two forward passes:
  float_forward  a NumPy copy of llama2.c's run.c in float32; greedy decoding
                 from "Once upon a time" gives the same tokens as run.c built
                 from upstream (checked when this was written; the tokens are
                 in FLOAT_REF below, so the check needs no C compiler).
  IntModel       what the firmware does, integer only (the core has no FPU):

Decided with the user (2026-11-25): weights INT8 with one scale per output
column (per row in llama2.c's layout), activations quantized to INT8 per
vector, so a whole dot product is one accelerator job and one rescale.

Formats (Qn = value * 2^n in a signed integer):
  activations     Q16 int32 (x, normed x, q, k, v, attention out, FFN)
  weights         int8, stored K x N (input x output, the accelerator's W
                  layout), in column blocks of at most BLOCK_BYTES so each
                  block is one accelerator job; per column n a multiplier
                  m[n] = round(wmax_n / 127^2 * 2^40)
  activation q8   amax = max|a|; r = floor(127 * 2^32 / amax);
                  q = clamp((a * r + 2^31) >> 32, -127, 127)
  matvec          acc = sum q * w (int32, what the array computes);
                  t = (acc * m + 2^23) >> 24; y = (t * amax + 2^15) >> 16
  embedding       x = (w * e + 2^7) >> 8, e = round(wmax_t / 127 * 2^24)
  RMSNorm         ms = (sum x^2) / dim + eps (Q32); s = isqrt(ms) (Q16);
                  inv = floor(2^46 / s) (Q30);
                  y = ((((x * g + 2^15) >> 16) * inv) + 2^29) >> 30
  RoPE            cos, sin Q30 tables per position; (a*c - b*s + 2^29) >> 30
  KV cache        int16, k Q9 (+-64), v Q11 (+-16), rounded, saturated
                  (saturations are counted)
  scores          ((q . k) * round(2^16 / sqrt(8)) + 2^24) >> 25
  exp(-d), d >= 0 Q16 in, Q16 out: t = (d * round(log2(e) * 2^16) + 2^15)
                  >> 16, n = t >> 16, 2^-frac from a 257-entry Q30 table
                  with linear interpolation, then a rounding shift by n + 14;
                  0 for d >= 16
  softmax         e_i = exp(-(max - s_i)); inv = floor(2^40 / sum e);
                  p_i = (e_i * inv + 2^23) >> 24 (Q16)
  attention out   (sum p * v + 2^10) >> 11
  SiLU            e = exp(-|h|); sig (Q15) = floor(2^31 / (2^16 + e)) for
                  h >= 0, floor(e * 2^15 / (2^16 + e)) otherwise;
                  silu = (h * sig + 2^14) >> 15; times h3: (. * h3 + 2^15) >> 16
  logits          the matvec above; the next token is the first argmax

Every shift is arithmetic (floor), every division has non-negative operands
(so C's truncation and Python's floor agree), and every intermediate is
checked here to fit the C type the firmware holds it in.

Usage:
  llm_model.py check  DIR         kernels against float, then the integer
                                  model against float_forward
  llm_model.py export DIR OUTDIR  write llm_blob.bin, llm_blob.h and
                                  llm_vectors.txt for the firmware
DIR holds stories260K.bin and tok512.bin (make llm-model fetches them).
"""
import hashlib
import math
import struct
import sys
from pathlib import Path

import numpy as np

SHA256 = {
    "stories260K.bin": "b0a507e7ad0f626624f17112325e66691f9076d622e1d3274d103d00299f2696",
    "tok512.bin": "037cb335abb25d1fa9e8ecae30ed2a3a8ace9302862ebcdc05d51a6bbb10c312",
}
PROMPT = "Once upon a time"
MAX_SEQ = 64                 # context the firmware keeps (KV cache size)
BLOCK_BYTES = 16384          # the accelerator's W buffer (gemm_accel BUF_BYTES)
GEMM_COLS = 16               # W rows are padded to whole lines of this

# run.c (upstream llama2.c 350e04f), -t 0 -n 64 -i "Once upon a time":
# prompt tokens then 59 generated, as float_forward must reproduce.
FLOAT_REF = [1, 403, 407, 261, 378, 432, 383, 286, 261, 376, 298, 315, 421,
             395, 317, 426, 338, 401, 396, 267, 337, 410, 408, 419, 292, 411,
             322, 265, 282, 295, 433, 426, 385, 328, 432, 358, 394, 261, 370,
             432, 352, 266, 268, 388, 426, 338, 391, 266, 267, 337, 335, 312,
             432, 398, 312, 286, 267, 414, 270, 333, 415, 426, 13, 438, 310]

Q16 = 1 << 16
EPS_Q32 = round(1e-5 * 2**32)
LOG2E_Q16 = round(math.log2(math.e) * Q16)
EXP2_LUT = [round(2**30 * 2 ** (-i / 256)) for i in range(257)]   # Q30
K_SHIFT, V_SHIFT = 7, 5      # Q16 -> Q9 and Q11
MAT_ORDER = ("wq", "wk", "wv", "wo", "w1", "w3", "w2")   # blob order per layer


# ---------------------------------------------------------------- loading

def load(d):
    d = Path(d)
    for name, digest in SHA256.items():
        got = hashlib.sha256((d / name).read_bytes()).hexdigest()
        if got != digest:
            sys.exit(f"{d / name}: SHA-256 {got}, expected {digest}")
    raw = (d / "stories260K.bin").read_bytes()
    cfg = struct.unpack("7i", raw[:28])
    dim, hid, n_l, n_h, n_kv, vocab, seq = cfg
    assert vocab > 0, "shared classifier expected"
    f = np.frombuffer(raw[28:], dtype=np.float32)
    o = 0

    def take(*shape):
        nonlocal o
        n = int(np.prod(shape))
        a = f[o:o + n].reshape(shape)
        o += n
        return a
    kvd = n_kv * dim // n_h
    w = dict(emb=take(vocab, dim), rms_att=take(n_l, dim), wq=take(n_l, dim, dim),
             wk=take(n_l, kvd, dim), wv=take(n_l, kvd, dim), wo=take(n_l, dim, dim),
             rms_ffn=take(n_l, dim), w1=take(n_l, hid, dim), w2=take(n_l, dim, hid),
             w3=take(n_l, hid, dim), rms_final=take(dim))
    o += seq * (dim // n_h)          # freq_cis_real/imag, unused (run.c too)
    assert o == f.size, (o, f.size)
    w["cfg"] = dict(dim=dim, hidden=hid, n_layers=n_l, n_heads=n_h, n_kv_heads=n_kv,
                    vocab=vocab, seq=seq, head_size=dim // n_h, kv_dim=kvd)
    w["vocab"], w["vocab_scores"] = load_tokenizer(d / "tok512.bin", vocab)
    return w


def load_tokenizer(path, vocab):
    d = path.read_bytes()
    o = 4                            # max_token_length
    pieces, scores = [], []
    for _ in range(vocab):
        sc, n = struct.unpack("fi", d[o:o + 8])
        o += 8
        pieces.append(d[o:o + n])
        scores.append(sc)
        o += n
    return pieces, scores


def encode(w, text):
    """run.c's encode() with bos=1, eos=0: dummy-prefix space, BPE by score."""
    lookup = {p: i for i, p in enumerate(w["vocab"])}
    toks = [1]
    if text:
        toks.append(lookup[b" "])
    for ch in text.encode():
        # stories260K's vocabulary holds every byte this demo uses
        toks.append(lookup[bytes([ch])])
    body = toks[1:]
    while True:
        best, best_i, best_id = -1e10, -1, -1
        for i in range(len(body) - 1):
            pid = lookup.get(w["vocab"][body[i]] + w["vocab"][body[i + 1]])
            if pid is not None and w["vocab_scores"][pid] > best:
                best, best_i, best_id = w["vocab_scores"][pid], i, pid
        if best_i < 0:
            break
        body[best_i:best_i + 2] = [best_id]
    return [1] + body


def decode(w, prev, tok):
    p = w["vocab"][tok]
    if prev == 1 and p.startswith(b" "):
        p = p[1:]
    return p


# ---------------------------------------------------------------- float

def float_forward(w, tok, pos, cache):
    c = w["cfg"]
    hs, kvd, rep = c["head_size"], c["kv_dim"], c["n_heads"] // c["n_kv_heads"]

    def rms(x, g):
        ss = np.float32(np.dot(x, x) / c["dim"] + np.float32(1e-5))
        return g * (x / np.sqrt(ss))
    x = w["emb"][tok].copy()
    for l in range(c["n_layers"]):
        xb = rms(x, w["rms_att"][l])
        q, k, v = w["wq"][l] @ xb, w["wk"][l] @ xb, w["wv"][l] @ xb
        for i in range(0, c["dim"], 2):
            fr = 1.0 / 10000.0 ** ((i % hs) / hs)
            co, si = np.cos(pos * fr), np.sin(pos * fr)
            for vec in ((q, k) if i < kvd else (q,)):
                a, b = vec[i], vec[i + 1]
                vec[i], vec[i + 1] = a * co - b * si, a * si + b * co
        cache[0][l, pos], cache[1][l, pos] = k, v
        out = np.zeros(c["dim"], np.float32)
        for h in range(c["n_heads"]):
            kh = (h // rep) * hs
            sc = cache[0][l, :pos + 1, kh:kh + hs] @ q[h * hs:(h + 1) * hs] / np.sqrt(hs)
            e = np.exp(sc - sc.max())
            out[h * hs:(h + 1) * hs] = (e / e.sum()) @ cache[1][l, :pos + 1, kh:kh + hs]
        x = x + w["wo"][l] @ out
        xb = rms(x, w["rms_ffn"][l])
        h1, h3 = w["w1"][l] @ xb, w["w3"][l] @ xb
        x = x + w["w2"][l] @ (h1 * (1 / (1 + np.exp(-h1))) * h3)
    return w["emb"] @ rms(x, w["rms_final"])


def float_cache(w, seq):
    c = w["cfg"]
    shape = (c["n_layers"], seq, c["kv_dim"])
    return np.zeros(shape, np.float32), np.zeros(shape, np.float32)


# ---------------------------------------------------------------- integer

def fits(a, bits, what):
    """Assert every value of a fits a signed `bits`-bit C integer."""
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    a = np.asarray(a, dtype=object) if not isinstance(a, np.ndarray) else a
    mn, mx = int(np.min(a)), int(np.max(a))
    assert lo <= mn and mx <= hi, f"{what}: {mn}..{mx} overflows int{bits}"


def rshift(a, s):
    """Rounding arithmetic right shift (round half up), as the C does."""
    return (a + (1 << (s - 1))) >> s


def exp_neg(d):
    """exp(-d) for d >= 0, Q16 in and out (int64 arrays or ints)."""
    d = np.asarray(d, dtype=np.int64)
    assert (d >= 0).all()
    t = rshift(d * LOG2E_Q16, 16)
    n, f = t >> 16, t & 0xFFFF
    idx, frac = f >> 8, f & 0xFF
    lut = np.array(EXP2_LUT, dtype=np.int64)
    v = lut[idx] + (((lut[np.minimum(idx + 1, 256)] - lut[idx]) * frac + 128) >> 8)
    n = np.minimum(n, 40)            # d >= 16 is forced to 0 below anyway
    out = (v + (np.int64(1) << (n + 13))) >> (n + 14)
    return np.where(d >= (16 << 16), 0, out)


def quantize_q8(a):
    """INT8 codes and amax (Q16) of a Q16 vector."""
    a = np.asarray(a, dtype=np.int64)
    amax = int(np.abs(a).max())
    if amax == 0:
        return np.zeros(a.size, np.int64), 0
    r = (127 << 32) // amax
    fits(a * r, 64, "q8 product")
    return np.clip(rshift(a * r, 32), -127, 127), amax


class Matrix:
    """A K x N int8 weight matrix stored as column blocks, with multipliers."""

    def __init__(self, wf, block_bytes=BLOCK_BYTES):
        wf = np.asarray(wf, dtype=np.float64)          # llama2.c layout: N x K
        self.n, self.k = wf.shape
        wmax = np.abs(wf).max(axis=1)
        wmax = np.where(wmax == 0, 1.0, wmax)
        self.q = np.clip(np.rint(wf / wmax[:, None] * 127), -127, 127).astype(np.int64).T
        self.m = np.rint(wmax / (127 * 127) * 2**40).astype(np.int64)
        self.e = np.rint(wmax / 127 * 2**24).astype(np.int64)
        fits(self.m, 32, "multiplier")
        fits(self.e, 32, "embedding scale")
        self.nb = max(GEMM_COLS, (block_bytes // self.k) // GEMM_COLS * GEMM_COLS)
        self.nb = min(self.nb, self.n)

    def blocks(self):
        """(n0, n1) column ranges, each one dense K x (n1 - n0) block."""
        return [(n0, min(n0 + self.nb, self.n)) for n0 in range(0, self.n, self.nb)]

    def matvec(self, a):
        qa, amax = quantize_q8(a)
        acc = qa @ self.q                                # what the array computes
        fits(acc, 32, "accumulator")
        t = rshift(acc * self.m, 24)
        fits(acc * self.m, 64, "acc * m")
        fits(t * amax, 64, "t * amax")
        y = rshift(t * amax, 16)
        fits(y, 32, "matvec out")
        return y, acc


class IntModel:
    def __init__(self, w, seq=MAX_SEQ):
        self.c = c = w["cfg"]
        self.seq = seq
        L = c["n_layers"]
        self.mats = {name: [Matrix(w[name][l]) for l in range(L)]
                     for name in ("wq", "wk", "wv", "wo", "w1", "w2", "w3")}
        self.emb = Matrix(w["emb"])                       # N = vocab (tokens)
        q16 = lambda a: np.rint(np.asarray(a, np.float64) * Q16).astype(np.int64)
        self.rms_att, self.rms_ffn = q16(w["rms_att"]), q16(w["rms_ffn"])
        self.rms_final = q16(w["rms_final"])
        hs = c["head_size"]
        ang = np.array([[p * (1.0 / 10000.0 ** ((2 * i) / hs)) for i in range(hs // 2)]
                        for p in range(seq)])
        self.cos = np.rint(np.cos(ang) * 2**30).astype(np.int64)
        self.sin = np.rint(np.sin(ang) * 2**30).astype(np.int64)
        self.score_c = round(Q16 / math.sqrt(hs))
        self.reset()

    def reset(self):
        c = self.c
        shape = (c["n_layers"], self.seq, c["kv_dim"])
        self.kc = np.zeros(shape, np.int64)
        self.vc = np.zeros(shape, np.int64)
        self.saturations = 0

    def rmsnorm(self, x, g):
        ss = int(np.sum(x * x))
        fits(ss, 64, "sum of squares")
        ms = ss // self.c["dim"] + EPS_Q32
        s = math.isqrt(ms)
        inv = (1 << 46) // s
        xg = rshift(x * g, 16)
        fits(xg * inv, 64, "rmsnorm product")
        return rshift(xg * inv, 30)

    def rope(self, v, pos, n):
        hs = self.c["head_size"]
        v = v.copy()
        for i in range(0, n, 2):
            co, si = self.cos[pos, (i % hs) // 2], self.sin[pos, (i % hs) // 2]
            a, b = v[i], v[i + 1]
            v[i], v[i + 1] = rshift(a * co - b * si, 30), rshift(a * si + b * co, 30)
        return v

    def store(self, v, shift):
        r = rshift(v, shift)
        self.saturations += int(np.sum((r > 32767) | (r < -32768)))
        return np.clip(r, -32768, 32767)

    def forward(self, tok, pos):
        c, M = self.c, self.mats
        hs, rep = c["head_size"], c["n_heads"] // c["n_kv_heads"]
        assert pos < self.seq
        x = rshift(self.emb.q[:, tok] * self.emb.e[tok], 8)
        for l in range(c["n_layers"]):
            xb = self.rmsnorm(x, self.rms_att[l])
            q, _ = M["wq"][l].matvec(xb)
            k, _ = M["wk"][l].matvec(xb)
            v, _ = M["wv"][l].matvec(xb)
            q, k = self.rope(q, pos, c["dim"]), self.rope(k, pos, c["kv_dim"])
            self.kc[l, pos] = self.store(k, K_SHIFT)
            self.vc[l, pos] = self.store(v, V_SHIFT)
            out = np.zeros(c["dim"], np.int64)
            for h in range(c["n_heads"]):
                kh = (h // rep) * hs
                qh = q[h * hs:(h + 1) * hs]
                dots = self.kc[l, :pos + 1, kh:kh + hs] @ qh
                fits(dots * self.score_c, 64, "score product")
                sc = rshift(dots * self.score_c, 25)
                fits(sc, 32, "score")
                e = exp_neg(sc.max() - sc)
                inv = (1 << 40) // int(e.sum())
                p = rshift(e * inv, 24)
                acc = p @ self.vc[l, :pos + 1, kh:kh + hs]
                fits(acc, 64, "attention acc")
                out[h * hs:(h + 1) * hs] = rshift(acc, 11)
            y, _ = M["wo"][l].matvec(out)
            x = x + y
            fits(x, 32, "residual")
            xb = self.rmsnorm(x, self.rms_ffn[l])
            h1, _ = M["w1"][l].matvec(xb)
            h3, _ = M["w3"][l].matvec(xb)
            e = exp_neg(np.abs(h1))
            sig = np.where(h1 >= 0, (1 << 31) // (Q16 + e), (e << 15) // (Q16 + e))
            hb = rshift(rshift(h1 * sig, 15) * h3, 16)
            fits(hb, 32, "ffn hidden")
            y, _ = M["w2"][l].matvec(hb)
            x = x + y
            fits(x, 32, "residual")
        logits, _ = self.emb.matvec(self.rmsnorm(x, self.rms_final))
        return logits


def xorshift64(n, seed=0x9E3779B97F4A7C15):
    """n values of Marsaglia's xorshift64 (13, 7, 17), as llm_host.c makes them."""
    x, out, m = seed, [], (1 << 64) - 1
    for _ in range(n):
        x ^= (x << 13) & m
        x ^= x >> 7
        x ^= (x << 17) & m
        out.append(x)
    return out


def kernel_crcs():
    """CRC-32 of each kernel over a sweep the C repeats: exp(-d) for every d
    in [0, 17 * 2^16), the sigmoid (Q15) for every h in [-20, 20) * 2^16,
    isqrt of 100,000 xorshift values shifted right by i % 64."""
    import zlib
    crc = lambda a: zlib.crc32(np.asarray(a, dtype="<u4").tobytes())
    d = np.arange(0, 17 << 16, dtype=np.int64)
    h = np.arange(-20 << 16, 20 << 16, dtype=np.int64)
    e = exp_neg(np.abs(h))
    sig = np.where(h >= 0, (1 << 31) // (Q16 + e), (e << 15) // (Q16 + e))
    xs = xorshift64(100000)
    roots = [math.isqrt(x >> (i % 64)) for i, x in enumerate(xs)]
    return {"exp_neg": crc(exp_neg(d)), "sigmoid": crc(sig), "isqrt": crc(roots)}


def logits_crc(logits):
    import zlib
    return zlib.crc32(np.asarray(logits, dtype="<i4").tobytes())


def generate(model, w, n):
    """Greedy: prompt tokens forced, then argmax. Returns tokens and per-step CRCs."""
    prompt = encode(w, PROMPT)
    toks, crcs = [prompt[0]], []
    model.reset()
    for pos in range(n - 1):
        lg = model.forward(toks[-1], pos)
        crcs.append(logits_crc(lg))
        toks.append(prompt[pos + 1] if pos + 1 < len(prompt) else int(np.argmax(lg)))
    return toks, crcs


# ---------------------------------------------------------------- checks

def check_kernels():
    d = np.arange(0, 17 << 16, 37, dtype=np.int64)
    err = np.abs(exp_neg(d) - np.exp(-d / Q16) * Q16).max()
    print(f"exp(-d), d in [0, 17]: max error {err:.2f} LSB (Q16)")
    assert err <= 1.0, err
    assert exp_neg(0) == Q16
    h = np.arange(-20 << 16, 20 << 16, 101, dtype=np.int64)
    e = exp_neg(np.abs(h))
    sig = np.where(h >= 0, (1 << 31) // (Q16 + e), (e << 15) // (Q16 + e))
    hf = h / Q16
    err = np.abs(sig / 2**15 - 1 / (1 + np.exp(-hf))).max()
    print(f"sigmoid, h in [-20, 20]: max error {err * 2**15:.2f} LSB (Q15)")
    assert err * 2**15 <= 2.0, err
    rng = np.random.default_rng(1)
    for scale in (1e-3, 1.0, 30.0):
        a = np.rint(rng.normal(0, scale, 172) * Q16).astype(np.int64)
        qa, amax = quantize_q8(a)
        err = np.abs(qa * amax / 127 - a).max() / amax
        assert err <= 0.5 / 127 + 1e-4, (scale, err)
    print("q8 quantization: within half a step at 3 scales")
    qa, amax = quantize_q8(np.zeros(8, np.int64))
    assert amax == 0 and not qa.any()


def check_model(w, n=MAX_SEQ):
    cache = float_cache(w, n)
    prompt = encode(w, PROMPT)
    assert prompt == FLOAT_REF[:len(prompt)], prompt
    ftoks = [prompt[0]]
    for pos in range(n - 1):
        lg = float_forward(w, ftoks[-1], pos, cache)
        ftoks.append(prompt[pos + 1] if pos + 1 < len(prompt) else int(np.argmax(lg)))
    assert ftoks == FLOAT_REF[:n], "float model differs from run.c"
    print(f"float model: {n} tokens equal to run.c's")

    model = IntModel(w)
    itoks, _ = generate(model, w, n)
    first = next((i for i in range(n) if itoks[i] != ftoks[i]), None)
    print(f"integer model, greedy: {'all ' + str(n) if first is None else str(first)}"
          f" tokens equal to float before the first difference;"
          f" KV saturations {model.saturations}")
    # teacher-forced: both models see the float model's tokens
    model.reset()
    cache = float_cache(w, n)
    agree = 0
    for pos in range(n - 1):
        fl = float_forward(w, ftoks[pos], pos, cache)
        il = model.forward(ftoks[pos], pos)
        agree += int(np.argmax(fl) == np.argmax(il))
    print(f"integer model, teacher-forced: argmax equal at {agree}/{n - 1} positions")
    text = b"".join(decode(w, a, b) for a, b in zip(itoks, itoks[1:]))
    print("integer text:", text.decode(errors="replace"))
    # Floors, not the measured values (62 and 62/63 when this was written):
    # a quantization change may move the first difference, a bug moves it a lot.
    assert agree >= 0.9 * (n - 1), "integer argmax disagrees with float too often"
    assert first is None or first >= n // 2, "integer greedy text left float's early"


# ---------------------------------------------------------------- export

def export(w, outdir):
    """llm_blob.bin (little-endian, 4-byte aligned sections), its header
    llm_blob.h (sizes and byte offsets), and llm_vectors.txt (tokens and
    per-step logits CRC-32 the firmware must reproduce)."""
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    model = IntModel(w)
    c = model.c
    blob = bytearray()
    defs = []

    def put(name, arr, dtype):
        while len(blob) % 4:
            blob.append(0)
        defs.append((name, len(blob)))
        a = np.asarray(arr)
        bits = np.dtype(dtype).itemsize * 8
        if np.dtype(dtype).kind == "u":
            assert 0 <= a.min() and a.max() < (1 << bits), name
        else:
            fits(a, bits, name)
        blob.extend(a.astype(dtype).tobytes())

    mats = []                        # (blocks offset, multipliers offset, k, n, nb)

    def put_matrix(name, mat):
        start = len(blob) + (-len(blob)) % 4
        for b, (n0, n1) in enumerate(mat.blocks()):
            put(f"{name}_B{b}", mat.q[:, n0:n1], "<i1")
            # blocks back to back: block b at start + b * k * nb
            assert defs[-1][1] == start + b * mat.k * mat.nb, name
        put(f"{name}_M", mat.m, "<i4")
        mats.append((start, defs[-1][1], mat.k, mat.n, mat.nb))
    for l in range(c["n_layers"]):
        for name in MAT_ORDER:
            put_matrix(f"L{l}_{name.upper()}", model.mats[name][l])
    put_matrix("EMB", model.emb)
    put("EMB_E", model.emb.e, "<i4")
    put("RMS_ATT", model.rms_att, "<i4")
    put("RMS_FFN", model.rms_ffn, "<i4")
    put("RMS_FINAL", model.rms_final, "<i4")
    put("ROPE_COS", model.cos, "<i4")
    put("ROPE_SIN", model.sin, "<i4")
    put("EXP2_LUT", EXP2_LUT, "<i4")
    offs, text = [0], b""
    for p in w["vocab"]:
        text += p
        offs.append(len(text))
    put("VOCAB_OFFS", offs, "<u2")
    put("VOCAB_TEXT", np.frombuffer(text, np.uint8), "<u1")
    prompt = encode(w, PROMPT)
    put("PROMPT", prompt, "<u2")
    (outdir / "llm_blob.bin").write_bytes(bytes(blob))

    h = ["/* Generated by sw/model/llm_model.py export; do not edit. */",
         "#ifndef LLM_BLOB_H", "#define LLM_BLOB_H", "#include <stdint.h>"]
    for k in ("dim", "hidden", "n_layers", "n_heads", "n_kv_heads", "vocab",
              "head_size", "kv_dim"):
        h.append(f"#define LLM_{k.upper():<14} {c[k]}")
    h.append(f"#define LLM_SEQ            {model.seq}")
    h.append(f"#define LLM_PROMPT_LEN     {len(prompt)}")
    h.append(f"#define LLM_SCORE_C        {model.score_c}")
    h.append(f"#define LLM_EPS_Q32        {EPS_Q32}")
    h.append(f"#define LLM_LOG2E_Q16      {LOG2E_Q16}")
    h.append(f"#define LLM_K_SHIFT        {K_SHIFT}")
    h.append(f"#define LLM_V_SHIFT        {V_SHIFT}")
    for i, name in enumerate(MAT_ORDER):
        h.append(f"#define LLM_{name.upper():<14} {i}")
    h.append(f"#define LLM_N_MATS         {len(MAT_ORDER)}")
    for name, off in defs:
        if not name.startswith("L") and "_B" not in name and not name.endswith("_M"):
            h.append(f"#define LLM_OFF_{name:<14} {off}")
    h.append(f"#define LLM_BLOB_BYTES     {len(blob)}")
    h.append("/* per matrix: blocks, multipliers (byte offsets), K, N, columns per")
    h.append(" * block; layer l's matrix i at [l * LLM_N_MATS + i], the embedding last */")
    h.append("static const struct llm_mat { uint32_t w, m; uint16_t k, n, nb; }")
    h.append("llm_mats[LLM_N_LAYERS * LLM_N_MATS + 1] = {")
    h += [f"    {{{a}, {b}, {k}, {n}, {nb_}}}," for a, b, k, n, nb_ in mats]
    h.append("};")
    h.append("#endif")
    (outdir / "llm_blob.h").write_text("\n".join(h) + "\n")

    toks, crcs = generate(model, w, MAX_SEQ)
    lines = [f"# {PROMPT!r}, greedy, {MAX_SEQ} positions: pos token logits_crc32"]
    lines += [f"{i} {toks[i + 1]} {crcs[i]:08x}" for i in range(len(crcs))]
    lines += [f"kernel {k} {v:08x}" for k, v in kernel_crcs().items()]
    (outdir / "llm_vectors.txt").write_text("\n".join(lines) + "\n")
    print(f"wrote {outdir}/llm_blob.bin ({len(blob)} bytes), llm_blob.h, llm_vectors.txt")


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("check", "export"):
        sys.exit(__doc__)
    w = load(sys.argv[2])
    if sys.argv[1] == "check":
        check_kernels()
        check_model(w)
    else:
        export(w, sys.argv[3])


if __name__ == "__main__":
    main()
