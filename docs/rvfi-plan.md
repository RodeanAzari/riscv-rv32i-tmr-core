# RVFI plan

How the RISC-V Formal Interface gets built into this core, and why it is built
the way it is. Written before the ID stage, because three more pipeline stages
are about to be built on top of these decisions.

CLAUDE.md §5.4 requires the port and lists its signals. This note covers the
part a signal list does not: *where each value is captured*, and what goes
wrong if it is captured somewhere else.

---

## What RVFI is

A trace port. Once per retired instruction the core asserts `rvfi_valid` and
presents, on the same cycle, everything an external checker needs to decide
whether that instruction did the right thing: the instruction word, the PC
before and after, the registers it read and the values it read *from them*, the
register it wrote and the value written, and any memory access.

`riscv-formal` then proves — not tests, proves — that every retirement is
consistent with the RV32I specification. It is the single highest-value
verification artifact in Phase B.

**One pulse per retirement, not per cycle.** A stalled or flushed cycle
retires nothing and must not assert `rvfi_valid`.

---

## Where each field is captured

The fields are born in different stages and all have to arrive at WB together,
so they ride the pipeline registers as shadow fields alongside the real data.

| Field | Captured at | Note |
|---|---|---|
| `rvfi_insn`, `rvfi_pc_rdata` | IF/ID | Available today |
| `rvfi_rs1_addr`, `rvfi_rs2_addr` | ID | Decoder output |
| `rvfi_rs1_rdata`, `rvfi_rs2_rdata` | **EX, after the forwarding mux** | See below |
| `rvfi_pc_wdata` | EX | Branch target, else `pc + 4` |
| `rvfi_mem_addr`, `_rmask`, `_wmask`, `_wdata` | MEM | Masks encode width and alignment |
| `rvfi_mem_rdata` | MEM→WB | Load data lands a stage after its address |
| `rvfi_rd_addr`, `rvfi_rd_wdata` | WB | Both read 0 when no write happens |
| `rvfi_order` | WB | Free-running retirement counter |
| `rvfi_valid` | WB | One pulse per retired instruction |
| `rvfi_trap`, `rvfi_halt`, `rvfi_intr` | WB | Tied low — no traps or interrupts in scope (§5.1) |

---

## The one that bites: `rvfi_rs1_rdata` / `rvfi_rs2_rdata`

These must be the values the instruction **architecturally read** — the values
it actually computed with.

Today, with no EX forwarding, that is whatever the register file returned, so
capturing at ID/EX is correct. **Once EX→EX and MEM→EX forwarding exist, it
stops being correct.** A forwarded instruction computes with a value that came
out of a forwarding mux; the value sitting in the ID/EX register is stale and
was never used. A core that reports the ID/EX value is lying about what it did,
in exactly the cycles where forwarding fired.

The failure mode is worse than being wrong, because of how it *looks*:
`riscv-formal` reports a mismatch that reads like a forwarding bug, and the
hunt starts in the hazard unit, where there is no bug to find.

**Therefore:** when the EX slice adds forwarding muxes, the RVFI `rs1_rdata` /
`rs2_rdata` taps move to the **mux outputs**, not the register file outputs.
This is written down here because it is a one-line change that is invisible
until it costs a day.

---

## Why the port is not being added yet

§5.4 says design RVFI in from Phase A, and this note is that design. The *port*
waits for the WB stage, deliberately.

Nothing retires yet — there is no WB — so `rvfi_valid` could only be tied low.
Wiring `riscv-formal` against a core whose `rvfi_valid` never rises makes every
ISA compliance property **pass vacuously**: the checker constrains only cycles
where `rvfi_valid` is high, and there are none. CLAUDE.md §5.5 requires
reachability checks precisely to catch this, and §9 lists vacuous proofs as a
known failure mode.

A green `riscv-formal` run that proves nothing is worse than no run, because it
looks like progress. So the shadow fields are plumbed as each stage is built,
and the port is connected when there is a retirement to report.

---

## Build order

| Slice | RVFI work |
|---|---|
| **ID** *(this one)* | `rs1_addr` / `rs2_addr` carried in ID/EX; `insn` and `pc` already in IF/ID |
| **EX** | `pc_wdata`; move the `rs1_rdata` / `rs2_rdata` taps to the forwarding mux outputs |
| **MEM** | `mem_addr`, `mem_rmask`, `mem_wmask`, `mem_wdata` |
| **WB** | `rd_addr`, `rd_wdata`, `order`, `valid` — **port goes live, `riscv-formal` wired up** |

Phase B then checks reachability on every property, so a regression back to
vacuity gets caught rather than celebrated.
