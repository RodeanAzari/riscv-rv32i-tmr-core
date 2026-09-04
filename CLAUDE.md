## 1. Standards that apply to every project

These are what separate a portfolio from a pile of repos. Almost no student does these, which is exactly why they signal maturity.

### 1.1 Repository structure

```
project-name/
├── README.md              # architecture diagram + MEASURED results
├── rtl/                   # synthesizable SystemVerilog only
├── tb/                    # testbenches (UVM or cocotb)
├── sim/                   # simulation scripts, waveform configs
├── syn/                   # synthesis + implementation scripts (Tcl)
├── constr/                # XDC timing/pin constraints
├── sw/                    # host software, drivers, reference models
├── docs/                  # design docs, coverage plans, timing reports
├── scripts/               # build automation
├── Makefile               # single entry point: make sim / make synth / make prog
└── .github/workflows/     # CI
```

### 1.2 Non-negotiables

|Requirement|Why it matters|
|---|---|
|**Scripted, reproducible builds** (Tcl + Make)|Kepler lists scripting (bash/Python/Tcl) as a bonus. Clicking through the Vivado GUI is not a build process.|
|**CI on every commit** — lint, simulate, synthesize|Nobody expects this from a student. It reads as professional immediately.|
|**Measured numbers in the README**|Latency in ns, Fmax in MHz, LUT/FF/BRAM/DSP utilization, coverage %, IPC. Not "high performance."|
|**Timing closure reports committed**|Proves you actually closed timing rather than ignoring warnings.|
|**Hardware evidence**|Photos, ILA captures, logic-analyzer traces, UART logs. Simulation-only projects are the norm; hardware-proven ones are not.|
|**Design doc in `docs/`**|Block diagram, interface spec, throughput/latency targets, CDC strategy, and — critically — _decisions you made and rejected alternatives_.|

### 1.3 Measurement discipline

Report **distributions, not averages**, wherever latency is involved: p50 / p99 / p99.9 / max. An average latency figure tells an HFT interviewer that you haven't thought about tail behavior, which is the entire problem in that industry.

### 1.4 Commit hygiene

Commit regularly with meaningful messages. A repo with 200 commits over six months tells a truthful story about sustained work. A repo with three commits titled "final" tells a different one.

---

## 3. Project 1 — RISC-V RV32I Core: Formally Verified, Fault-Tolerant

**Priority: BUILD THIS FIRST.** It is the fastest path to something demonstrable, it uses hardware you already own, and it addresses the core stated requirement of literally every posting reviewed (HRT: "thorough understanding of digital logic design and/or computer architecture").

**Estimated duration:** 10–14 weeks **Target relevance:** Big Tech ★★★ | Aerospace ★★★ | HFT ★★

### 3.1 Scope boundary

**In scope:**

- In-order 5-stage pipelined RV32I core
- Full hazard handling: forwarding, stall, flush
- Formal verification (riscv-formal + hand-written SVA)
- SystemVerilog UVM testbench with functional coverage
- TMR variant with voter and fault-injection harness
- Running on Arty A7 with UART console and ILA visibility

**Explicitly OUT of scope:**

- Tomasulo / out-of-order execution
- Superscalar issue
- Cache hierarchy beyond simple instruction/data memory
- MMU, privilege modes, interrupts (beyond a basic timer if time allows)

> **Why out-of-order was cut:** Tomasulo is a multi-month project on its own, and combining it with TMR is architecturally incoherent — radiation-hardened designs are deliberately simple, in-order, and deterministic _because_ you need provable state recovery. An interviewer who knows the space domain will ask why you TMR'd an OoO machine, and there is no good answer. A complete, verified, silicon-proven in-order core beats a half-finished OoO one.

### 3.2 Architecture

```
                    ┌──────────────────────────────────────────┐
                    │           HAZARD / CONTROL UNIT          │
                    │  stall · flush · forward-select signals  │
                    └──┬────────┬────────┬────────┬────────┬───┘
                       │        │        │        │        │
   ┌─────┐   ┌─────┐   ▼ ┌─────┐▼ ┌─────┐▼ ┌─────┐▼ ┌─────┐▼
   │ PC  │──▶│ IF  │────▶│ ID  │─▶│ EX  │─▶│ MEM │─▶│ WB  │
   └──▲──┘   └──┬──┘     └──┬──┘  └──┬──┘  └──┬──┘  └──┬──┘
      │         │           │        │        │        │
      │      ┌──▼──┐     ┌──▼───┐ ┌──▼──┐  ┌──▼───┐    │
      │      │IMEM │     │ REG  │ │ ALU │  │ DMEM │    │
      │      │BRAM │     │ FILE │ │     │  │ BRAM │    │
      │      └─────┘     └──▲───┘ └─────┘  └──────┘    │
      │                     └───────────────────────────┘
      │                          writeback path
      │
      └──── branch resolution (EX stage) ────────────────
```

**Pipeline stages**

|Stage|Function|
|---|---|
|**IF**|PC update, instruction fetch from BRAM, IF/ID register|
|**ID**|Decode, register file read, immediate generation, hazard detection|
|**EX**|ALU operation, branch resolution, forwarding mux inputs|
|**MEM**|Data memory access, load/store alignment|
|**WB**|Register file writeback|

**Forwarding paths to implement:** EX→EX, MEM→EX, WB→ID (register file internal forwarding). Load-use hazard requires a one-cycle stall — this is the case students get wrong most often, so verify it explicitly.

**TMR architecture (Phase C):**

```
         ┌───────────────┐
    ┌───▶│  Core Copy A  │───┐
    │    └───────────────┘   │
    │    ┌───────────────┐   │   ┌──────────┐
 ───┼───▶│  Core Copy B  │───┼──▶│  VOTER   │──▶ output
    │    └───────────────┘   │   │ (2-of-3) │
    │    ┌───────────────┐   │   └────┬─────┘
    └───▶│  Core Copy C  │───┘        │
         └───────────────┘            ▼
                                 mismatch flag
                                 → resync / scrub
```

Vote on architectural state (register file writes, PC, memory writes). Expose a mismatch counter so faults are observable at runtime.

### 3.3 Phases

**Phase A — Working core (weeks 1–4)**

- Implement all five stages, hazard unit, forwarding
- Self-checking testbench running hand-written assembly
- Pass the official `riscv-tests` RV32I suite
- **Deliverable:** core executes RV32I correctly in simulation

**Phase B — Formal verification (weeks 5–7)**

- Integrate `riscv-formal` for ISA compliance proofs
- Hand-write SVA properties for:
    - Forwarding correctness (forwarded value equals architectural value)
    - No structural hazard on register file ports
    - Branch flush correctness (no wrong-path instruction commits)
    - Pipeline register validity (no X propagation into committed state)
- Run bounded model checking and induction with SymbiYosys
- **Deliverable:** documented property list, proof results, any bugs formal caught that simulation missed _(this last one is a great interview story — write down every bug formal found that your testbench didn't)_

**Phase C — UVM environment (weeks 6–9, overlaps B)**

- UVM testbench: driver, monitor, scoreboard, coverage collector
- C++/Python golden ISA reference model connected via DPI-C
- Per-instruction architectural state comparison
- Constrained-random instruction stream generation
- Functional coverage plan: instruction types, hazard scenarios, forwarding paths, branch taken/not-taken, corner immediates
- **Deliverable:** coverage report at ≥95% functional coverage with a written coverage plan in `docs/`

**Phase D — Hardware bring-up (weeks 9–11)**

- Synthesize to Arty A7, close timing, document Fmax
- UART peripheral for console output
- Boot a real compiled C program (start with "hello world," then Dhrystone or CoreMark)
- ILA probes on pipeline registers for live debug
- **Deliverable:** photo/video of the board running your program, timing report, utilization report

**Phase E — TMR + fault injection (weeks 11–14)**

- Triplicate the core, implement the voter
- Fault-injection harness: randomly flip bits in registers/pipeline state at randomized cycles
- Measure and report: fault detection rate, recovery rate, area/timing overhead vs. baseline
- Formally verify the voter (any two agreeing inputs produce that output)
- **Deliverable:** fault-injection campaign results table, area/Fmax cost of TMR

### 3.4 Headline metrics to report

- Fmax on Artix-7 (MHz)
- Resource utilization: LUTs, FFs, BRAM, DSP (and % of device)
- CPI / IPC on CoreMark and Dhrystone
- Formal: number of properties proven, proof depth, bugs found
- Functional coverage %
- TMR: fault detection rate, recovery rate, area overhead %, Fmax penalty

### 3.5 Optional extension (only after Phase E ships)

Branch predictor comparison — static not-taken vs. 2-bit bimodal vs. tournament — with **measured IPC deltas** on real benchmarks. Quantified performance data is far more impressive than the word "tournament" on a resume.

### 3.6 Common failure modes

- **Load-use hazard handled incorrectly** — verify with directed tests before trusting random ones
- **Forwarding to the wrong operand** when both source registers match
- **Branch flush off by one stage** — wrong-path instruction commits
- **X propagation** from uninitialized BRAM masking real bugs in simulation
- **Formal proofs that pass vacuously** — always check for reachability; a property that's never exercised proves nothing