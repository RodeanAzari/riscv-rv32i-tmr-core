# Formal properties

Every property proven in this repo: what it claims, how it is proven, how
deep, and how it is known not to pass vacuously (CLAUDE.md §5.5, §8 Phase B).
Updated in the same commit as the property. Numbers come from the SymbiYosys
logs in `tb/formal/build/<job>_<task>/logfile.txt`, produced by `make formal`.

Tools: OSS CAD Suite **2026-10-07** — Yosys 0.69+208, SymbiYosys 0.69, Yices
2.7.0 — the same bundle locally and in CI.

## How to read this

- **prove** is k-induction, two checks that must both pass. The **base case**
  is a bounded model check: from the initial state, no assertion fails in the
  first *k* cycles. The **inductive step** starts from *any* state, reachable
  or not, and shows *k* passing cycles imply a passing next one. Together
  they cover every reachable state, forever — a proof, not a long clean run.
  An induction failure on a true property means the step started from an
  unreachable state; the fix is a stronger invariant, never a deeper *k*
  alone.
- **cover** asks the solver for a trace reaching each `cover()`. Every
  scenario that could break a property is a cover; an unreached one fails the
  run, so a property cannot pass because its condition never arises.
- **Shown to fail**: a fault planted in the RTL, and the property catching it.
  A property that has never failed has not been shown to check anything.

## Properties

| # | Property | Module | Job | Method, depth | Result | Covers reached |
|---|---|---|---|---|---|---|
| 1 | x0 invariance: a read of x0 returns 0, on both ports, every cycle | `riscv_regfile` | `tb/formal/regfile_x0.sby` | k-induction, k = 4 | **proven** | 4 / 4 |
| 2 | riscv-formal ISA compliance, all 37 checkable RV32I instructions (`insn_*`) | `riscv_core` | `tb/formal/rvfi/checks.cfg` | BMC, check cycle 15 | **pass, 37/37** | 4 / 4 each |
| 3 | riscv-formal `reg`: every register read returns the last value written | `riscv_core` | same | BMC, cycles 15–25 | **pass** | — (shown to fail) |
| 4 | riscv-formal `pc_fwd` / `pc_bwd`: consecutive retirements chain their pcs | `riscv_core` | same | BMC, cycles 10–25 | **pass** | — (`pc_fwd` shown to fail) |
| 5 | riscv-formal `unique`: no `rvfi_order` index used twice | `riscv_core` | same | BMC, cycles 1–25 | **pass** | — (shown to fail) |
| 6 | riscv-formal `causal`: no instruction reads a result its producer has not yet written | `riscv_core` | same | BMC, cycles 10–25 | **pass** | — (not yet shown to fail) |

### 1. x0 invariance (register file)

Harness `tb/formal/regfile_x0_formal.sv` wraps the register file with every
input free and asserts on the read ports. The array has no reset, so its
initial contents — x0's storage included — are free as well.

Covers: a nonzero write to x0 in the same cycle as a read of x0 (the bypass
path), on each port, reached at step 0; a read of x0 after an earlier nonzero
write to it (the storage path), on each port, reached at step 1.

Shown to fail (2026-10-08):

| Planted fault | Result |
|---|---|
| rs1 port loses its x0 test | base case fails: the free initial array puts a nonzero value in x0's storage — the reset-less case a simulator's zeroed state never shows |
| bypass ahead of the x0 test, x0 writes ungated | base case fails on rs2: a same-cycle write leaks |
| x0 writes ungated, read test kept | **passes, correctly**: the read mux zeroes x0 first, so a dirty x0 is invisible at the ports. The write gate is defence in depth, not observable here |
| harness cover that cannot happen | cover task fails: the vacuity guard works |

### 2–6. riscv-formal (core, through RVFI)

`tb/formal/rvfi/wrapper.sv` drives the core for riscv-formal's checkers with
**both memories free**: a new arbitrary instruction word and load value every
cycle. There is no program and no memory model — every instruction sequence
is explored, and the checks relate what RVFI reports to the ISA spec.
`RISCV_FORMAL_ALIGNED_MEM`: lane-style memory fields, misaligned accesses
trap. Run by `scripts/riscv-formal.sh` from `make formal`; riscv-formal is a
submodule at `c992aa6` (2026-07-16).

What each kind of check can and cannot see — learned the hard way, by
mutation:

- **`insn_*`** checks that the retiring instruction's results follow the spec
  *from the operand values RVFI reports*. A pipeline that forwards the wrong
  value reports that wrong value faithfully, and the arithmetic on it is still
  right — so wrong forwarding priority and a missing load-use stall both
  **pass every `insn` check**.
- **`reg`** is what catches them: the value reported read from a register
  must equal the value last reported written to it. It failed on the
  older-write-wins forwarding bug, a missing load-use stall, and a stall
  bubble that kept `rd_we` — none of which any `insn` check saw.
- The depths follow VexRiscv's 5-stage configuration in riscv-formal. The
  first retirement is possible at cycle 5, so a check at 15 has ~10 cycles of
  arbitrary history in flight — every forwarding and stall combination.

**Reachability:** the same configuration is generated again with `mode
cover`, so every `cover()` in riscv-formal's checkers must be reached. Each
`insn` check carries four, the last being "this instruction retires at the
check cycle, untrapped"; all 37 reach 4/4. `reg`, `pc_*`, `unique` and
`causal` contain no covers, so their evidence is the planted faults below.

Shown to fail (2026-10-08), each against all 42 checks:

| Planted fault | Failing checks |
|---|---|
| older write wins forwarding (rs1) | `reg` |
| no load-use stall | `reg` |
| stall bubble keeps `rd_we` | `reg` |
| writes to x0 forwarded | all 37 `insn`, `reg` |
| misaligned taken target does not trap | all 8 branch/jump `insn` |
| `rvfi_pc_wdata` always pc + 4 | 8 branch/jump `insn`, `pc_fwd` |
| redirect does not flush IF/ID | `pc_fwd`, `reg` |
| `rvfi_order` never advances | `unique` |
| `rvfi_order` counts bubbles (gaps) | **none** — riscv-formal's RVFI spec forbids gaps but no check enforces it; the cocotb RVFI monitor does (`order == i`) |

**Not enabled, deliberately:** `ill` (requires the all-zero word to trap;
this core decodes non-RV32I words inert — a decision of its own),
`liveness` and `hang` (need a fairness assumption and thought about the
halt), the `bus_*` checks (need `RISCV_FORMAL_BUS` signals). **Not yet shown
to fail:** `pc_bwd`, `causal`.

Runtime: ~1 min for both passes on 16 cores; `reg` dominates (~46 s).

## Bugs formal found that simulation missed

### 1. Yosys drops a `~` on a size cast: jump targets unmasked (2026-10-08)

**Found by:** riscv-formal, first run — 8 of 37 `insn` checks failed: every
branch, JAL and JALR.

**Counterexample:** `jalr x1, 1(x0)` must jump to `(0 + 1) & ~1 = 0`. The core
reported `pc_wdata = 1`, and the next instruction retired at pc 1.

**Cause:** the redirect target was `target_sum & ~XLEN'(2'b11)`. Yosys 0.69
binds that `~` to the cast's *width* (`XLEN`) rather than to the cast, so the
mask came out as `0x3`, not `0xFFFFFFFC` — confirmed on a 4-line module with
`sat -show`. `~(XLEN'(2'b11))` evaluates correctly, as does every spelling in
Verilator and Vivado.

**Why simulation missed it:** simulation runs on Verilator and synthesis on
Vivado, and both read the RTL as intended. Only Yosys mis-built it — and
Yosys is the front end of riscv-formal **and of the LibreLane ASIC flow**
(§6.4). Without this check, ASIC run #1 would have produced a core whose
jumps land on unaligned pcs.

**Fix:** `{target_sum[XLEN-1:2], 2'b00}` — no cast, no precedence question.
The RTL had exactly one size cast.
