# Functional coverage plan (Phase C)

What the UVM environment (`tb/uvm/`, `make uvm`) must exercise before Phase C
is done (CLAUDE.md §8: **≥ 95% functional coverage**), written before the
environment, as buildplan.md §5.6 requires. Each group below becomes one
covergroup in the coverage collector; each row is one bin, or a set of bins
as counted.

## How it is measured

**Two kinds of source.**

- **Black-box, from RVFI**: one record per retired instruction (instruction
  word, pc, rs1/rs2/rd and their values, memory address and masks, trap).
  This is what most groups sample. Only valid retirements count, so bubbles
  and flushed wrong-path instructions never hit a bin.
- **White-box, from inside the core**, for what RVFI cannot show: which
  forwarding path delivered an operand, and when the load-use stall fired.
  The collector reads these by hierarchical reference (testbench only;
  simulators allow it, and nothing in `rtl/` changes):

  | Signal (in `riscv_core`) | Meaning, when `id_ex_valid` |
  |---|---|
  | `id_ex_fwd_rs1_ex_mem`, `id_ex_fwd_rs2_ex_mem` | operand from EX/MEM |
  | `id_ex_fwd_rs1_mem_wb`, `id_ex_fwd_rs2_mem_wb` | operand from MEM/WB |
  | `stall` | load-use stall this cycle |
  | `wb_rd_we_o`, `wb_rd_addr_o` with ID's `dec_rs1_addr` / `dec_rs2_addr`, `if_id_valid` | WB→ID bypass through the register file |

  A white-box bin is credited only for an instruction that will retire, so
  a squashed one cannot count. Forwarding is sampled in EX when
  `id_ex_valid` is set: nothing squashes an instruction once it is in EX (a
  redirect flushes only the younger stages, and no test resets mid-program).
  The stall is sampled in its own cycle: its consumer is in ID and a stall
  never coincides with a redirect (formal property S1), so the consumer
  goes on to retire.

**The number.** Every bin has weight 1, and the reported figure is **bins
hit ÷ bins defined** over all groups. In the covergroups this is done by
giving each coverpoint and cross an `option.weight` equal to its bin count,
so the simulator's total equals the bin ratio rather than an average of
group percentages, which would let a small group swing the figure. No bin
is excluded after the fact: a bin that cannot be reached is a bug in this
plan, and the plan is changed in a commit that says why.

**Scope.** RV32I as this core implements it (CLAUDE.md §5.1): every
exception halts the core, so a trapping instruction ends its test, and the
trap bins are hit by short directed or random tests that end that way.
FENCE is a NOP.

## Groups

### 1. Instructions — 40 bins

Each RV32I instruction retired at least once: LUI, AUIPC, JAL, JALR; BEQ,
BNE, BLT, BGE, BLTU, BGEU; LB, LH, LW, LBU, LHU; SB, SH, SW; ADDI, SLTI,
SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI; ADD, SUB, SLL, SLT, SLTU, XOR,
SRL, SRA, OR, AND; FENCE, ECALL, EBREAK.

### 2. Forwarding — 30 bins

| Coverpoint / cross | Bins |
|---|---|
| rs1 source: EX/MEM, MEM/WB, WB→ID bypass, register file | 4 |
| rs2 source: same four, for instructions that read rs2 | 4 |
| rs1 source × rs2 source (R-type, branches, stores) | 16 |
| rs1 = rs2, both forwarded from one producer: from EX/MEM, from MEM/WB | 2 |
| both EX/MEM and MEM/WB write the source register (younger must win), per operand | 2 |
| a load's result forwarded from MEM/WB, per operand | 2 |

Register-file reads count only when the register is not x0, so "register
file" means a real value, not the hardwired zero.

### 3. Load-use stall — 9 bins

| | Bins |
|---|---|
| stall on rs1 only, rs2 only, both | 3 |
| stall after each load width: LB, LH, LW, LBU, LHU | 5 |
| the instruction that waited out a stall is a taken branch or jump | 1 |

### 4. Control flow — 17 bins

| | Bins |
|---|---|
| each conditional branch × {taken, not taken} | 12 |
| JAL, JALR (always taken) | 2 |
| taken branch forward, taken branch backward | 2 |
| a taken branch whose next instruction in program order is itself a branch (squashed in ID) | 1 |

### 5. Immediates and sign extension — 59 bins

| | Bins |
|---|---|
| ADDI, SLTI, SLTIU, XORI, ORI, ANDI × imm {0, 1, −1, 2047, −2048} | 30 |
| SLLI, SRLI, SRAI × shamt {0, 1, 31} | 9 |
| load offset {0, −1, 2047, −2048}; store offset, same four | 8 |
| LUI, AUIPC × imm[31:12] {0, 0x80000, 0xFFFFF} | 6 |
| LB, LH × loaded value's sign bit {0, 1} | 4 |
| LBU, LHU with the loaded value's top bit set (must zero-extend) | 2 |

### 6. Back-to-back dependencies — 11 bins

| | Bins |
|---|---|
| read-after-write at distance 1, 2, 3, ≥4 retirements, × {rs1, rs2} | 8 |
| write-after-write to the same register in consecutive retirements | 1 |
| a chain of three, each reading the one before | 1 |
| a store whose data register is the previous instruction's load result | 1 |

### 7. Memory alignment — 32 bins

| | Bins |
|---|---|
| LB, LBU × address[1:0] {0, 1, 2, 3} | 8 |
| LH, LHU × {0, 2} (aligned) | 4 |
| LH, LHU × {1, 3} (misaligned: traps) | 4 |
| LW × 0; LW × {1, 2, 3} (traps) | 4 |
| SB × {0, 1, 2, 3} | 4 |
| SH × {0, 2}; SH × {1, 3} (traps) | 4 |
| SW × 0; SW × {1, 2, 3} (traps) | 4 |

### 8. Traps — 7 bins

| | Bins |
|---|---|
| ECALL, EBREAK | 2 |
| misaligned load, misaligned store | 2 |
| taken branch to a misaligned target; JAL to one; JALR to one | 3 |

### 9. M extension — 33 bins (RV32IM build only, Phase H)

Counted only when the core is built with M_EXT = 1 (`make uvm M=1`); the
RV32I run's total stays groups 1-8. Written before the environment's M
support, as groups 1-8 were. Group 1 does not count M encodings (they share
OP's funct3 values with ADD..AND).

| | Bins |
|---|---|
| each M instruction retired: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU | 8 |
| DIV, DIVU, REM, REMU by zero; DIV, REM with INT_MIN / −1 (overflow) | 6 |
| MULH both negative; MULH one negative; MULHSU rs1 negative; MULHU both ≥ 2^31; DIV/REM negative ÷ positive; DIV/REM positive ÷ negative (not −1) | 6 |
| M operand source (white-box, the instruction's first EX cycle): rs1 from EX/MEM, MEM/WB, WB→ID; rs2 the same | 6 |
| M result read by the next retirement; by the one after (nearest writer); by a taken branch at distance 1 | 3 |
| load-use stall with an M instruction waiting in ID; two M instructions retiring back to back; a trap retiring straight after an M instruction | 3 |
| M instruction with rd = x0 | 1 |

An M instruction stays in EX for 3 or 34 cycles while ID moves on; the
forwarding groups (2 and this one) sample an instruction only on its first
cycle in EX, the one whose forwarding decision it used.

## Total

| Group | Bins |
|---|---|
| 1. Instructions | 40 |
| 2. Forwarding | 30 |
| 3. Load-use stall | 9 |
| 4. Control flow | 17 |
| 5. Immediates | 59 |
| 6. Dependencies | 11 |
| 7. Alignment | 32 |
| 8. Traps | 7 |
| **Total** | **205** |
| 9. M extension (RV32IM build only) | 33 |
| **Total, RV32IM build** | **238** |

95% of 205 is 194.75, so **at most 10 bins may stay unhit**. Every unhit
bin at sign-off is listed in PROGRESS.md with the reason.

## Checked as well as covered

Coverage says a case happened; it does not say the core got it right. Every
retirement in every test is compared with the C golden model
(`sw/model/`) through DPI-C: instruction, pc, next pc, register written and
its value, memory address, masks and data, and trap. A mismatch fails the
test at the first divergent instruction.
