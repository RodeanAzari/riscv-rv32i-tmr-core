# Progress Log

Running context for this project. Read this first at the start of a session to
know where things stand. Update it at the end of any session that changed
meaningful state.

**Repo:** https://github.com/RodeanAzari/riscv-rv32i-tmr-core (private)
**Local:** `~/riscv-rv32i-tmr-core`
**Phase:** A — working core (first slice done: PC + IF)

---

## Where things stand

### Working and verified

| Check | Result |
|---|---|
| `make lint` | clean, Verilator 5.050 |
| `make sim` | 3/3 passing |
| `make synth` | routes clean, 0 errors, ~40 s |
| CI on push | green (lint + sim) |

### Implemented

`rtl/riscv_core.sv` (43 lines) — PC register and IF stage only.

- PC resets to `0x0000_0000`, advances `pc + 4`
- IMEM is an **external port**, synchronous read, 1-cycle latency — matches
  BRAM timing on the Arty A7 so Phase D bring-up needs no rewrite
- IF/ID resets to a NOP (`0x0000_0013`) so ID never sees X on cycle one
  (heads off the X-propagation failure mode in plan §3.6)
- `if_id_pc` / `if_id_instr` exposed as outputs for ILA probing later

`tb/test_core.py` (59 lines) — 3 cocotb tests: reset state, PC sequencing,
IF/ID capture against a 4-instruction program.

`scripts/setup-vivado-env.sh`, `constr/core_ooc.xdc`, `syn/synth_ooc.tcl` —
out-of-context synthesis and implementation of the core alone, no board-level
top yet. Runs through `route_design` because post-synthesis timing is an
estimate and post-route is measured.

### Baseline, 2026-09-05 (PC + IF only, `xc7a100tcsg324-1`)

| | |
|---|---|
| Constraint | 10.000 ns (100 MHz, the Arty's oscillator) |
| WNS | +7.338 ns |
| Fmax | 375.7 MHz |
| LUT | 2 / 63,400 |
| FF | 92 / 126,800 |
| CARRY4 | 8 |
| BRAM / DSP | 0 / 0 |

The FF count is a useful correctness check on the flow: 3 x 32 = 96 registers
in the RTL, minus 4 that constant-fold away because `pc[1:0]` and
`if_id_pc[1:0]` are always zero on a `pc + 4` increment. 92 is right.

**Fmax here is not a board number.** Out-of-context leaves `HD.CLK_SRC` unset,
so Vivado cannot estimate clock delay or skew; read it as the logic limit. Its
value is as a *tracking* baseline — re-run `make synth` as each pipeline stage
lands and watch what the critical path does.

### Not started

Everything else: ID, EX, MEM, WB, register file, hazard unit, forwarding,
formal, UVM, TMR, hardware bring-up.

---

## Toolchain

| Tool | Version | Location |
|---|---|---|
| Verilator | 5.050 | `~/.local/bin/verilator` (built from source; tree at `~/.local/src/verilator`) |
| cocotb | 2.0.1 | `~/cocotb-env` |
| riscv gcc | 16.1.0 | `~/riscv-toolchain/bin/riscv32-unknown-elf-gcc` |
| spike | — | `~/riscv-toolchain/bin/spike` |
| gh CLI | 2.100.0 | `~/.local/bin/gh`, authed as RodeanAzari |
| **Vivado** | 2025.2 | `~/Xilinx/2025.2/Vivado` — ML Standard, no license file. Run `vivado-env` first |
| **yosys / SymbiYosys** | — | **not installed** — needed for Phase B |

`~/.local/bin` is first on PATH, so the source-built Verilator shadows the
Debian 5.032 package automatically.

### Environment gotchas

- **`sudo` cannot prompt for a password through Claude Code** (no TTY). Anything
  needing root must be run in a separate WSL terminal.
- **Vivado needs `libncurses.so.5`, which Ubuntu 26.04 does not package.**
  Symptom is nastier than a missing-library error: batch runs **hang at 0% CPU
  with no output** instead of failing. Fixed with compat symlinks onto
  ncurses 6 in `~/.local/lib/vivado-compat`, which `vivado-env` puts on
  `LD_LIBRARY_PATH`. Details in vivado-setup.md §3.
- **Vivado 2026.1 forced `LC_ALL=en_US.UTF-8`**, which Ubuntu does not
  generate, and crashed on launch. Worked around without root via `~/.locale`
  and `LOCPATH`. 2025.2 does not have this problem; the workaround is retained
  anyway since the other Xilinx binaries are unchecked.
- Debian's Verilator is 5.032, below cocotb 2.x's 5.036 floor. This is why
  Verilator was built from source both locally and in CI.

---

## Build targets

| Target | Does | State |
|---|---|---|
| `make lint` | Verilator lint of `rtl/` | working |
| `make sim` | cocotb regression | working |
| `make sw` | build `sw/*.c` → `.elf` / `.hex` | untested, no source yet |
| `make spike` | run `.elf` on spike | untested, no source yet |
| `make synth` | OOC synth + impl of the core, reports to `docs/reports/` | working |
| `make prog` | — | not written, blocked on USB passthrough (§6 of vivado-setup.md) |

---

## CI

`.github/workflows/ci.yml`, single `verilate` job: builds Verilator 5.050 from
source, caches it on key `verilator-Linux-v5.050`, installs cocotb from
`tb/requirements.txt`, then runs lint and sim.

First run took 11m53s (the compile). Cached runs should be under a minute.
Bumping `VERILATOR_VERSION` forces a rebuild.

**Not in CI:** synthesis. Vivado is large and slow; a self-hosted runner may be
the honest answer rather than pretending it fits on a hosted one.

---

## Decisions made, and why

- **`~/Xilinx` over `/tools/Xilinx`** for the pending Vivado install — avoids
  needing root, which is awkward here.
- **Never source `settings64.sh` in `.bashrc`** — it shadows system libraries
  and breaks `git`/`curl`. Use an opt-in `vivado-env` shell function.
  Details in [vivado-setup.md](vivado-setup.md).
- **IMEM external to the core** rather than an internal array — BRAM-shaped
  from the start.
- **Target part is `xc7a100tcsg324-1`** — the board is an **Arty A7-100T**
  (confirmed 2026-09-05). 63,400 LUTs / 126,800 FFs / 135 BRAM / 240 DSP; these
  are the denominators for every utilization percentage in the README. The
  100T's headroom matters for Phase E: three core copies plus a voter would be
  tight on a 35T's 20,800 LUTs.
- **Pinned to Vivado 2025.2, not the latest** (decided 2026-09-04). AMD made
  the free tier Windows-only in **2026.1** and put it on annual renewal; a
  Linux 2026.1 seat costs ~$1,200–$1,800/yr. Everything up to 2025.2 keeps
  Vivado ML Standard free on Linux with no license file. 2026.1 was installed
  first (63 GB) before this surfaced — `vlm` shows no free option on Linux,
  only a 60-day trial. The trial was rejected: it expires mid-Phase-D. Nothing
  in Phase D needs a 2026.1 feature.
- **Repo named `riscv-rv32i-tmr-core`** — puts the differentiator (TMR) in the
  name rather than burying it.
- **Private until there's something to show**, then flip:
  `gh repo edit --visibility public`.

---

## Next up

1. **ID stage + register file** — next slice of Phase A. Where load-use hazard
   groundwork starts; plan §3.6 flags it as the thing students most often get
   wrong, so it wants directed tests before random ones. Re-run `make synth`
   after it lands to see what the register file does to the critical path.
2. **Board-level top** — deferred until the core executes instructions:
   `constr/arty_a7.xdc` pin constraints, a top with BRAM instruction memory and
   clocking, then `make prog`. Only then does Fmax become a board number.

---

## How to maintain this file

Update at the end of any session that changed meaningful state. Keep it a
snapshot of *current* reality, not an append-only diary — stale claims here are
worse than no file. Specifically:

- Move items between "Implemented" and "Not started" as they land
- Re-run `make lint` and `make sim` and record what actually happened, not what
  should have
- Add decisions with their rationale, since the reasoning is the part that
  gets forgotten
- Update the toolchain table when anything is installed or upgraded

---

*Last updated: 2026-09-05 — Vivado 2025.2 ML Standard installed and verified,
and `make synth` landed: out-of-context synth + impl of the core with committed
reports. Baseline recorded above. Next slice is the ID stage.*
