"""Fault injection into the TMR core (CLAUDE.md 5.7): random bit flips, measured.

Toplevel riscv_core_tmr. Each trial runs a fresh dense random program (the
core test's generator: every hazard, forward branches, loads and stores,
ending in a halt) and, at a random cycle while it runs, flips one bit of one
copy's state. The bit is drawn uniformly from all of that copy's state: every
flip-flop the core's RTL assigns in always_ff (found by reading
rtl/core/riscv_core.sv, so a new register cannot be missed) and the 31
registers of its register file. Testbench only: the flip is a VPI deposit.

Each trial is then judged on what leaves the TMR core, against the golden
model: every voted register write, in order, and the final data memory.
Per trial:

  masked     no copy's next state ever differed from the others: the flipped
             bit was overwritten or never used before it could matter
  corrected  the copies disagreed (detected) and the output was still right
  failure    the output was wrong -- the case TMR exists to prevent

and, for each detected fault, whether the three copies' register files and
pipeline registers are identical again by the end (recovered) or a copy
still holds a wrong value (latent: typically a register-file bit in a
register the program never writes again), and how many cycles the
disagreement lasted.

FAULTS trials (default 1000 in the regression, about 15 s; `make faults`
runs the documented campaign and writes docs/reports/tmr_faults.txt). SEED picks the
campaign. The regression requires zero failures.

On the RV32IM build (riscv_core_tmr_m, M_EXT=1; `make faults M=1` writes
tmr_faults_m.txt) the programs are RV32IM (test_core_m's generator) and the
M unit's flip-flops, read from rtl/core/riscv_muldiv.sv the same way, are
part of each copy's state: flipped, and compared at the end.
"""

import os
import random
import re
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

import test_core
from rv32i_model import run_model
from test_core import CLK_PERIOD_NS, MEM_WB, NOP, bram_model, random_mem, random_program, release
from test_core_m import is_m, random_m_program

REPO = Path(__file__).resolve().parents[2]
REGFILE_BITS = 31 * 32                      # x1-x31; x0's storage is never read


M_EXT = os.environ.get("M_EXT") == "1"


def core_flops(path="rtl/core/riscv_core.sv"):
    """Names of a module's flip-flops, from its RTL, verification code excluded."""
    src = (REPO / path).read_text()
    kept, skip = [], 0
    for line in src.splitlines():
        # any `ifdef nested inside a skipped block counts too, so its `endif
        # does not end the skip early (riscv_muldiv: MULDIV_ARITH in FORMAL)
        if re.match(r"\s*`ifdef (RISCV_FORMAL|FORMAL)", line) or (
                skip and re.match(r"\s*`if(n?def)\b", line)):
            skip += 1
        elif skip and re.match(r"\s*`endif", line):
            skip -= 1
        elif not skip:
            kept.append(line)
    names = set()
    for blk in re.finditer(r"always_ff @\(posedge clk_i\) begin(.*?)\n  end\n",
                           "\n".join(kept), re.S):
        for m in re.finditer(r"^\s*(?:if.*?\)\s*|else\s*(?:if.*?\)\s*)?)?(\w+)\s*<=",
                             blk.group(1), re.M):
            names.add(m.group(1))
    return sorted(names)


def copies(dut):
    return [dut.u_core_a, dut.g_other[1].u_core, dut.g_other[2].u_core]


def flop_names():
    """Every flop group of a copy, as a path below the copy: the core's, and
    with M_EXT the unit's."""
    names = core_flops()
    if M_EXT:
        names += [f"g_muldiv.u_muldiv.{n}" for n in core_flops("rtl/core/riscv_muldiv.sv")]
    return names


def handle(core, path):
    for part in path.split("."):
        core = getattr(core, part)
    return core


def snapshot(core, flops):
    regs = [int(core.u_regfile.mem[i].value) for i in range(1, 32)]
    return regs, [int(handle(core, n).value) for n in flops]


async def trial(dut, rng, flops, widths):
    program = random_m_program(rng, 120) if M_EXT else random_program(rng, 120, 0)
    mem0 = random_mem(rng)
    want_wb, model = run_model(program, dict(mem0), m_ext=M_EXT)
    want = [(rd, v) for rd, v in want_wb if rd != 0]

    # Reset, with this trial's program and data in the memories the models
    # serve, and every copy's register file cleared as at power-up -- it has
    # no reset, and a fault left in it by the last trial must not leak in.
    test_core._imem.clear()
    test_core._imem.update({4 * i: w for i, w in enumerate(program)})
    mem = DMEM
    mem.clear()
    mem.update(mem0)
    dut.rst_i.value = 1
    for c in copies(dut):
        for i in range(32):
            c.u_regfile.mem[i].value = 0
    for _ in range(2):
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
    await release(dut)

    # The flip: which copy, which bit of its state, which cycle. Drawn so
    # that every state bit of the copy is equally likely.
    copy = rng.randrange(3)
    flop_bits = sum(widths)
    pick = rng.randrange(flop_bits + REGFILE_BITS)
    # A divide holds EX for 34 cycles: room for every M instruction to be one.
    n_m = sum(1 for w in program if is_m(w)) if M_EXT else 0
    run_cycles = 3 * len(program) + 34 * n_m + MEM_WB + 1
    at = rng.randrange(1, max(2, len(want_wb)))   # within the run, not after the halt
    core = copies(dut)[copy]

    got, mismatch_cycles, first, last = [], 0, None, None
    for cycle in range(run_cycles):
        if cycle == at:
            if pick < flop_bits:
                for name, w in zip(flops, widths):
                    if pick < w:
                        h = handle(core, name)
                        h.value = int(h.value) ^ (1 << pick)
                        where = f"{name}[{pick}]"
                        break
                    pick -= w
            else:
                pick -= flop_bits
                reg, bit = 1 + pick // 32, pick % 32
                h = core.u_regfile.mem[reg]
                h.value = int(h.value) ^ (1 << bit)
                where = f"regfile x{reg}[{bit}]"
        # Sampled just before the clock edge, where the counter samples it: a
        # flip the pc vote corrects at that same edge shows only here.
        await Timer(CLK_PERIOD_NS // 2 - 1, unit="ns")
        if int(dut.mismatch_o.value):
            mismatch_cycles += 1
            first = cycle if first is None else first
            last = cycle
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
        if int(dut.wb_rd_we_o.value) and int(dut.wb_rd_addr_o.value):
            got.append((int(dut.wb_rd_addr_o.value), int(dut.wb_rd_wdata_o.value)))
        if int(dut.halt_o.value) and cycle > at + 8:
            break

    correct = got == want and all(
        mem.get(a, 0) == model.mem.get(a, 0) for a in set(mem) | set(model.mem))
    snaps = [snapshot(c, flops) for c in copies(dut)]
    converged = snaps[0] == snaps[1] == snaps[2]
    return {
        "where": where, "copy": "ABC"[copy], "regfile": where.startswith("regfile"),
        "detected": mismatch_cycles > 0, "correct": correct, "recovered": converged,
        "span": (last - first + 1) if first is not None else 0,
        "count": int(dut.mismatch_count_o.value),
    }


def summarise(results, seed):
    n = len(results)

    def pct(k, d):
        return f"{k:5d}  {100 * k / d:5.1f}%" if d else f"{k:5d}      -"

    gen = ("RV32IM: tb/cocotb/test_core_m.py's generator, the M unit's flops among the targets"
           if M_EXT else "tb/cocotb/test_core.py's generator")
    lines = [f"TMR fault-injection campaign: {n} trials, seed {seed}",
             "One random bit flipped in one copy per trial; each trial a fresh dense random",
             f"program ({gen}, 120 instructions + setup) judged",
             "against the golden model on the voted register writes and final memory.",
             ""]
    groups = [("all faults", lambda r: True),
              ("pipeline flip-flops", lambda r: not r["regfile"]),
              ("register file", lambda r: r["regfile"])]
    if M_EXT:   # a subset of the pipeline flip-flops above
        groups.append(("of which the M unit's flip-flops", lambda r: "muldiv" in r["where"]))
    for label, sel in groups:
        rs = [r for r in results if sel(r)]
        det = [r for r in rs if r["detected"]]
        masked = [r for r in rs if not r["detected"]]
        lines += [f"{label}: {len(rs)}",
                  f"  masked (no copy ever disagreed)    {pct(len(masked), len(rs))}",
                  f"    still latent at end              {pct(sum(not r['recovered'] for r in masked), len(masked))}",
                  f"  detected (copies disagreed)        {pct(len(det), len(rs))}",
                  f"    output correct (corrected)       {pct(sum(r['correct'] for r in det), len(det))}",
                  f"    copies identical again at end    {pct(sum(r['recovered'] for r in det), len(det))}",
                  f"  output wrong (failure)             {pct(sum(not r['correct'] for r in rs), len(rs))}",
                  ""]
    det = [r for r in results if r["detected"]]
    spans = sorted(r["span"] for r in det)
    if spans:
        lines.append(f"disagreement length, detected faults: median {spans[len(spans) // 2]} "
                     f"cycles, 90th percentile {spans[int(len(spans) * 0.9)]}, max {spans[-1]}")
    lines.append(f"mismatch counter matched detection in "
                 f"{sum((r['count'] > 0) == r['detected'] for r in results)}/{n} trials")
    lines.append("still latent: a copy still holds the flipped value at the end -- unused, so")
    lines.append("never voted on, and rewritten only if the program writes that register.")
    latent = [r["where"] for r in det if not r["recovered"]]
    if latent:
        lines.append(f"detected but not recovered (first 10): {', '.join(latent[:10])}")
    fails = [r["where"] for r in results if not r["correct"]]
    if fails:
        lines.append(f"FAILURES: {', '.join(fails[:20])}")
    return "\n".join(lines) + "\n"


DMEM = {}


@cocotb.test()
async def test_fault_campaign(dut):
    # One clock and one pair of memory models for every trial.
    dut.rst_i.value = 1
    dut.imem_rdata_i.value = NOP
    dut.dmem_rdata_i.value = 0
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    cocotb.start_soon(bram_model(dut, "imem", test_core._imem, NOP))
    cocotb.start_soon(bram_model(dut, "dmem", DMEM, 0))

    seed = int(os.environ.get("SEED", "1"))
    n = int(os.environ.get("FAULTS", "1000"))
    rng = random.Random(seed)
    flops = flop_names()
    widths = [len(handle(dut.u_core_a, name)) for name in flops]
    dut._log.info(f"{len(flops)} flop groups, {sum(widths)} bits, + {REGFILE_BITS} "
                  f"register-file bits per copy; {n} trials, seed {seed}")
    results = []
    for i in range(n):
        results.append(await trial(dut, rng, flops, widths))
        if (i + 1) % 100 == 0:
            dut._log.info(f"{i + 1}/{n} trials")
    text = summarise(results, seed)
    dut._log.info("\n" + text)
    with open(os.path.join("sim_build", "tmr_faults_m.txt" if M_EXT else "tmr_faults.txt"), "w") as f:
        f.write(text)
    assert all(r["correct"] for r in results), "a single fault changed the TMR core's output"
    assert all((r["count"] > 0) == r["detected"] for r in results), \
        "the mismatch counter disagrees with the mismatch signal"
    # Feedback's job: a copy knocked off course by a pipeline fault is pulled
    # back into step. (A register-file bit in a register never written again
    # stays wrong by design; see the module docstring.)
    stuck = [r["where"] for r in results
             if r["detected"] and not r["regfile"] and not r["recovered"]]
    assert not stuck, f"pipeline faults not recovered: {stuck[:10]}"
