"""The demo reel (sw/demo/) on the whole SoC, each demo checked against a model.

The RAM starts with the bootloader and the demo program already saved
(sw/build/boot_demo_sim.hex, scripts/mkimage.py), so each test reaches the
menu by pressing r. The UART runs at CLK/16 here (3.125 Mbaud) rather than
115200: a Life frame is 1700 characters. Nothing in the firmware depends on
the baud rate.

What each demo must print is computed here independently: the pipeline
microbenchmarks' cycle counts from the pipeline's design; Mandelbrot in Q12
fixed point and in IEEE single precision (rounded after every operation, as
libgcc's soft-float does); pi by Machin's formula; Life by its rules; the
primes by trial division.
"""

import os
import re
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

CLK_PERIOD_NS = 20          # 50 MHz, soc.sv's default
CLKS_PER_BIT = 16           # BAUD = 3125000, set for this build in the Makefile


async def uart_out(dut, out):
    while True:
        while dut.uart_tx_o.value:
            await RisingEdge(dut.clk_i)
        await ClockCycles(dut.clk_i, CLKS_PER_BIT // 2)
        byte = 0
        for i in range(8):
            await ClockCycles(dut.clk_i, CLKS_PER_BIT)
            byte |= int(dut.uart_tx_o.value) << i
        await ClockCycles(dut.clk_i, CLKS_PER_BIT)
        assert dut.uart_tx_o.value == 1, f"framing error after {byte:#04x}"
        out.append(chr(byte))


class Board:
    def __init__(self, dut):
        self.dut = dut
        self.out = []

    async def start(self):
        dut = self.dut
        cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
        dut.uart_rx_i.value = 1
        dut.rst_i.value = 1
        await ClockCycles(dut.clk_i, 5)
        await FallingEdge(dut.clk_i)
        dut.rst_i.value = 0
        cocotb.start_soon(uart_out(dut, self.out))
        await self.expect("or r to rerun the last one\r\n")
        await self.send("r")
        await self.expect("q  back to the bootloader\r\n\r\n> ")

    def text(self):
        return "".join(self.out)

    def mark(self):
        return len(self.out)

    def since(self, mark):
        return "".join(self.out[mark:])

    async def send(self, keys):
        for byte in keys.encode():
            for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
                self.dut.uart_rx_i.value = bit
                await ClockCycles(self.dut.clk_i, CLKS_PER_BIT)
            await ClockCycles(self.dut.clk_i, 4 * CLKS_PER_BIT)

    async def expect(self, text, after=0, cycles=20_000_000):
        for _ in range(0, cycles, 2000):
            if text in self.since(after):
                return self.since(after)
            await ClockCycles(self.dut.clk_i, 2000)
        raise AssertionError(f"waited for {text!r}; output was {self.since(after)[-600:]!r}")


# ---- models ----------------------------------------------------------------

PALETTE = " .,'~:;!+=*%$&#@"
W, H, MAXIT, Q = 76, 22, 32, 12


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def mandel_fixed(cr, ci):
    zr = zi = 0
    for i in range(MAXIT):
        zr2 = (zr * zr) >> Q
        zi2 = (zi * zi) >> Q
        if zr2 + zi2 > (4 << Q):
            return PALETTE[i >> 1]
        zi = ((zr * zi) >> (Q - 1)) + ci
        zr = zr2 - zi2 + cr
    return "@"


def mandel_float(cr, ci):
    # One rounding to single precision per operation. Exact: double holds
    # more than twice single's precision, so rounding twice gives the same.
    zr = zi = 0.0
    for i in range(MAXIT):
        zr2 = f32(zr * zr)
        zi2 = f32(zi * zi)
        if f32(zr2 + zi2) > 4.0:
            return PALETTE[i >> 1]
        zi = f32(f32(f32(2.0 * zr) * zi) + ci)
        zr = f32(f32(zr2 - zi2) + cr)
    return "@"


def mandel(use_float, cx=-(3 << Q) // 4, cy=0, step=(3 << Q) // W):
    # The demo's reset view; both divisions are exact or positive, so Python's
    # floor division agrees with C's truncation.
    x0 = cx - (W // 2) * step
    y0 = cy - (H // 2) * 2 * step
    rows = []
    for r in range(H):
        ci = y0 + r * 2 * step
        row = ""
        for c in range(W):
            cr = x0 + c * step
            if use_float:
                row += mandel_float(f32(cr * 2.0 ** -Q), f32(ci * 2.0 ** -Q))
            else:
                row += mandel_fixed(cr, ci)
        rows.append(row)
    return rows


def pi_digits(n):
    m = 10 ** (n + 10)

    def arctan_inv(x):
        total = term = m // x
        k, sign = 1, -1
        while term:
            term //= x * x
            k += 2
            total += sign * (term // k)
            sign = -sign
        return total

    return str(4 * (4 * arctan_inv(5) - arctan_inv(239)))[:n]


LW, LH = 76, 21
GUN = [
    "........................O...........",
    "......................O.O...........",
    "............OO......OO............OO",
    "...........O...O....OO............OO",
    "OO........O.....O...OO..............",
    "OO........O...O.OO....O.O...........",
    "..........O.....O.......O...........",
    "...........O...O....................",
    "............OO......................",
]


def life_gun(gens):
    cells = {(r + 2, c + 2) for r, line in enumerate(GUN) for c, ch in enumerate(line) if ch == "O"}
    for _ in range(gens):
        counts = {}
        for r, c in cells:
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    if dr or dc:
                        k = ((r + dr) % LH, (c + dc) % LW)
                        counts[k] = counts.get(k, 0) + 1
        cells = {k for k, n in counts.items() if n == 3 or (n == 2 and k in cells)}
    return ["".join("O" if (r, c) in cells else " " for c in range(LW)) + "|" for r in range(LH)]


def is_prime(v):
    if v < 2:
        return False
    d = 2
    while d * d <= v:
        if v % d == 0:
            return False
        d += 1
    return True


def frame(text, rows):
    """The last full frame drawn after a cursor-home, as rows of text."""
    body = text[text.rindex("\x1b[H") + 3:]
    return body.split("\r\n")[:rows]


# ---- tests -----------------------------------------------------------------

@cocotb.test()
async def test_sysinfo(dut):
    """The microbenchmarks measure exactly what the pipeline's design says."""
    b = Board(dut)
    await b.start()
    m = b.mark()
    await b.send("1")
    out = await b.expect("[press a key]", m)
    assert "4 patterns: pass" in out, "RAM test failed"
    want = {
        "ALU ops": (100, 100),               # one cycle each
        "load, used next": (100, 150),       # + 1 stall per load
        "load, used one later": (150, 150),  # forwarded, no stall
        "taken jumps": (50, 150),            # + 2 flushed cycles each
        "taken branches": (50, 150),
        "branches not taken": (50, 50),      # predicted: free
    }
    for name, (instrs, cycles) in want.items():
        line = re.search(re.escape(name) + r"\s+(\d+) instr\s+(\d+) cycles", out)
        assert line, f"no line for {name}"
        assert (int(line[1]), int(line[2])) == (instrs, cycles), \
            f"{name}: {line[1]} instr, {line[2]} cycles; expected {instrs}, {cycles}"
    await b.send("x")
    await b.expect("> ", b.mark())


@cocotb.test()
async def test_mandelbrot_fixed_and_float(dut):
    """Both renderers match the models character for character."""
    b = Board(dut)
    await b.start()
    m = b.mark()
    await b.send("2")
    out = await b.expect("q back  ", m, cycles=60_000_000)
    assert frame(out, H) == mandel(False), "fixed-point frame differs from the model"
    fixed_cycles = int(re.search(r"fixed point Q12\s+step \d+/4096\s+(\d+) cycles", out)[1])

    # The float frame is 49 million cycles, about 9 minutes here: run locally,
    # skipped on GitHub's runners (which set CI) to keep each push's run short.
    if os.environ.get("CI"):
        dut._log.info("CI: software-float frame skipped (runs in a local make sim)")
        await b.send("q")
        await b.expect("> ", m)
        return
    m = b.mark()
    await b.send("f")
    out = await b.expect("q back  ", m, cycles=150_000_000)
    assert frame(out, H) == mandel(True), "software-float frame differs from the IEEE model"
    float_cycles = int(re.search(r"software float\s+step \d+/4096\s+(\d+) cycles", out)[1])
    dut._log.info(f"Mandelbrot frame: fixed {fixed_cycles} cycles, float {float_cycles} "
                  f"({float_cycles / fixed_cycles:.1f}x)")
    await b.send("q")
    await b.expect("> ", m)


@cocotb.test()
async def test_pi(dut):
    b = Board(dut)
    await b.start()
    m = b.mark()
    await b.send("3")
    await b.expect("]: ", m)
    await b.send("60\r")
    out = await b.expect("[press a key]", m, cycles=40_000_000)
    printed = out[out.index("\r\n\r\n3") + 4:out.index(" digits in")]
    digits = re.sub(r"[^0-9]", "", printed.rsplit("\r\n\r\n", 1)[0])
    assert digits == pi_digits(60), f"{digits} != {pi_digits(60)}"
    assert "60 digits in" in out
    await b.send("x")


@cocotb.test()
async def test_life(dut):
    """Paused at some generation, the board matches the model; one step later too."""
    b = Board(dut)
    await b.start()
    m = b.mark()
    await b.send("4")
    await b.expect("generation 1 ", m, cycles=30_000_000)
    await b.send(" ")
    out = await b.expect("paused", m, cycles=30_000_000)
    gen = int(re.findall(r"generation (\d+) ", out)[-1])
    assert frame(out, LH) == life_gun(gen), f"generation {gen} differs from the model"
    assert int(dut.led_o.value) == gen & 15, "LEDs do not show the generation"

    m = b.mark()
    await b.send("n")
    out = await b.expect(f"generation {gen + 1} ", m, cycles=30_000_000)
    out = await b.expect("q back ", m)
    assert frame(out, LH) == life_gun(gen + 1), f"generation {gen + 1} differs from the model"
    await b.send("q")
    await b.expect("> ", m)


@cocotb.test()
async def test_hanoi(dut):
    b = Board(dut)
    await b.start()
    m = b.mark()
    await b.send("5")
    await b.expect("]: ", m)
    await b.send("3\r5")                     # three disks, speed 5: no delay
    out = await b.expect("[press a key]", m, cycles=40_000_000)
    assert "solved: 7 moves, 2^3 - 1 = 7" in out
    last = frame(out[:out.index("solved")], 4)[1:4]
    assert [len(row.strip().split()[-1]) for row in last] == [1, 3, 5], f"C holds {last}"
    await b.send("x")


@cocotb.test()
async def test_primes(dut):
    b = Board(dut)
    await b.start()
    m = b.mark()
    await b.send("6")
    await b.expect("]: ", m)
    await b.send("1000\r")
    # The whole prompt, not just its start: keys sent while the board is still
    # printing overrun the receiver's one-byte buffer and are lost.
    prompt = "(0 to go back) [0-9999999, Enter for 0]: "
    out = await b.expect(prompt, m, cycles=40_000_000)
    for limit in (10, 100, 1000):
        count = sum(is_prime(v) for v in range(limit + 1))
        assert re.search(rf"\s{limit}\s+{count}\r\n", out), f"pi({limit}) should be {count}"
    largest = [v for v in range(1001) if is_prime(v)][-8:]
    assert "the largest up to 1000: " + " ".join(map(str, largest)) in out

    for v in (997, 1001, 7919, 9999991, 9999973):
        m = b.mark()
        await b.send(f"{v}\r")
        out = await b.expect(prompt, m, cycles=40_000_000)
        want = "prime" if is_prime(v) else "not prime"
        assert f"{v} is {want}\r\n" in out, f"{v}: {out!r}"
    await b.send("0\r")
    await b.expect("> ", m)


@cocotb.test()
async def test_tmr(dut):
    """Demo 7: the sieve once clean, then repeatedly with copy B's pc flipped
    every 64 marks until a key, the table's injected row rewritten after each
    pass. With TMR (soc_tmr) every pass has the clean answer and cycle count
    and the voter saw every flip; on one core the writes do nothing."""
    b = Board(dut)
    await b.start()
    m = b.mark()
    await b.send("7")
    await b.expect("pass 2", m, cycles=40_000_000)
    await b.send("x")
    out = await b.expect("[press a key]", m, cycles=40_000_000)
    n = 163840
    odd = bytearray([1]) * (n + 1)
    for p in range(3, int(n ** 0.5) + 1, 2):
        if odd[p]:
            odd[p * p::2 * p] = bytes(len(range(p * p, n + 1, 2 * p)))
    primes = 1 + sum(odd[v] for v in range(3, n + 1, 2))
    rows = re.findall(r"(clean|injected)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)(?:\s+pass (\d+))?", out)
    assert rows and rows[0][0] == "clean", f"no clean run: {out!r}"
    (p0, c0, f0, d0), inj = map(int, rows[0][1:5]), rows[1:]
    assert p0 == primes, f"clean: primes {p0}, expected {primes}"
    assert (f0, d0) == (0, 0), "the clean run flipped or detected something"
    passes = [int(r[5]) for r in inj]
    assert passes == list(range(1, len(inj) + 1)) and len(inj) >= 2, f"passes {passes}"
    for _, p1, c1, _, _, _ in inj:
        assert int(p1) == primes, f"injected: primes {p1}, expected {primes}"
        assert int(c1) == c0, f"cycles {c0} clean, {c1} injected: correction should cost none"
    f1, d1 = map(int, inj[-1][3:5])
    assert f1 == len(inj) * int(inj[0][3]) > 1000 * len(inj), f"flips {f1} over {len(inj)} passes"
    core = dut.g_cpu.u_core
    if hasattr(core, "mismatch_count_o"):
        assert d1 == f1, f"{d1} of {f1} flips detected"
        since = int(re.search(r"disagreements since reset: (\d+)", out)[1])
        assert since == int(core.mismatch_count_o.value) >= f1
        dut._log.info(f"{f1} flips in {len(inj)} passes, all detected ({since} disagreements); "
                      f"{c0} cycles every pass")
    else:
        assert d1 == 0 and "(one core: make impl TMR=1)" in out
    await b.send("x")
    await b.expect("> ", b.mark())
