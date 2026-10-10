# Progress Log

Running context for this project. Read this first at the start of a session to
know where things stand. Update it at the end of any session that changed
meaningful state.

**Repo:** https://github.com/RodeanAzari/riscv-rv32i-tmr-core (private)
**Local:** `~/riscv-rv32i-tmr-core`
**Phase:** B — formal verification, started 2026-10-08 (riscv-formal passing: 37 instructions + reg/pc/unique/causal). Phase A **done** 2026-10-08, CI run 37817380686

---

## Where things stand

**Position: Phase A complete; every box in CLAUDE.md §8 checked.** The core executes
straight-line programs end to end: results write back to the register file in
WB, and loads and stores go through an external, BRAM-timed data memory port.
The temporary `wb_rd_*_i` testbench port is gone; tests set registers by
executing instructions.

Working today: **all 40 RV32I instructions** — every ALU instruction,
`lui`, `auipc`, all eight loads and stores, all six branches, `jal`,
`jalr`, `fence`, `ecall` and `ebreak` — with full data-hazard handling (EX/MEM→EX and MEM/WB→EX forwarding,
WB→ID through the register file, a one-cycle load-use stall) and branches
resolved in EX with static not-taken prediction: a taken branch or jump
flushes IF/ID and ID/EX and costs two cycles, not taken costs none.
**Every exception halts the core** — ECALL, EBREAK, a misaligned load or
store, a misaligned taken branch or jump target (no trap machinery is in
scope); FENCE is a NOP, which is complete on this core. The official **`riscv-tests` rv32ui
suite passes: 40 of 42**, the other two excluded with reasons (see
Decisions).

**Timing margin: +0.317 ns at 100 MHz out-of-context (103.3 MHz)**. Thin, and the paths that cross the memory
ports are not yet timed at all. The critical path is branch resolution fed by
the MEM/WB forward of the writeback mux. See the synthesis trend notes.

Both memories are now BRAM-timed in the testbench as well as in the design.
The IF timing bug found during MEM + WB is fixed — see Decisions.

`make lint`, `make sim` and `make synth` all pass locally, and lint and sim
pass in CI — including the official suite, assembled there by Ubuntu's
GCC 13.2 / binutils 2.42 rather than the local GCC 16.

### Working and verified

| Check | Result |
|---|---|
| `make lint` | clean, Verilator 5.050 |
| `make sim` | 168/168 passing across 7 toplevels (core, alu, regfile, decoder, mem_align, hazard, branch), including the 40 official `riscv-tests` |
| `make synth` | routes clean, 0 errors, ~40 s |
| `make formal` | x0 invariance, stall correctness (S1–S4), forwarding (F1/F2/L1), reset-commits-nothing (X1) and branch-flush correctness (B1/B2) proven by k-induction; **riscv-formal 42/42 checks and 42/42 cover runs** (37 `insn`, `reg`, `pc_fwd`, `pc_bwd`, `unique`, `causal`), ~1 min — see [formal-properties.md](formal-properties.md) |
| CI on push | green (lint + sim, 164/164, all 40 rv32ui ran) at `c9267af`; the formal job is new and unproven there |

### Implemented

`rtl/core/riscv_core.sv` — IF (PC, fetch, IF/ID), ID (decoder, register file,
ID/EX), EX (operand selection, ALU, EX/MEM), MEM (DMEM port, store alignment,
MEM/WB) and WB (load alignment, writeback mux).

- PC resets to `0x0000_0000`, advances `pc + 4`
- **Synchronous, active-high `rst_i`** per CLAUDE.md §4 — flops map to FDRE/FDSE
  on their dedicated SR pin, with no inverter and no async recovery/removal arc
- IMEM is an **external port**, synchronous read, 1-cycle latency — matches
  BRAM timing on the Arty A7 so Phase D bring-up needs no rewrite. The core
  presents **`pc_next`** (the reset vector during reset), so the BRAM and the
  pc register latch the same address on the same edge
- IF/ID resets to a NOP (`0x0000_0013`) so ID never sees X on cycle one
  (heads off the X-propagation failure mode in CLAUDE.md §9)
- `if_id_pc_o` / `if_id_instr_o` / `id_ex_*` exposed as outputs for ILA probing
  later, and carrying the RVFI shadow fields — see [rvfi-plan.md](rvfi-plan.md)
- **DMEM is an external port** — word-aligned address straight off the EX/MEM
  register, byte strobes, synchronous read. Load data arrives in WB and is
  **not** re-registered in MEM/WB: the BRAM's output register already is that
  pipeline register for it
- WB's register write is exposed as `wb_rd_*_o` **outputs** — what the
  directed tests observe
- **RVFI port** (`rvfi_*_o`, all §5.4 fields) under `` `ifdef RISCV_FORMAL ``:
  defined for lint (which runs both ways) and simulation, not for synthesis.
  A valid bit rides the pipeline so bubbles never retire; rs1/rs2 values are
  tapped after the forwarding muxes; memory fields are lane-style. Details in
  [rvfi-plan.md](rvfi-plan.md)
- **Branches and jumps resolve in EX.** `redirect` (a jump, or a branch whose
  condition holds) puts `redirect_target` on `pc_next`, so the pc and the BRAM
  take the target on the same edge, flushes IF/ID to a NOP and inserts a
  bubble into ID/EX — the two younger words already fetched. Redirect outranks stall in the `pc_next`
  mux, though the two cannot coincide (see Decisions). The target is a
  dedicated adder, `(jalr ? rs1 : pc) + imm` on the **forwarded** rs1, with
  bits [1:0] masked off. A jump's link address `pc + 4` replaces the ALU
  result going into EX/MEM, so it forwards like any other result
- **ECALL and EBREAK halt, resolved in EX** like a branch, so a wrong-path
  one is flushed rather than obeyed. From the cycle one reaches EX, `freeze`
  holds the pc and bubbles ID/EX every cycle; everything older still retires,
  and **`halt_o`** rises the cycle after the halting instruction leaves WB —
  architectural state is final when it is seen. Sticky until reset. RVFI
  marks that retirement `trap` and `halt`
- **Misaligned accesses and targets trap — and so halt — in EX** too: a load
  or store whose address is not a multiple of its size, or a *taken* branch
  or jump whose target has bit 1 set (JALR clears bit 0 first). Detected from
  bits [1:0] of the ALU and target adders; the instruction's register write,
  store and load are dropped going into EX/MEM. A misaligned access joins
  `freeze` the same cycle; a misaligned target does not need to — it is a
  redirect, which already flushes — so the slow branch comparator stays off
  `freeze`, and `halted_q` holds everything from the next cycle

`rtl/core/riscv_decoder.sv` — register addresses, all five RV32I immediate
formats (I/S/B/U/J), the EX control signals, `branch`/`jump`/`jalr`,
`mem_read`/`mem_write`/`mem_funct3`, and `halt` — the two exact ECALL/EBREAK
words, so CSR accesses, MRET and WFI stay inert. `mem_funct3` is `instr[14:12]`
unconditionally, so it also carries a branch's condition. `mem_read` remains
the only writeback select: a jump's link address enters in EX, not WB.

`rtl/core/riscv_branch.sv` — the branch condition from funct3 and the two
forwarded operands. One magnitude comparison serves BLT and BLTU: when the sign
bits agree, signed and unsigned order are the same; when they differ, the
operand with its sign bit set is smaller. Reserved funct3 010/011 never take.

`rtl/core/riscv_hazard.sv` — forwarding selects and load-use detection, both
decided **in ID**, purely combinational. The selects compare ID's rs1/rs2
against ID/EX's and EX/MEM's rd — the instructions that will be in EX/MEM and
MEM/WB when the consumer reaches EX, which is exact because every stage past
ID always advances — and the core registers them into ID/EX, so EX's muxes
switch off flops. When ID does not advance (stall, redirect) the selects land
in a bubble and ID decides again next cycle. One-hot per operand with priority
already resolved (the ID/EX producer wins: the younger write), so the core
holds no second copy of an encoding. Writes to x0 are never forwarded. The stall
compares the rs1/rs2 **fields** whether or not the instruction uses them — a
false match costs a cycle, never correctness. In the core, a stall holds the
pc and IF/ID (the pc mux re-presents `pc`, so the BRAM re-reads the word it
holds) and inserts a bubble into ID/EX. Store data in EX/MEM is the
**forwarded** rs2.

**A bubble clears six bits, not the whole of ID/EX:** `rd_we`, `mem_read`,
`mem_write`, `branch`, `jump`, `halt` — the only fields that can act. The rest hold the
squashed instruction's values, which compute a result nothing writes. So
`id_ex_pc_o`/`id_ex_instr_o` show the squashed instruction during a bubble,
not a NOP; RVFI's valid bit has to distinguish bubbles regardless. Each of the
six is pinned by a test that fails if it is left set: notably `mem_read`
(a stall bubble copying `lw x1, 0(x1)` would stall on itself forever) and
`branch` (a stall bubble would evaluate the branch on the load's *address*
forwarded from EX/MEM; a redirect bubble would redirect a second time), and
`halt` (EBREAK's rs2 field is 1, so after `lw x1` it stalls, and a bubble
copy keeping the bit halts a cycle early and flushes the real EBREAK).

`rtl/core/riscv_mem_align.sv` — byte lanes for both directions: stores
replicate data across lanes and raise strobes; loads pick the lane and sign- or
zero-extend. One module so the little-endian lane convention lives in one
place. Only ever sees aligned accesses: misaligned ones trap in EX first.

`rtl/core/riscv_alu.sv` — the ten RV32I arithmetic/logic operations. Selected by
the ISA's own `funct3` plus the ADD/SUB and SRL/SRA "alt" bit rather than a
private enum, so there is no second copy of an encoding to drift, and no
SystemVerilog package — which CLAUDE.md §4 flags as a Yosys risk, and which
could not be checked when this was written. Yosys has since been installed and
elaborates the whole core cleanly (see Toolchain).

`rtl/core/riscv_regfile.sv` — 32 x 32, two read ports, one write port.
**No reset on the array, deliberately**, and the synthesis report confirms why:
it inferred RAMD32/RAMS32 distributed RAM (44 LUTs), not the 992 flops a reset
would have forced. x0 invariance and WB→ID write-first forwarding are both
implemented here rather than in the surrounding pipeline, because both are
formal properties in CLAUDE.md §5.5.

`tb/cocotb/` — 168 tests across seven toplevels: `test_core` (65) and
`test_riscv_tests` (40) on the core, `test_alu`
(16), `test_regfile` (8), `test_decoder` (31), `test_mem_align` (4, each an
exhaustive sweep), `test_hazard` (2; one sweeps all 2,048 input combinations
over x0–x3), `test_branch` (2: corner pairs, and random pairs that are equal,
one apart or opposite in sign, against a reference using Python's own signed
compare rather than the RTL's sign-bit shortcut). In `test_core` **both** memories are BRAM-timed models that
sample 1 ns before each rising edge, like a flop's setup window. `feed()`
writes an instruction at the address being fetched, and `feed_to()` walks it to
a named pipeline register, so no test hand-counts the fetch latency. `feed()`
assumes no stall — a stall re-presents the same address, and feed() would
overwrite it — so anything with a load-use pair goes through `run()`, whose
`timed=True` records the cycle each instruction retires. That is how the
load-use tests prove the stall costs **exactly** one cycle, and that a load
followed by an unrelated instruction, or a load to x0, costs none — and how
the branch tests prove a taken branch costs exactly two and a not-taken one
none. `run(cycles=n)` lifts the default budget for programs with backward
branches. Tests that depend on forwarding preset the registers first: the
register file has no reset, so a stale value could otherwise happen to equal
the forwarded one and pass vacuously.

`tb/cocotb/rv32i_model.py` — the golden model (CLAUDE.md §11): one instruction
at a time, no pipeline, written from the ISA spec. Where RV32I raises an
exception it follows the core's one rule — trap means halt — and it raises on
everything not implemented rather than guessing.
Its B- and J-immediate decode was checked against **GNU `as`**, an encoder
independent of anything written here: 211 instructions, every single-bit
offset and both extremes, plus the test encoders `enc_b`/`enc_jal`/`enc_jalr`
bit for bit. `test_core` runs random
programs over x0–x4 against it, comparing **retirement order** (not just final
state, which a dropped or doubled instruction can survive) and final memory:
120 instructions padded (validates the model), 400 dense (finds hazards).
Random branches and jumps go **forward only**, 1–6 words, so every program
terminates; offset 2 skips exactly the word in IF/ID. Random targets and
addresses are always aligned — a misaligned one would trap and end most
programs early; directed tests cover that, and riscv-formal will exhaustively.
Each run asserts a floor on taken redirects (5 padded, 20 dense, against
measured minimums of 10 and 35 over 200 seeds, re-measured when misaligned
targets left the mix) so a generator that
stops branching fails rather than passing vacuously. Every program ends in six
ECALL/EBREAKs — the farthest a forward branch reaches — so each seed also
checks the halt: the exact retirement count, and nothing retiring after it. **Every retirement is also checked through RVFI**: the model leaves an
RVFI-shaped record per step, and `check_rvfi` compares the core's records
field by field — insn, both pcs, rs addresses and values, rd, memory masks,
address and the selected data lanes, and `order` — so stores, branches and
NOPs count too, and a dropped, duplicated or bubble-retired instruction
misaligns the stream. Register values are compared only where the model knows
them (no regfile reset): 1,228 of 1,470 reads across the two seed-1 programs.
`SEED=n` reruns a seed; seeds 1–20 pass.

`tb/cocotb/test_riscv_tests.py` — the official rv32ui suite, one cocotb test
per upstream test (`@cocotb.parametrize`). Each `.S` is assembled at test time
from the pinned submodule `sw/riscv-tests` with **our** environment,
`sw/riscv-tests-env/` (`riscv_test.h`, `link.ld`): upstream's `env/p` writes
a dozen CSRs and enters the test through `mret`, none of which exists here.
The test bodies and `test_macros.h` are untouched, and PASS/FAIL are
upstream's macros verbatim. The test list is read from upstream's own
`Makefrag`, minus a two-entry exclusion list that must still name real tests.
`-march=rv32i` and nothing more, so the assembler rejects any instruction
outside the base set rather than letting it run here as a silent NOP. The
same flat image goes behind both memory ports. **Two verdicts per test:** the
suite's own (`gp == 1` at the halt), and every retirement against the golden
model through RVFI — the model must pass each test on its own first, or the
failure is reported as the model's. Proven able to fail: an SRA-as-SRL ALU
fails `sra`, `srai` and `lui` at case 3; the older-write-wins forwarding bug
fails 24 of 40; a decoder that never halts fails all 40.

Submodules get their own toplevel rather than being
poked through the core's hierarchy, so a unit test survives refactoring and can
drive ports the core does not expose.

`scripts/setup-vivado-env.sh`, `constr/core_ooc.xdc`, `syn/synth_ooc.tcl` —
out-of-context synthesis and implementation of the core alone, no board-level
top yet. Runs through `route_design` because post-synthesis timing is an
estimate and post-route is measured.

### Not started

riscv-formal and the §5.5 properties beyond x0 invariance, UVM, TMR,
hardware bring-up, and all of Stage 2.

**Encodings outside RV32I decode inert** (`rd_we = 0`, no memory access, no
redirect, no halt) rather than half-working — CSR accesses, MRET, WFI and
illegal words alike, since there is no trap to raise. A branch or load that wrote a plausible-looking value would later
surface as a riscv-formal mismatch that reads like a forwarding bug, sending the
hunt to the wrong part of the design.

---

## Synthesis trend

**This table is the one append-only thing in this file.** Everything else here
is a snapshot of current reality; this is deliberately history, because the
whole point is the deltas. Never rewrite a past row — if an old number turns
out to be wrong, add a row saying so.

Add a row after every RTL slice lands. `make synth`, then copy the numbers
straight out of `docs/reports/summary_ooc.txt` — do not retype them from
memory or from the terminal scrollback.

All rows out-of-context on `xc7a100tcsg324-1`, constrained at 10.000 ns
(100 MHz, the Arty's oscillator), unless a row says otherwise.

| Date | Slice | LUT | FF | CARRY4 | WNS (ns) | Fmax (MHz) | Δ Fmax |
|---|---|---|---|---|---|---|---|
| 2026-09-05 | PC + IF (43 lines) | 2 | 92 | 8 | +7.338 | 375.7 | — (baseline) |
| 2026-09-17 | Sync-high reset + `_i`/`_o` ports | 1 | 92 | 8 | +7.338 | 375.7 | 0.0 |
| 2026-09-17 | ID: decode + regfile + ID/EX | 108 | 249 | 8 | +6.029 | 251.8 | −123.9 |
| 2026-09-17 | EX: ALU + operand sel + EX/MEM | 592 | 352 | 24 | +3.095 | 144.8 | −107.0 |
| 2026-10-07 | MEM + WB: DMEM port, lane align, MEM/WB, writeback | 682 | 484 | 24 | +2.696 | 136.9 | −7.9 |
| 2026-10-07 | IF fix: IMEM driven from `pc_next` | 712 | 489 | 24 | +2.846 | 139.8 | +2.9 |
| 2026-10-07 | Forwarding + load-use stall (hazard unit) | 818 | 489 | 24 | +0.942 | 110.4 | −29.4 |
| 2026-10-07 | Branches + JAL/JALR: comparator, target adder, flush | 963 | 492 | 47 | +0.059 | 100.6 | −9.8 |
| 2026-10-07 | Bubble clears 5 control bits, not all of ID/EX | 963 | 492 | 47 | +0.073 | 100.7 | +0.1 |
| 2026-10-07 | Forwarding selects decided in ID, registered | 1095 | 496 | 47 | +0.394 | 104.1 | +3.4 |
| 2026-10-07 | RVFI port, under `RISCV_FORMAL` (not synthesized) | 1095 | 496 | 47 | +0.394 | 104.1 | 0.0 |
| 2026-10-08 | FENCE (NOP), ECALL/EBREAK halt | 1107 | 501 | 47 | +0.430 | 104.5 | +0.4 |
| 2026-10-08 | Misaligned access / taken target traps (halts) | 1115 | 501 | 47 | +0.300 | 103.1 | −1.4 |
| 2026-10-08 | Redirect mask as a concatenation (Yosys cast bug) | 1115 | 501 | 47 | +0.300 | 103.1 | 0.0 |
| 2026-10-08 | Stall properties S1–S4, under `FORMAL` (not synthesized) | 1115 | 501 | 47 | +0.300 | 103.1 | 0.0 |
| 2026-10-08 | Reset gates store and writeback; forwarding props (not synthesized) | 1117 | 501 | 47 | +0.317 | 103.3 | +0.2 |
| 2026-10-10 | Branch-flush properties B1/B2, under `FORMAL` (not synthesized) | 1117 | 501 | 47 | +0.317 | 103.3 | 0.0 |

Device totals for the percentages: 63,400 LUT / 126,800 FF / 135 BRAM /
240 DSP.

### Reading these numbers

**Fmax here is not a board number.** Out-of-context leaves `HD.CLK_SRC` unset,
so Vivado cannot estimate clock delay or skew. Read it as the core's logic
limit. A real board number arrives with the Arty A7 top, and when it does it
gets its own table rather than being mixed into this one — measurement
conditions travel with the measurement or the measurement is worthless.

The FF count doubles as a correctness check on the flow. The RTL has 3 x 32 =
96 registers; 4 constant-fold away because `pc[1:0]` and `if_id_pc_o[1:0]` are
always zero on a `pc + 4` increment. 92 is right, and the tools proving they
understood the design is a good sign the flow is wired up correctly.

Expect Fmax to fall sharply once there is an ALU. **That fall is the data.**
A single number at the end of the project is a claim; a table showing what each
pipeline stage cost in MHz and LUTs is evidence of engineering. It also
localises regressions — if Fmax halves, the row tells you which slice did it,
instead of bisecting months of commits.

The MEM + WB row: **the critical path did not move.** It is still
`id_ex_a_sel_zero` → ALU carry chain → `ex_mem_alu_result_o[31]`, 12 levels,
61% route. The −7.9 MHz is the same EX path routing worse among ~90 more LUTs,
not a new path through MEM or WB. The FF count reconciles exactly: the RTL adds
148 flops (ID/EX +5, EX/MEM +37, MEM/WB +106); 2 constant-fold
(`mem_wb_pc_o[1:0]`), and Vivado merges 14 pairs of flops that always hold the
same bit — `mem_funct3` equals `instr[14:12]` in three stages, and
`mem_wb_rd_addr` equals `instr[11:7]`. 352 + 148 − 16 = 484. Checked in the
routed netlist, not assumed: `mem_wb_instr_o` keeps 29 flops (its funct3 bits
merged into `mem_wb_mem_funct3`), and `mem_wb_rd_addr` keeps none.

The IF-fix row: **+30 LUTs** is the reset gating on `imem_addr_o`, one LUT for
each of the 30 bits that are not constant zero. **+5 FFs** is `pc[1]`, which no
longer constant-folds in any of the five PC registers (seen in the routed
netlist: each holds bits 31:1). It is always zero, and before this change
Vivado knew it; the cause is not established. The +2.9 MHz is placement
variation, not an improvement.

**The fix moved logic onto a path this table cannot see.** `imem_addr_o` now
comes out of the `pc + 4` adder rather than straight off a flop, and the
out-of-context constraints set no output delays, so the path from the pc
register through the adder to the BRAM address pins is **untimed** here. It
gets timed when the board-level top puts a real BRAM on the other end — see
Next up.

The forwarding row is the largest single-feature cost so far, and the shape
of the critical path is the textbook one: `ex_mem_rd_we` → hazard comparator →
`fwd_rs2_ex_mem` (fanout 32) → forwarding mux → `alu_b[2]` (fanout 115, the
shifter's shift amount) → `ex_mem_alu_result[26]`. A loop from EX/MEM back to
EX/MEM with the forwarding **decision** in series ahead of the ALU; 79% of it
is routing. **Not acted on yet**, recorded as an option: compute the selects
one stage early — compare ID's rs1/rs2 against ID/EX's and EX/MEM's rd — and
register them into ID/EX, so in EX they come straight off flops. FF count is
unchanged because the stall uses clock enables and the bubble reuses the reset
values.

The branch row: **the critical path moved to branch resolution, and it ends
in the flush.** `mem_wb` rd → hazard comparator (fo 99) → forward select
(fo 54) → forwarding mux → the comparator's `ltu` carry chain (4 CARRY4) →
`redirect` (fo 33) → the synchronous reset pins of ID/EX, fanout **171**. 11
levels, 77% routing. The forwarding decision is still in series at the front,
so registering the selects in ID still helps; the new lever is the back end
(Next up). FF +3 is exactly `id_ex_branch`/`jump`/`jalr`. CARRY4 +23 is the
three new carry structures: the target adder, the `pc + 4` link adder, and
the comparator.

The bubble row: **a fix that worked and did not help.** The flush's endpoint
fanout fell 171 → 5 and that last net 1.06 → 0.64 ns, but placement shifted
the rest of the same path and absorbed it: +0.014 ns overall, noise. LUT and
FF unchanged — the reset pins were free; their cost was purely routing. What
the report shows instead is where the time is: `mem_wb` rd → hazard compare
(fo 98) → forward select (fo 54) → forwarding mux is ~5.1 ns of the 9.2 ns
path, before the comparator has an operand. That is the registered-selects
lever.

The registered-selects row: **the forwarding decision is off the critical
path.** The new worst path starts at `mem_wb_mem_read` (the writeback select,
fo 97) → writeback mux → forwarding mux → comparator carry chain → `redirect`
→ the IF/ID flush (fo 95) → ID/EX control; 11 levels, 73% route. FF +4 is
exactly the four `id_ex_fwd_*` flops. **LUT +132 is not explained.** It is in
synthesis itself — the post-synthesis cell table already sums to 1095, and
phys_opt reports no replication or retiming — and the mix shifted to smaller
LUTs (LUT2 39 → 70, LUT5 108 → 172), consistent with the forwarding/operand
muxes being restructured once their selects come off flops. Cause not
established. Two levers remain in sight on this path: the IF/ID flush fanout
(the same treatment as ID/EX, but IF/ID's instruction word drives decode, so it
needs a valid bit rather than a five-bit clear), and the load data on the
MEM/WB forward — which on the board starts at a BRAM's ~2 ns clock-to-out.

The RVFI row is identical to the one above to the last digit, which is the
point: everything RVFI adds sits under `` `ifdef RISCV_FORMAL ``, synthesis does
not define it, and Vivado is deterministic for the same netlist. Neither report
mentions `rvfi`.

The halt row: **FF +5 is exactly the RTL** — `id_ex_halt`, `halted_q`,
`ex_mem_halt`, `mem_wb_halt`, `halt_o`. LUT +12 is the halt decode (two
32-bit compares) and the `freeze` terms. The worst path is the same family:
`mem_wb_alu_result[1]` (the load lane select) → load alignment → writeback
mux → forwarding mux → comparator → `redirect` → the ID/EX bubble clear,
10 levels, 74% route. That clear net now carries `freeze` too — Vivado named
its last LUT after `id_ex_halt` — but `freeze` comes off two flops, so it
added no level. +0.036 ns is placement noise. Deliberately **not** on the
IF/ID flush (see Decisions).

The misalignment-trap row took three runs, and the two discarded ones are the
lesson. First, misalignment read off `alu_result[1:0]` and a taken
misaligned target also fed `freeze`: +0.030 ns. Dropping the target term
from `freeze` (redundant — a redirect already flushes) made it **−0.912 ns,
21 levels**: `alu_result[0]` is the ALU's final mux output, which also
carries SLT's 32-bit compare, and with `freeze` now a plain select Vivado
folded `freeze ? pc : pc + 4` into the pc+4 carry chain — compare chain and
increment chain in series. The fix was what the comment had claimed all
along: a dedicated `ex_rs1[1:0] + imm[1:0]`, exact because a sum's low bits
depend only on its operands' low bits. Final: +0.300 ns, 9 levels, the
familiar writeback → forwarding → comparator → ID/EX bubble-clear path at
76% route. FF unchanged (the trap reuses the halt flops); LUT +8.

The redirect-mask row is identical to the one above, which is the point:
Vivado always read `~XLEN'(2'b11)` as intended, so replacing it changed
nothing it builds. Only Yosys differed.

The reset-gating row: LUT +2 is the two `&& !rst_i` gates (store enable,
writeback enable); the worst path is unchanged in shape, and +0.2 MHz is
placement noise. The forwarding properties and the regfile's observation
port are under `FORMAL` and absent from the netlist.

**The out-of-context slack is optimistic, now +0.317 ns.** Three
paths that matter on the board cross the core's ports and are untimed here:
`pc + 4` / stall mux → `imem_addr_o`, the stall comparator and now the whole
branch-resolution path → `imem_addr_o`, and
`dmem_rdata_i` → load alignment → writeback mux → forwarding mux → ALU — the
last one starts at a BRAM clock-to-out of roughly 2 ns on Artix-7. The board-
level run will say whether 100 MHz survives.

---

## Toolchain

| Tool | Version | Location |
|---|---|---|
| Verilator | 5.050 | `~/.local/bin/verilator` (built from source; tree at `~/.local/src/verilator`) |
| cocotb | 2.1.0 | `~/cocotb-env` |
| riscv gcc | 16.1.0 | `~/riscv-toolchain/bin/riscv32-unknown-elf-gcc` |
| spike | — | `~/riscv-toolchain/bin/spike` |
| gh CLI | 2.100.0 | `~/.local/bin/gh`, authed as RodeanAzari |
| **Vivado** | 2025.2 | `~/Xilinx/2025.2/Vivado` — ML Standard, no license file. Run `vivado-env` first |
| **OSS CAD Suite** | nightly **2026-10-07** | `~/.local/opt/oss-cad-suite` (2.5 GB), `bin/` **appended** to PATH in `~/.bashrc`. The bundle's date is its version — pin CI to the same one |
| ↳ Yosys | 0.69+208 (`7b1913f4c`) | from the suite. Also the ASIC flow's synthesis step (§6.4) |
| ↳ SymbiYosys (`sby`) | 0.69 | from the suite, with `yosys-smtbmc` |
| ↳ solvers | Yices 2.7.0, Boolector 3.2.4, Bitwuzla 0.9.1, Z3 4.15.5 | from the suite |
| **LibreLane + Sky130** | — | **not installed** — needed closing Phase E (CLAUDE.md §6.4 run #1) |
| **riscv-formal** | `c992aa6` (2026-07-16) | git submodule `tb/formal/riscv-formal`; never written to — `scripts/riscv-formal.sh` builds a symlink tree in `tb/formal/build/rvf/` instead |
| **riscv-tests** | `bcffa2b` (2026-09-25) | git submodule `sw/riscv-tests`; its own nested `env` submodule is deliberately not initialised — we use our env |

`~/.local/bin` is first on PATH, so the source-built Verilator shadows the
Debian 5.032 package automatically. OSS CAD Suite's `bin/` is **last**, so it
supplies only what nothing else does — `which verilator python3` must still
print `~/.local/bin/verilator` and `/usr/bin/python3`.

**Yosys reads the core** (checked 2026-10-07, both configurations, with and
without `-DRISCV_FORMAL`): `read_verilog -sv` on every file under `rtl/`,
`hierarchy -check -top riscv_core; proc; check -assert` — all seven modules
elaborated, none black-boxed, 0 problems, no warnings. That closes the §4
"keep `rtl/core/` within Yosys's subset" question for the RTL as it stands; it
is a parse-and-elaborate check, not yet a proof of anything.
**And it was not enough:** a clean elaboration still hid a Yosys
mis-parse of `~XLEN'(2'b11)` that riscv-formal found on its first run (see
Decisions and [formal-properties.md](formal-properties.md)). Elaborating
proves Yosys accepts the RTL, not that it means the same thing by it.

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
- **OSS CAD Suite ships its own Verilator and Python.** Its README suggests
  sourcing `environment` or putting `bin/` first on PATH; either would silently
  replace the pinned Verilator 5.050 and the Python cocotb runs under, and
  `make sim` would change simulators without saying so. Hence appended, not
  prepended, and never `source`d — the same lesson as Vivado's
  `settings64.sh`.

---

## Build targets

| Target | Does | State |
|---|---|---|
| `make lint` | Verilator lint of `rtl/` | working |
| `make sim` | cocotb regression | working |
| `make sw` | build `sw/**/*.c` → `.elf` / `.hex` | untested, no source yet |
| `make spike` | run `.elf` on spike | untested, no source yet |
| `make synth` | OOC synth + impl of the core, reports to `docs/reports/` | working |
| `make prog` | — | stub; blocked on USB passthrough (§6 of vivado-setup.md) |
| `make formal` | SymbiYosys over every `tb/formal/*.sby`, all tasks, then `scripts/riscv-formal.sh` (checks + covers, verdicts read from status files); appends OSS CAD Suite's `bin/` to PATH itself; `FORMAL_JOBS=n` | working |
| `make uvm` / `impl` / `asic` | — | stubs that name their phase and what they wait on |

---

## CI

`.github/workflows/ci.yml`, two jobs in parallel. **`verilate`** builds
Verilator 5.050 from source, caches it on key `verilator-Linux-v5.050`,
installs cocotb from `tb/cocotb/requirements.txt`, then runs lint and sim.
**`formal`** downloads OSS CAD Suite at `OSS_CAD_SUITE_DATE` (2026-10-07, the
local install's date — the two must move together), puts it on PATH and runs
`make formal` — the smoke test, then riscv-formal (checked out as a
submodule). Not cached: ~700 MB GitHub-to-GitHub takes seconds, and caching
it would eat a large share of the 10 GB quota. Separate jobs so a lint failure
never hides a formal result, or the reverse.

First run took 11m53s (the compile). Cached runs should be under a minute.
**GitHub evicts a cache unused for 7 days**, so the first push after a break
rebuilds Verilator (~8 min) and re-saves it — seen 2026-10-07 after a 20-day
gap: `Cache not found for input keys: verilator-Linux-v5.050`, then lint and
sim in about a minute. A slow first run after a pause is this, not a broken
cache key.
CI checks out with `submodules: true` for `sw/riscv-tests`, and installs
Ubuntu's `gcc-riscv64-unknown-elf` to assemble it — there is no riscv32
package, and none is needed: `-march=rv32i -mabi=ilp32` choose the target and
nothing links a library. `test_riscv_tests.py` takes `RISCV_PREFIX`, else
`~/riscv-toolchain`'s riscv32 gcc, else whichever is on PATH.
The regression is seven elaborations; each gets its own build directory and
results file.
Bumping `VERILATOR_VERSION` forces a rebuild.

**Watch: `ubuntu-latest` becomes Ubuntu 26 from 2026-10-19** (annotation on
run 37817380686). Two things move with it: the apt riscv64 toolchain (13.2
today), and the OS under the cached Verilator — the cache key names only
`runner.os` (`Linux`), so a binary built on 24.04 would be restored onto
26.04. If the first run after the switch fails, suspect this before the RTL;
pinning `runs-on: ubuntu-24.04` or adding the image version to the key are
the two fixes. (The same run also warns that Node 20 actions are deprecated;
they run on Node 24 regardless.)

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
- **Synchronous, active-high reset** (decided 2026-09-17). The core was written
  with async active-low `rst_n`; CLAUDE.md §4 requires sync active-high `rst`,
  so the RTL moved. Changed while the core was one file — reset convention is
  viral, and every module, testbench and the Phase E TMR wrapper inherits it.
  Confirmed in the synthesis report rather than assumed: the 92 flops went
  FDCE/FDPE (async clear/preset) → FDRE/FDSE (sync reset/set), and one of the
  two LUT1s disappeared with the active-low inverter. Zero timing cost — the
  critical path is the `pc + 4` carry chain, which reset style does not touch.
- **`_i`/`_o` suffixes on every port, clock and reset included** (2026-09-17).
  CLAUDE.md §4 mandates the suffixes and carves out no exception, and the
  convention it comes from (lowRISC/OpenTitan) suffixes `clk_i`/`rst_i` too.
  Done in the same session as the reset change for the same reason: the port
  list is one module long today. The **clock object stays named `clk`** while
  the port is `clk_i` — `syn/synth_ooc.tcl` finds it with `get_clocks clk` and
  every committed report identifies it that way, so a timing object should not
  be renamed whenever RTL naming conventions shift. Verified the constraint
  still binds: the timing report shows `clk` at 10.000 ns / 100 MHz, not the
  empty-path fallback the script prints when `create_clock` matches nothing.
- **Nested layout adopted early, empty directories not created** (2026-09-17).
  `rtl/core/` and `tb/cocotb/` now hold the two existing files; the other eight
  directories in CLAUDE.md §3 appear when they have contents. The real fix was
  not the move but the **globs**: `rtl/*.sv` matched one level, and the failure
  modes were asymmetric — Verilator errors on a missing module, but Vivado
  black-boxes it with a critical warning and finishes, emitting a utilization
  report for a design with a hole in it. Every source glob is now recursive,
  sorted for reproducible ordering, and errors on an empty match, and
  `synth_ooc.tcl` additionally rejects any netlist containing a black box
  (`IS_BLACKBOX`, property name verified against Vivado rather than assumed).
- **Hosted CI runs lint + sim + formal; synthesis stays local** (2026-09-17).
  CLAUDE.md §4 previously demanded synth in CI, which this file already argued
  against. The line that was missing is that **cost, not principle**, separates
  them: yosys and SymbiYosys install in minutes and belong in CI from Phase B,
  while Vivado's ~54 GB does not fit a hosted runner. Committed reports in
  `docs/reports/` are the substitute; a self-hosted runner is the upgrade path.
- **Measurement discipline restored to CLAUDE.md §10** (2026-09-17). The
  rewrite deleted it, but `syn/synth_ooc.tcl` and this file's trend table both
  rest on it. Three rules are back — measure every increment, numbers come from
  generated files, conditions travel with the number. The fourth (p50/p99
  latency distributions) stayed deleted: nothing here reports a latency
  distribution, so it was framing borrowed from a different kind of project.
- **RVFI: design in now, connect the port at WB** (2026-09-17). CLAUDE.md §5.4
  wants RVFI from Phase A. The shadow fields ride the pipeline registers from
  this slice on, but the *port* waits for a retirement to report: with no WB,
  `rvfi_valid` could only be tied low, and wiring riscv-formal to a core that
  never retires makes every ISA property pass **vacuously** — the exact failure
  §5.5 and §9 warn about. A green formal run that proves nothing is worse than
  no run. Full reasoning and the per-field capture points in
  [rvfi-plan.md](rvfi-plan.md); the one that bites is `rs1_rdata`/`rs2_rdata`,
  whose taps must move to the forwarding-mux outputs when EX lands.
- **Register file has no reset on the array** (2026-09-17). RV32I leaves x1–x31
  undefined at reset, so resetting them buys nothing architecturally and costs
  992 flops plus the loss of RAM inference. Measured rather than assumed: the
  synthesis report shows RAMD32 x68 and RAMS32 x20 — 44 LUTs of distributed RAM
  — and the FF count landed at 249, which is the pipeline registers alone. The
  simulation cost is X on the read ports until a register is written; that is a
  testbench problem, not a hardware one.
- **cocotb 2.0.1 → 2.1.0** (2026-09-17). Forced, not cosmetic. Under 2.0.1,
  adding the register file's 32 x 32 array made **reading a top-level output
  port segfault** in the VPI layer. Reduced to a 15-line module with one array
  and twelve 32-bit outputs: 12/12 reads on 2.1.0, 4/12 on 2.0.1, and the
  crash point moved with unrelated build flags, which is what memory corruption
  looks like. Ruled out first: our RTL (lint clean, generated C++ symmetric
  across the ports), signal naming, port count, packed vs. unpacked array, and
  the trace flags. Verilator VPI array support is a known weak spot in cocotb
  (issues #1851, #3446, #3611). Anyone on 2.0.1 will see this the moment a
  register file appears, hence the pin in `tb/cocotb/requirements.txt`.
- **EX slice excludes branches, loads/stores and forwarding** (2026-09-17). Not
  laziness — each is blocked on something that does not exist yet. Forwarding
  sources are the EX/MEM and MEM/WB registers, so there is literally nothing to
  forward from. Branch resolution needs the flush machinery, which belongs with
  the hazard unit. Loads and stores need MEM. Half a branch is worse than none,
  so the unimplemented classes decode inert instead.
- **The hazard slice was split: data hazards first, branches second**
  (2026-10-07). The plan bundled forwarding, the load-use stall and branches.
  Forwarding is independent of control flow and removes the NOP padding every
  test needed; branches bring their own flush machinery. Two slices also mean
  two trend rows, so each feature's cost is visible on its own.
- **Golden model before RTL, and proven on both sides of the change**
  (2026-10-07). The model and random tests were written before any hazard RTL.
  Padded programs passed against the old core (the model is right); dense ones
  failed at writeback #11 (the test can see hazards); after the hazard unit,
  both passed. The first padded run failed for a third reason worth
  remembering: the register file has no reset, so a random program reading a
  register before writing it got Verilator's initial value in the core and 0
  in the model. Random programs now load x1–x4 first, as real software would.
- **Branch resolution has its own comparator and target adder** (2026-10-07).
  Not the ALU: during a jump the ALU's result is replaced by the link address,
  and routing the redirect through the ALU's result mux would lengthen the
  path that now sets Fmax anyway. The comparator shares one carry chain
  between BLT and BLTU (sign bits decide when they differ).
- **A jump's link address replaces the ALU result in EX** (2026-10-07). The
  plan left open whether `pc + 4` is a third writeback source or goes through
  the ALU. Neither: a third WB source would break EX/MEM→EX forwarding of the
  link, and feeding a constant 4 into the ALU puts a mux on `alu_b`, which was
  already on the critical path at fanout 115. A 2:1 mux after the ALU, selected
  off a flop, costs the least. (No correct-path instruction can actually
  consume a link from EX/MEM — a jump's successor arrives two flushed cycles
  later and reads it through the register file — but the value is right on
  every path, which is what Phase B will check.)
- **Stall and redirect cannot coincide** (2026-10-07). The plan called for a
  directed test of both firing in one cycle. They cannot: the stall needs a
  load in EX and the redirect a branch or jump in EX, and EX holds one
  instruction. Redirect still outranks stall in the mux, at no cost.
  Confirmed by mutation: swapping the priority passes all 52 core tests.
  Belongs in Phase B as `!(stall && redirect)`.
- **Misaligned jump and branch targets drop bits [1:0]** (2026-10-07).
  **Superseded 2026-10-08: they now trap** — see "Misalignment traps".
  Same reasoning as data misalignment at the time. Masked off the sum rather
  than left out of the add, since `rs1[1:0] + imm[1:0]` can carry into bit 2
  — still true of the redirect mask. The directed test read the landing pc
  with `auipc`: checking which instruction ran was not enough, because IMEM
  ignores the low bits too — a first version of the test missed a planted bug
  for exactly that reason, and only the random tests caught it.
- **riscv-formal: `insn` checks are not enough on their own** (2026-10-08).
  They verify each instruction's result *from the operand values RVFI
  reports*, and a pipeline that forwards the wrong value reports it
  faithfully. Wrong forwarding priority, a missing load-use stall and a
  stall bubble keeping `rd_we` all passed every `insn` check, and all failed
  `reg`. So `reg`, `pc_fwd`, `pc_bwd`, `unique` and `causal` run alongside,
  at VexRiscv's 5-stage depths (check at 15; consistency windows to 25).
- **riscv-formal runs from a symlink tree, with verdicts from status files**
  (2026-10-08). `genchecks.py` locates riscv-formal as `../..` from the
  current directory, so `scripts/riscv-formal.sh` builds that layout under
  `tb/formal/build/` instead of writing into the submodule. The generated
  `.sby` files say `expect pass,fail`, so `sby` — and the generated makefile —
  exit 0 on a FAILED check; the script reads every check's `status` and
  requires as many PASSes as checks generated. Found when the first planted
  faults "passed" `make`.
- **Reachability for riscv-formal: the same config again in `mode cover`**
  (2026-10-08). `genchecks.py` accepts `mode cover` though its docs list only
  bmc and prove. Deriving `covers.cfg` from `checks.cfg` with one `sed` keeps
  a single configuration; every `cover()` in riscv-formal's checkers must be
  reached, 4 per instruction.
- **No size casts on expressions Yosys sees** (2026-10-08). Yosys 0.69 reads
  `~XLEN'(2'b11)` as a cast to width `~XLEN`, yielding mask `0x3`; Verilator
  and Vivado read `~(XLEN'(2'b11))`. Unmasked jump targets resulted, in
  every Yosys-built netlist only — riscv-formal and the future LibreLane run.
  Replaced by a concatenation; it was the RTL's only cast. If one is ever
  needed, parenthesise it and let `make formal` judge.
- **Reset gates the two commit points** (2026-10-08). `dmem_we_o`/`dmem_wstrb_o`
  and `wb_rd_we_o` are ANDed with `!rst_i`. Pipeline registers clear only at
  the end of the reset cycle, so during it EX/MEM and MEM/WB hold power-up
  contents, and an ungated port could store garbage into data memory. Found
  by formal (an implausibly early cover, then X1); invisible in simulation
  and on the FPGA, both of which power flops up at 0, but real on an ASIC.
- **Forwarding is proven for one solver-chosen register** (2026-10-08):
  `anyconst f_reg` plus a shadow of its committed value, tied to the
  register file's storage by invariant R1 through a formal-only observation
  port on `riscv_regfile`. Simulation tracks x1. The property block now needs
  `RISCV_FORMAL` too (it reuses the RVFI valid bits to skip bubbles), so
  `core.sby` defines both.
- **Properties live in the RTL, `ifdef FORMAL`; environments live in
  `tb/formal/`** (decided 2026-10-08, superseding the entry below). The §5.5
  properties are about `stall`, `redirect` and pipeline registers, and
  open-source Yosys cannot reach them from a harness: a hierarchical
  reference like `u.inner` is not an error but a *new, undriven, free wire*
  ("used but has no driver"), and the assertion on it vanishes. So each
  module states its own properties in one `ifdef FORMAL` block. Assumptions
  — where vacuous proofs come from — stay in the harness, few and visible.
  `FORMAL` is defined by Yosys's `-formal` (verified: it emits `$check`
  cells), never by Vivado, and not by riscv-formal's `read -sv`, so neither
  synthesis nor riscv-formal sees the blocks. Lint's second run and every
  cocotb build define it, with Verilator `--assert`: each test checks every
  property on every cycle. "Previous cycle" values are explicit `f_past_*`
  flops, not `$past()`, because Yosys and Verilator sample clocked
  assertions differently. `f_past_valid` needs an initial value — the one
  place in `rtl/` that has one — under a scoped `PROCASSINIT` lint waiver.
- **Formal harnesses wrap modules from outside; nothing in `rtl/`**
  (2026-10-08). **Superseded the same day** — see above. Properties live in `tb/formal/` as a wrapper module that
  instantiates the RTL with every input free and asserts on its ports, using
  immediate assertions in procedural blocks — the subset open-source Yosys
  parses (no Verific). Nothing formal-only enters `rtl/`, so synthesis and the
  trend table never see it. The cost is that a harness sees only ports;
  internal invariants (the core's, later) need RVFI or exported signals.
- **The first property is x0 invariance on the register file** (2026-10-08).
  A §5.5 property small enough that a failure could only be the toolchain, so
  the smoke test proves the chain, not the design. It still earns its place:
  the planted-fault run showed the solver using the reset-less array's free
  initial contents — a state simulation's zeroed memory never shows.
- **ECALL and EBREAK halt the core** (decided 2026-10-08). RV32I says they
  trap; traps need `mtvec`/`mepc`/`mcause` and the CSR instructions, all out
  of scope (§5.1), so something else has to happen. Three options were
  weighed: halt, NOP, or redirecting riscv-tests' PASS/FAIL to a memory
  store. Halt is the only one giving the instructions a defined meaning that
  holds on the board too — a NOP silently runs on into whatever follows, and
  the store dodges the question. Precedent: PicoRV32's `trap` pin, and
  riscv-formal's NERV, which without CSRs treats them as illegal and stops.
  RVFI sets both `rvfi_halt` ("the last instruction the core retires before
  halting") and `rvfi_trap` (its architectural effect is an exception). It
  also lets upstream's PASS/FAIL macros run verbatim.
- **Freeze does not flush IF/ID** (2026-10-08). The first version did; it is
  redundant — ID/EX takes a bubble every cycle once frozen, so IF/ID's word
  can never issue — and IF/ID's flush is on the critical path. The pc *is*
  frozen, though nothing architectural needs it: a halted core showing where
  it stopped is worth one OR term at the stall's mux input.
- **riscv-tests: our environment, upstream's tests** (2026-10-08). Upstream's
  `env/p` needs CSRs and `mret`; every core without them (PicoRV32 the best
  known) supplies its own `riscv_test.h`. Ours zeroes x1–x31 as upstream's
  does, starts at the reset vector, and keeps PASS/FAIL verbatim. **Two of
  42 excluded:** `fence_i` (Zifencei, not among the 40 instructions, and its
  self-modifying code cannot work across separate instruction and data
  memories) and `ma_data` (misaligned access, which this core ignores rather
  than traps — see the misalignment decision). A submodule, not a copy, so
  the exact upstream commit is in history and an update is one reviewed bump.
- **FENCE is a NOP, and that is the implementation** (2026-10-08). FENCE
  orders memory accesses as seen by other harts and devices; with one
  in-order hart, no caches and no store buffer, accesses already happen in
  program order. Revisit when the Stage 2 DMA engine starts sharing memory
  with the core — that is the first second observer.
- **The ASIC flow is LibreLane, not OpenLane** (renamed 2026-10-07, before
  anything was installed). CLAUDE.md named "OpenLane" from before the
  ecosystem moved. Checked on GitHub that day: the original
  `The-OpenROAD-Project/OpenLane` is the legacy flow (last push 2026-03);
  Efabless's OpenLane 2 now sits at `chipfoundry/openlane2`, quiet since
  2025-12; `librelane/librelane` describes itself as the successor, is based
  on OpenLane 2, is run by the FOSSi Foundation, and released 3.0.16 on
  2026-10-06. Same tools and Sky130 underneath, so §6.4's steps and metrics
  are unchanged. Renamed now so no one installs the wrong flow from a stale
  spec. Open: whether LibreLane has built-in scan insertion (§6.5) — check in
  Phase H.
- **Formal tools come from OSS CAD Suite, date-pinned** (2026-10-07). One
  bundle of Yosys, SymbiYosys and four solvers, built and tested together, in
  the home directory with no root. `apt` was checked first: Ubuntu 26.04 has
  `yosys` 0.52 and `boolector`, but no SymbiYosys package and no Yices, so it
  would have meant mixing an apt Yosys with a source-built `sby` at versions
  nobody tested together. The bundle is a nightly, so its date is the version;
  when formal joins CI, CI installs the same date.
- **The RVFI port is compiled only under `RISCV_FORMAL`** (2026-10-07). Its
  shadow registers are trace, not CPU; an always-on port would have put them
  in the OOC numbers, since every port of the top is kept. Same convention as
  riscv-formal's own flow. The cost is a second configuration to keep honest,
  so `make lint` runs both.
- **RVFI checked in simulation before formal exists** (2026-10-07). A cocotb
  monitor compares every retirement with the golden model. Seven planted RVFI
  bugs were each caught by the random programs — including the plan's "one
  that bites", rs1 tapped before the forwarding mux, which fails at
  retirement #1 (the `addi` of the first `li`). When riscv-formal arrives,
  disagreement between it and this monitor points at the harness, not the core.
- **Forwarding selects are decided in ID and registered** (2026-10-07). The
  lever recorded with the forwarding row. Exact rather than speculative,
  because stages past ID never hold: ID/EX's instruction is in EX/MEM next
  cycle, EX/MEM's in MEM/WB. Checked by mutation in both directions it could
  go wrong — selects used a cycle early (unregistered), and registered but
  compared against producers a stage late — each fails ~25 core tests. +3.4
  MHz for 4 flops (and +132 LUTs, unexplained; see the trend notes).
- **A bubble clears only ID/EX's five control bits** (2026-10-07). Done to
  take the flush off 171 reset pins; measured gain was noise (see the trend
  notes), kept anyway because the bits it no longer drives are free and the
  analysis behind it — which fields can act — is the one the RVFI valid bit
  needs. It exposed two test gaps the full flush had been hiding, since a
  zeroed bubble could never resemble a real instruction: a load-after-load
  pointer chase, and a branch in a stall or redirect bubble. The random test
  missed both: it addresses loads off x0, and evidently rarely puts a taken
  branch directly behind a redirect.
- **Store data is forwarded** (2026-10-07). Not in the original plan. EX/MEM
  was copying rs2 out of ID/EX, so `addi x1; sw x1` back to back would have
  stored a stale x1. Found while designing the muxes, not in test, and covered
  by `test_store_data_is_forwarded`.
- **IMEM is driven from `pc_next`, not `pc`** (2026-10-07). Fixes a bug found
  during the MEM + WB slice: a BRAM latches its address at a clock edge and
  answers during the next cycle, so presenting `pc` made it return `mem[P]`
  while the pc already held `P + 4`. Every instruction reached IF/ID tagged
  with the next instruction's PC — `auipc x5, 0` at pc 8 wrote 12. It went
  unseen because the testbench answered IMEM within the cycle, which no BRAM
  can do. Now the BRAM and the pc register latch the same address on the same
  edge. The alternative, keeping a registered address and delaying the pc by a
  cycle to match, gives the address path better timing but adds one more
  wrong-path fetch to discard on every taken branch. Branch redirect and the
  stall both enter at `pc_next`, so one mux feeds both the pc and the BRAM.
  Proven both ways: the new testbench fails 4 tests on the old RTL (including
  the exact `auipc` symptom) and passes on the new.
- **Testbench memories sample just before the clock edge, not at the falling
  edge** (2026-10-07). `imem_addr_o` depends on `rst_i` combinationally, so a
  test releasing reset at the falling edge changes it in the same instant a
  falling-edge sampler reads it. Sampling 1 ns before the rising edge removes
  the race, and it is also how a real flop behaves (setup window).
- **Misalignment traps — and so halts** (decided 2026-10-08, reversing the
  two truncation decisions below). riscv-formal settled it: under
  `RISCV_FORMAL_ALIGNED_MEM` every `insn_*.v` for a load, store, branch or
  jump has `spec_trap` true on a misaligned address or target, and
  `rvfi_insn_check` asserts `spec_trap == trap`; without that mode it expects
  the access to *succeed* at byte granularity. Neither accepts "ignore the low
  bits". The alternative, `assume`-ing misaligned cases away in the harness,
  was rejected: it would hide real behaviour from the checker, the failure
  mode §5.5 warns about. Halting follows the ECALL rule — an exception with no
  handler stops the core — so there is one rule, not two. Detection is in EX
  from adder bits [1:0], the earliest bits a carry chain settles; a branch
  traps only if taken (its target is otherwise never used). On the board a
  pointer bug now stops the core visibly instead of silently corrupting the
  containing word. Proven by mutation: dropping the register-write gate, the
  store gate, the same-cycle freeze, the halfword rule, the "only if taken"
  condition, or the target trap's halt each fails the test written for it.
- **Misaligned loads/stores are assumed not to happen** (decided 2026-10-07).
  **Superseded 2026-10-08: they trap** — see above.
  RV32I demands support or a trap; traps are out of scope (§5.1) and hardware
  support means a MEM-stage FSM and a stall before any hazard unit exists.
  Defined behaviour rather than undefined: **address bits below the access size
  are ignored**, so a misaligned access touches the aligned word or halfword
  that contains it, never two words. Pinned by
  `test_misaligned_access_uses_the_containing_word`. **Open for Phase B:**
  riscv-formal must be told; check what `RISCV_FORMAL_ALIGNED_MEM` expects of a
  misaligned access (it may expect `rvfi_trap`) before relying on it, otherwise
  constrain the harness to aligned addresses. The same question now applies to
  misaligned jump and branch targets.
- **Load/store width is its own field, not the ALU's `funct3`** (2026-10-07).
  The earlier plan said the carried `funct3` doubled as the width. It cannot:
  loads and stores use the ALU to compute `rs1 + imm`, so the ALU's `funct3`
  must say ADD. `mem_funct3` rides alongside. It costs nothing in the end —
  Vivado merges each copy with the `instr[14:12]` shadow bits it always equals,
  keeping one flop per bit.
- **Store data is replicated, not shifted** (2026-10-07). `SB` puts rs2's byte
  in all four lanes and the strobes pick one; replication is wiring, a shifter
  is muxes. The unit test checks the memory *outcome*, not `wdata`'s unwritten
  lanes, so it would still pass on a correct shifting redesign.
- **The ALU is selected by `funct3` + `alt`, not a private opcode enum**
  (2026-09-17). Using the ISA's own encoding means the decoder and the ALU
  cannot drift out of step, because there is only one encoding. It also avoids a
  SystemVerilog package, which §4 lists among the constructs to check against
  Yosys before committing — and yosys is not installed until Phase B, so an
  unverifiable construct was worth designing around rather than adopting.
  The `alt` bit is where the classic decode bug lives: on OP-IMM it is `instr[30]`
  **only** for the two shift forms. Everywhere else `instr[30]` is immediate bit
  10, so forwarding it unconditionally turns `addi rd, rs1, -1` into a subtract —
  wrong only for immediates with bit 10 set, which small positive random values
  never produce. Directed tests cover it at both the decoder and the core level.

---

## Next up

> **Resume here (2026-10-10, mid Phase B).** Branch-flush correctness is
> proven (B1/B2, k = 7, see formal-properties.md §10). Remaining §5.5
> properties: **no structural hazard** on the regfile ports, and the general
> case of **no X into committed state**. Same discipline: covers guarded by
> `f_past_valid` and outside reset, a planted fault for every property, the
> induction depth swept, and docs/formal-properties.md updated in the same
> commit.
>
> **Plan agreed 2026-10-10:** finish those two properties, then go straight to
> a **first-light board bring-up (§3 below) before starting Phase C**. Goal:
> see it run on the Arty A7: LEDs blink, text prints over UART, a simple
> program runs. This is an early slice of Phase D, not a phase skip. Phase C
> (UVM) follows, and Phase D's remaining boxes (Dhrystone/IPC, ILA, photo)
> come after that as planned.

### 1. Timing: IF/ID flush via the valid bit

The current critical path ends in the IF/ID flush (fo 95). The valid bit now
exists, but only under `RISCV_FORMAL`; moving `if_id_valid` into the core
proper and gating decode with it would let a redirect clear one bit instead of
64. Its own measured slice.

### 2. Formal, continued (Phase B)

riscv-formal passes: 37 instruction checks plus `reg`, `pc_fwd`, `pc_bwd`,
`unique`, `causal`, each non-vacuous (covers or planted faults). Open, in
rough order:

- The remaining §5.5 hand-written properties, each added to
  [formal-properties.md](formal-properties.md) with depth, covers and a
  planted fault it catches: **no structural hazard** on the regfile ports, and
  the rest of **no X into committed state** — X1 covers reset; the general
  case is that every flop that can reach committed state is reset (a
  two-copy "miter" proof is one way). Done: stall correctness (S1–S4),
  forwarding (F1/F2/L1, with invariant R1), reset commits nothing (X1),
  branch-flush correctness (B1/B2).
- Show `pc_bwd` and `causal` failing on a planted fault.
- Decide `liveness`/`hang` (fairness, and what liveness means once halted)
  and `ill` (needs a legality decoder, or a reasoned exclusion).

### 3. Board-level top: first light (next after Phase B's last two properties)

Scheduled ahead of Phase C (see the plan under "Resume here"). Done when all
three are seen on the board:

1. **LEDs blink**: a program in BRAM writes to a memory-mapped LED register
2. **Text prints**: a UART transmitter (`rtl/periph/`) prints "hello" to a
   serial terminal over the board's USB-UART
3. **A simple program runs**: a small compiled C program (e.g. a counter or
   a sum printed over UART), not just hand-written assembly

Pieces: `constr/arty_a7.xdc` pin constraints (copied from Digilent's master XDC),
a top with BRAM instruction/data memory, clocking (likely an MMCM to 50 MHz for
first light, given the thin OOC margin), a simple address decode for the
LED and UART registers, `make impl`, then `make prog`
(still blocked on WSL2 USB passthrough, §6 of vivado-setup.md). Only then does
Fmax become a board number, and it gets its own table. It is also the first run
that times `pc + 4` → `imem_addr_o` → BRAM address, which the out-of-context
flow leaves unconstrained; expect it, plus the branch-target mux added in §1,
to be a candidate critical path — it now carries the branch comparator and
target adder too.

**Programming the board from WSL2: undecided, pick at bring-up.** WSL2 cannot
see USB devices by default, so neither Vivado's Hardware Manager nor
`openFPGALoader` *running inside WSL* will find the Arty's JTAG on its own.
vivado-setup.md §6 reads as if `openFPGALoader` avoids this; it does not. It
avoids Vivado's Hardware Manager, not the USB problem. Two options:

1. **`usbipd-win` + `openFPGALoader` in WSL.** `usbipd-win` (installed on
   Windows) attaches the Digilent USB device into WSL; `openFPGALoader -b arty`
   then programs the `.bit` from WSL. Fully scriptable, so `make prog` does
   the whole job. Cost: the device must be re-attached (`usbipd attach`) after
   every reboot or replug.
2. **Program from the Windows side.** Build the `.bit` in WSL with `make impl`,
   then load it with Vivado Hardware Manager or `openFPGALoader` on Windows,
   pointed at the file through `\\wsl$\...`. Fewest moving parts, but
   `make prog` would no longer program the board itself; it could only
   print instructions.

The serial console (UART text) has the same issue: the Arty's USB-UART
appears as a COM port on Windows, and reaches WSL only through `usbipd-win`.
A Windows terminal (PuTTY, Tera Term) on the COM port avoids that.

**Learning the Vivado GUI alongside the scripts.** The build stays scripted
(`make impl` / `make prog`, Tcl in batch mode, never GUI-only, per CLAUDE.md
§2), but the user wants to learn the Vivado GUI too. At bring-up, walk through
it on the same design: open the checkpoints (`.dcp`) `make impl` writes to
look at the device view, the placed design, the critical path and the timing
and utilization reports, and use Hardware Manager (at least once, even if
option 1 is chosen above) to program the board and later view ILA captures.
The GUI is for looking and learning; the scripts produce the committed results.

---

## How to maintain this file

Update at the end of any session that changed meaningful state. Keep it a
snapshot of *current* reality, not an append-only diary — stale claims here are
worse than no file. Specifically:

- Move items between "Implemented" and "Not started" as they land
- Re-run `make lint` and `make sim` and record what actually happened, not what
  should have
- **Run `make synth` and append a row to the synthesis trend table** after any
  RTL change. Copy the numbers from `docs/reports/summary_ooc.txt`; commit the
  regenerated reports in the same commit as the RTL that produced them, so a
  report always matches the code beside it in history
- Add decisions with their rationale, since the reasoning is the part that
  gets forgotten
- Update the toolchain table when anything is installed or upgraded

---

*Last updated: 2026-10-10 — branch-flush correctness proven by k-induction
(B1: bubbles are inert in every stage; B2: retirements chain their pcs),
holding from k = 7 with no helper invariant; three planted flush faults each
caught. Netlist unchanged: 168/168, 103.3 MHz. Next: structural hazards on
the regfile ports, general X propagation.*
