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

## Bugs formal found that simulation missed

None yet. Each entry goes here with the property, the counterexample, and
why simulation did not see it (CLAUDE.md §5.5).
