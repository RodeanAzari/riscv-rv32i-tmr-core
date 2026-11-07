"""The official riscv-tests rv32ui suite, on the core (a Phase A box).

Each test is assembled from the pinned submodule sw/riscv-tests with this
core's own environment, sw/riscv-tests-env/ -- upstream's needs CSRs and
traps, which this core does not have. The test bodies are unmodified.

A test ends in ECALL, which halts the core; gp then holds 1 for a pass or
(n << 1) | 1 for a failure at test case n. Two independent verdicts are
checked for each test:

  1. The suite's own: gp == 1 at the halt.
  2. Every retirement against the golden model, through RVFI -- the same
     check the random programs get. A test can pass on a wrong core if the
     wrong result happens to satisfy its check; this cannot.

The model must also pass each test on its own. If it does not, the model is
wrong, and that is reported as such rather than blamed on the core.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import cocotb

from rv32i_model import run_model
from test_core import check_rvfi, final_regs, run

REPO = Path(__file__).resolve().parents[2]
SUITE = REPO / "sw" / "riscv-tests"
ENV = REPO / "sw" / "riscv-tests-env"
BUILD = Path(__file__).resolve().parent / "sim_build" / "riscv-tests"

# Upstream tests that do not apply to this core, and why. Everything else in
# upstream's rv32ui list runs. Kept as a list with reasons rather than a
# silent filter, and checked against upstream below, so a renamed or removed
# test cannot quietly turn an exclusion into nothing.
EXCLUDED = {
    "fence_i": "FENCE.I is Zifencei, not one of the 40 RV32I instructions "
               "(CLAUDE.md 5.1); the test rewrites its own code, which "
               "separate instruction and data memories cannot see",
    "ma_data": "misaligned loads and stores, expecting each to succeed or "
               "to trap into a handler that emulates it; this core traps by "
               "halting, as it has no handler (PROGRESS.md, Decisions)",
}


def upstream_tests():
    """The rv32ui test names, read from upstream's own Makefrag."""
    text = (SUITE / "isa" / "rv32ui" / "Makefrag").read_text()
    block = re.search(r"rv32ui_sc_tests\s*=\s*\\\n(.*?)\n\s*\n", text, re.S)
    assert block, "rv32ui_sc_tests not found in Makefrag -- upstream changed shape"
    return block.group(1).replace("\\", " ").split()


if not (SUITE / "isa").is_dir():
    raise RuntimeError(f"{SUITE} is empty: run `git submodule update --init`")
_upstream = upstream_tests()
_stale = set(EXCLUDED) - set(_upstream)
if _stale:
    raise RuntimeError(f"excluded tests no longer upstream: {sorted(_stale)}")
RV32UI = [t for t in _upstream if t not in EXCLUDED]


def toolchain_prefix():
    """RISCV_PREFIX, else the local riscv32 toolchain, else a riscv64 one on
    PATH (CI's distro package). Either builds RV32I: -march/-mabi decide the
    target, and these tests link no libraries."""
    if "RISCV_PREFIX" in os.environ:
        return os.environ["RISCV_PREFIX"]
    local = Path.home() / "riscv-toolchain" / "bin" / "riscv32-unknown-elf-"
    if Path(f"{local}gcc").exists():
        return str(local)
    for prefix in ("riscv32-unknown-elf-", "riscv64-unknown-elf-"):
        if shutil.which(f"{prefix}gcc"):
            return prefix
    raise RuntimeError("no RISC-V gcc found: set RISCV_PREFIX")


# The M extension's suite (Phase H): runs only on a core built with M_EXT = 1
# (the Makefile's *_m builds export M_EXT=1). Upstream's list, nothing excluded.
M_EXT = os.environ.get("M_EXT") == "1"


def upstream_rv32um():
    text = (SUITE / "isa" / "rv32um" / "Makefrag").read_text()
    block = re.search(r"rv32um_sc_tests\s*=\s*\\\n(.*?)\n\s*\n", text, re.S)
    assert block, "rv32um_sc_tests not found in Makefrag -- upstream changed shape"
    return block.group(1).replace("\\", " ").split()


RV32UM = upstream_rv32um()


def build(name, suite="rv32ui"):
    """Assemble one test and return its flat image as {byte address: word}.

    -march=rv32i, nothing more: the assembler rejects any instruction outside
    the base set, so no CSR access or extension can slip into a test and
    execute here as a silent NOP.
    """
    prefix = toolchain_prefix()
    BUILD.mkdir(parents=True, exist_ok=True)
    elf, binary = BUILD / f"{suite}-{name}.elf", BUILD / f"{suite}-{name}.bin"
    march = "rv32im" if suite == "rv32um" else "rv32i"
    subprocess.run([f"{prefix}gcc", f"-march={march}", "-mabi=ilp32", "-static",
                    "-nostdlib", "-nostartfiles",
                    f"-I{ENV}", f"-I{SUITE / 'isa' / 'macros' / 'scalar'}",
                    f"-T{ENV / 'link.ld'}", "-o", str(elf),
                    str(SUITE / "isa" / suite / f"{name}.S")],
                   check=True, capture_output=True, text=True)
    subprocess.run([f"{prefix}objcopy", "-O", "binary", str(elf), str(binary)],
                   check=True)
    data = binary.read_bytes()
    data += bytes(-len(data) % 4)
    return {a: int.from_bytes(data[a:a + 4], "little") for a in range(0, len(data), 4)}


@cocotb.test()
@cocotb.parametrize(name=RV32UI)
async def test_rv32ui(dut, name):
    image = build(name)
    # Harvard: the same image behind both ports, as two BRAMs loaded from
    # one file. The program is the image as a word list for IMEM.
    program = [image.get(4 * i, 0) for i in range(max(image) // 4 + 1)]

    want_rvfi = []
    _, model = run_model(program, image, traces=want_rvfi)
    assert model.halted, f"model: {name} never reached its ecall"
    assert model.x[3] == 1, (
        f"MODEL fails {name} at test case {model.x[3] >> 1} -- the model is wrong")

    got_rvfi = []
    writebacks, _ = await run(dut, program, dict(image),
                              cycles=3 * len(want_rvfi) + 20, rvfi=got_rvfi)
    assert int(dut.halt_o.value), f"{name}: core never halted"
    gp = final_regs(writebacks).get(3, 0)
    assert gp == 1, f"{name}: fails at test case {gp >> 1} (gp = {gp:#x})"
    stats = check_rvfi(got_rvfi, want_rvfi)
    dut._log.info(f"{name}: pass; {stats}")


# Defined only on an M build, so RV32I builds do not report 8 skips each.
if M_EXT:
    @cocotb.test()
    @cocotb.parametrize(name=RV32UM)
    async def test_rv32um(dut, name):
        """rv32um on an M core, judged both ways as test_rv32ui is. A divide is
        34 cycles in EX, hence the larger budget."""
        image = build(name, "rv32um")
        program = [image.get(4 * i, 0) for i in range(max(image) // 4 + 1)]
        want_rvfi = []
        _, model = run_model(program, image, traces=want_rvfi, m_ext=True)
        assert model.halted and model.x[3] == 1, f"MODEL fails {name} -- the model is wrong"
        got_rvfi = []
        writebacks, _ = await run(dut, program, dict(image),
                                  cycles=40 * len(want_rvfi) + 20, rvfi=got_rvfi)
        assert int(dut.halt_o.value), f"{name}: core never halted"
        gp = final_regs(writebacks).get(3, 0)
        assert gp == 1, f"{name}: fails at test case {gp >> 1} (gp = {gp:#x})"
        dut._log.info(f"{name}: pass; {check_rvfi(got_rvfi, want_rvfi)}")
