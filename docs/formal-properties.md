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
| 7 | S1–S4 stall correctness (§5.5): stall and redirect never coincide; a stall holds pc and IF/ID, bubbles ID/EX, and lasts exactly one cycle | `riscv_core` | `tb/formal/core.sby` | k-induction, holds from k = 2, run at 10 | **proven** | 4 / 4 |
| 8 | F1/F2 forwarding correctness (§5.5): EX's operands equal the architectural register values; L1: no instruction in EX ever needs an in-flight load result | `riscv_core` | same | k-induction, holds from k = 2, run at 10; needs invariant R1 | **proven** | 6 / 6 |
| 9 | X1 reset commits nothing (§5.5 "no X into committed state", the reset case): no register write and no store while `rst_i` is high | `riscv_core` | same | k-induction (with the above) | **proven** | 2 / 2 |
| 10 | B1/B2 branch flush correctness (§5.5): a bubble in any stage can do nothing; valid instructions retire in control-flow order, each at its predecessor's `pc_wdata` | `riscv_core` | same | k-induction, holds from k = 7, run at 10; no helper invariant | **proven** | 4 / 4 |
| 11 | SH1 no structural hazard on the register file ports (§5.5): a read of the register WB is writing returns WB's data, on each port | `riscv_core` | `tb/formal/core.sby` | k-induction; alone holds at k = 1 (combinational), run at 10 with the rest | **proven** | 2 / 2 |
| 12 | XP/XT no X into committed state, general case (§5.5): nothing left over from power-up is ever X in a register write, store, retirement or halt after reset | `riscv_core`, X-encoded by Yosys `xprop` | `tb/formal/xprop.sby` | XP: k-induction, holds from k = 7, run at 10, needs invariant XR. XT: BMC, depth 10 | **XP proven; XT pass (bounded)** | 5 / 5 |

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

### 7. Stall correctness (core, internal)

The first properties written **inside the RTL**: the `ifdef FORMAL` block at
the end of `rtl/core/riscv_core.sv`, beside the logic they describe. The
harness `tb/formal/core_formal.sv` supplies only the environment: free
instruction and load data, and one assumption — the first cycle is a reset.
The same block is compiled into every cocotb test with Verilator `--assert`,
so every simulated cycle checks it too.

| | Property |
|---|---|
| S1 | `!(stall && redirect)` — the Phase A "cannot coincide" claim |
| S2 | after a stall: `pc`, `if_id_pc_o`, `if_id_instr_o` unchanged |
| S3 | after a stall: ID/EX's six control bits all clear (a bubble) |
| S4 | after a stall: no stall (it lasts exactly one cycle) |

Covers, all after reset: a stall (step 3), a stall coinciding with a
misaligned-load trap (step 3), the cycle after a stall (step 4), and the
instruction that waited out a stall redirecting (step 5).

Shown to fail (2026-10-08):

| Planted fault | Result |
|---|---|
| stall no longer bubbles ID/EX | S3 fails, base case, step 4; in simulation, the same assertion stops the first load-use test at 40 ns |
| IF/ID not held on a stall | S2 fails (pc and instruction), step 4 |
| pc not held on a stall | S2 fails (pc), step 4 |

Two things learned writing these, both recorded so they are not relearned:

- **A cover is only evidence if the state it reaches is.** Unguarded, three
  of the four covers were "reached at step 0" — the arbitrary pre-reset state,
  where the solver simply chose ID/EX contents no reset produces. Covers now
  carry the assertions' guard (`f_past_valid`) and exclude reset cycles; the
  real steps are 3–5. And one cover was simply wrong: the waiting instruction
  reaches EX two cycles after the stall, not one — the unreached cover is
  what said so.
- **Induction needed no helper invariant.** A planned one (no ID/EX is both a
  load and a branch/jump) proved redundant: the proof holds from k = 2 with or
  without it, because ID/EX is rewritten every cycle and two steps of history
  exclude any state the decoder cannot produce. k = 1 fails with or without
  it — the `f_past_*` flops can start disagreeing with what they record. It
  was removed.

### 8. Forwarding correctness (core, internal)

For the instruction in EX, the architectural value of register *r* is its
value once every older instruction has committed. The older instructions in
flight are in EX/MEM and MEM/WB, so:

```
arch(r) = 0                      if r is x0
        = EX/MEM's result        if EX/MEM writes r   (youngest older writer)
        = MEM/WB's write-back    else if MEM/WB writes r
        = r's committed value    otherwise
```

F1/F2 assert `ex_rs1`/`ex_rs2` — the forwarding muxes' outputs — equal
`arch`, for every real instruction (RVFI's `id_ex_valid` skips bubbles),
outside reset. L1 asserts a load in EX/MEM never writes a register the
instruction in EX names: the stall's whole job, stated end to end.

Two techniques make it provable:

- **One arbitrary register.** `f_reg` is `anyconst` — chosen by the solver,
  fixed for the trace — with a shadow `f_shadow` of its committed value
  (updated from WB's writes). A proof for an arbitrary register is a proof
  for all 32, at a fraction of the cost. In simulation there is no solver,
  so Verilator builds track x1, the register the random programs and
  riscv-tests write most.
- **R1, a strengthening invariant:** once known, the shadow equals what the
  register file stores. Without it induction fails — a start state could have
  them disagree, and since a register can go unwritten for any number of
  cycles, no window length rules that out. The core's property block cannot
  reach the array by hierarchy, so `riscv_regfile` has a formal-only
  observation port (`f_raddr_i`/`f_rdata_o`, `ifdef FORMAL`).

Covers, all after reset: EX reads `f_reg` (≠ x0) forwarded from EX/MEM (step
4), from MEM/WB (step 5), and from the register file with the shadow known
(step 6), on each operand.

Shown to fail (2026-10-08):

| Planted fault | Result |
|---|---|
| older write wins (forwarding priority) | F1, step 5; in simulation, `test_younger_write_wins` stops at 50 ns on the same line |
| no load-use stall | L1, step 4 |
| writes to x0 forwarded | F2, step 4 |
| rs2's mux driven by rs1's select | F2, step 4 |
| **R1 removed** | **induction fails** — R1 is necessary, unlike the helper tried for S1 |

One property bug on the way: F1/F2 first applied during reset too. At a
mid-run reset the instruction in EX never commits, and X1 (below) had just
blocked MEM/WB's write, so "the value once older instructions commit" was
undefined there. The base case found it at depth 7; the guard is `!rst_i`.

### 9. Reset commits nothing (core, internal)

X1 asserts that while `rst_i` is high there is no register write and no
store. Unlike every other property here it is **not** gated on
`f_past_valid`: the state it guards against is exactly the arbitrary
power-up state before the first clock edge. Covers: a mid-run reset arriving
with a store, and with a register write, in flight — so the gating matters
after power-up too.

Shown to fail: removing the store's reset gate fails X1 at step 0.

### 10. Branch flush correctness (core, internal)

"No wrong-path instruction ever reaches WB" is stated as two halves, and
neither is enough alone:

| | Property |
|---|---|
| B1 | a stage whose RVFI valid bit is clear can do nothing. In ID/EX: no write to a register other than x0, no load or store, no branch, jump or halt. In EX/MEM: no register write, no load or store, no halt. In MEM/WB: no register write, no halt |
| B2 | every retirement outside reset has `pc == f_next_pc`: the reset vector after a reset, otherwise the previous retirement's `pc_wdata` |

**Why two.** The valid bits are a hand-kept copy of the flush logic, not
the flush itself. A design that let a wrong-path instruction through while
its valid bit was cleared would pass B2, since the instruction never shows
as a retirement, and it would still write a register. B1 ties the copy to the
design: whatever the valid bits drop, the design dropped. B1 alone says
bubbles are inert, not that wrong-path instructions are bubbles. B2 says
that, because a wrong-path instruction retiring valid carries the wrong pc.
The third leg is riscv-formal's `insn` checks, which prove each `pc_wdata`
is the spec's next pc. Together they say the stream that commits is the
program's control flow and nothing else.

B1 says "a register other than x0" because the flush puts a NOP into IF/ID,
and a NOP is `addi x0, x0, 0`, which decodes `rd_we = 1`. So a flushed
bubble legitimately carries `rd_we` with `rd = x0`.

B2 is riscv-formal's `pc_fwd` stated as an inductive property. `pc_fwd` is
a bounded check, clean for 25 cycles from reset. B2 holds forever.

**Induction depth.** k = 1–6 fail and k = 7 holds. The k = 6
counterexample is an unreachable start state: the pc register is two above
IF/ID's pc (both misaligned), which no reset, `+4` or masked target
produces. Two load-use stalls stretch it to six cycles before the bad pc
reaches WB. A finite k is enough because every such inconsistency drains.
IF/ID reloads from the pc on every non-stall cycle, a stall lasts one cycle
(S4), and past ID nothing holds. A helper invariant was tried, `pc ==
if_id_pc + 4` while IF/ID is valid and the core is not halted. It held, but
it lowered k only to 6, because the rest of the depth is the same drain
through ID/EX, EX/MEM and MEM/WB. It was removed, as S1's helper was. The
resume note had predicted invariants linking every stage's pc; none turned
out to be needed.

Covers, all after reset: a retirement directly after a taken transfer
(step 8), and a redirect squashing an instruction in ID that would have
acted: a register write, a store, a jump (step 3 each).

Shown to fail (2026-10-10):

| Planted fault | Result |
|---|---|
| redirect no longer flushes IF/ID's word; the valid bit still clears | B1 (ID/EX), step 5: the unflushed word issues as a bubble that can branch |
| redirect forgotten in IF/ID entirely, word **and** valid bit | **B2**, step 7: the wrong-path word retires as valid, at the wrong pc. B1 cannot see this one, because the copy is wrong in the same way as the design |
| redirect no longer bubbles ID/EX's control bits | B1 (ID/EX), step 4: a bubble with a register write |

### 11. No structural hazard on the register file ports (core, internal)

Most of this property holds by construction, so there is nothing to assert
for it. The register file has one write port, and WB is its only writer. It
has two read ports, and only ID's decoder drives them. No two stages ever
compete for a port, and two writes in one cycle cannot be expressed. An
assertion of either would pass without checking anything.

The one real hazard is the classic five-stage one: WB writes a register in
the same cycle that ID reads it. The register file's write-first bypass
resolves it, and SH1 asserts that it does. When WB writes rd ≠ x0, a read
of rd on either port returns WB's data. The read ports are combinational
from their inputs, so SH1 is not gated on `f_past_valid`. It holds in every
state, including the arbitrary first one. On its own it proves at k = 1.

F1/F2 already imply SH1, because a stale ID read reaches EX as a wrong
operand. SH1 checks it where it happens, one cycle earlier, and pins it on
the register file instead of the forwarding network.

Covers, after reset, on each port: a valid instruction in ID reads `f_reg`
in the cycle WB writes it, with WB's data different from the stored value,
so the bypass decides the read (step 5 each).

Shown to fail (2026-10-16):

| Planted fault | Result |
|---|---|
| write-first bypass removed from both read ports | SH1, step 5, on each port |
| same, with SH1 disabled | F2, step 6: the stale read reaches EX one cycle later |

### 12. No X into committed state, the general case (core, X-encoded)

X1 proves nothing commits while reset is held. This proves nothing left
over from power-up commits after reset.

**How X is modelled.** `xprop.sby` runs Yosys's `xprop` pass over the
flattened core. It gives every signal a second bit meaning "this bit is X"
and splits every port into a value half (`_d`) and an X-mask half (`_x`).
A flop with no reset powers up X. The harness `tb/formal/xprop_formal.sv`
drives the clock, reset and both memories' read data fully defined, since
the program is the environment's business, and asserts on the commit ports'
X masks. The encoding is pessimistic: a mux with an X select is X even when
both inputs agree. That can only add failures, never hide one.

**Two X sources, two claims.** Every pipeline flop that can reach a commit
is reset, so X from one is a design bug. The register file is deliberately
not reset (RV32I leaves x1–x31 undefined), so X from it is software reading
a register it never wrote, and a branch, address or result built on that
read is X too.

| | Property |
|---|---|
| XP | with the register file powering up arbitrary but defined, nothing committed is ever X after reset: register writes (enable, address, data), stores (enable, strobes, address, written lanes), retirements (valid, pc, instruction) and the halt. That is, every flop that can reach committed state is reset. **k-induction.** |
| XT | with the register file X as well, the same holds from reset until the first instruction that reads a register not written since that reset. Register-file X reaches committed state only through an instruction that read it. The next reset re-arms the check. **BMC, depth 10.** |

XR, the strengthening invariant, says no register holds X under XP, or no
register written since reset holds X under XT. Induction needs it for the
same reason as R1.

**Why XT is bounded.** XT's induction fails, and no depth fixes it by itself.
The counterexample starts with X in IF/ID's instruction word and in ID/EX's
control bits, which no reset produces, since instructions come from defined
memory. Ruling such states out needs invariants on every pipeline stage's X
masks, but in reachable states a stage *can* hold X control legitimately:
an instruction that read an undefined register and has not yet retired. The
harness sees ports only. XP carries the inductive claim about the design,
and XT is the bounded check that register-file X stays on the path
software chose.

"Read" is decided from the opcode, not RVFI's rs fields, which are raw
instruction bits (LUI's would name a register). Missing a real read shows as
a false failure, not a false pass.

**Induction depth (XP).** k = 1–6 fail and k = 7 holds. The k = 6
counterexample was not analysed.

**Pitfall in the flow: the optimiser can hide X.** Yosys's `opt` treats a
flop with no init value as don't-care and may fold it to a constant. The
first version ran `opt -fast` before `xprop`. A planted fault, `halted_q`
unreset, then passed in one second: the optimiser had chosen init 1, so the
core was permanently halted and nothing ever committed. The flow now runs no
`opt` before `xprop` and turns every free-init flop into `$anyinit` right
after it. The same fault then fails at step 4.

**An approach that did not scale.** The first version compared two copies of
the core started from independent arbitrary states (a miter). Yices,
Bitwuzla, Boolector and ABC PDR all stalled at step 8 or 9, where the first
instructions after reset retire: an SMT solver has to prove the two
datapaths equal with no structural sharing. Making both register files
start equal did not help. The single-copy X encoding runs BMC to depth 10 in
about 3 minutes and proves XP in about 90 seconds.

Covers (XT's harness), all reached: X at power-up, an unreset view of the
halt (step 0); X in the pipeline while nothing committed is X, an ID/EX
operand read from an unwritten register (step 3); a store (step 4); the check
stopping on a read of an undefined register (step 5); a register-register
instruction writing a result from two defined nonzero sources (step 6).

Shown to fail (2026-10-16), each in both tasks:

| Planted fault | Result |
|---|---|
| `ex_mem_rd_we_o` loses its reset | XP and XT, step 2: an X register-write enable |
| `halted_q` loses its reset | XP and XT, step 4: an X register-write enable, through the freeze and the bubble logic |
| `halted_q` unreset, before the flow fix above | **passes**, because the optimiser fixed the flop's init (the `ex_mem_rd_we_o` fault was caught even then) |

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

### 2. Reset could store power-up garbage into data memory (2026-10-08)

**Found by:** a forwarding cover reached implausibly early — "a register
read with the shadow known" at step 3, before any instruction could have
committed. The trace showed why, and X1 was written to pin it.

**Counterexample:** step 0, `rst_i` high, the pipeline registers holding
power-up values: MEM/WB asserted a register write, and EX/MEM can likewise
assert a store. Reset clears both registers only *at the end* of the reset
cycle, and neither write port was gated by reset, so the register file
and — the serious half — **data memory** took a write of garbage during
reset. RV32I leaves x1–x31 undefined at reset; memory it does not: it holds
the program's data.

**Why simulation missed it:** Verilator initialises all state to zero, so
MEM/WB and EX/MEM power up holding no write. On the FPGA it cannot happen
either — Xilinx flops power up to their INIT value, 0. On an ASIC flops power
up random: the LibreLane chip (§6.4) could have corrupted memory on every
reset.

**Fix:** `dmem_we_o`/`dmem_wstrb_o` and `wb_rd_we_o` are ANDed with
`!rst_i`. X1 now proves it.
