// RV32I core. Phase A: all five stages -- IF, ID, EX, MEM, WB.
//
// FENCE is a NOP, which is a complete FENCE on one in-order hart without
// caches. Every exception RV32I defines here -- ECALL, EBREAK, a misaligned
// load or store, a misaligned taken branch or jump target -- halts the core:
// with no trap machinery in scope (CLAUDE.md 5.1) there is no handler to
// enter. See the EX section.
//
// Branches and jumps resolve in EX (CLAUDE.md 5.2) with static not-taken
// prediction: fetch carries on at pc + 4, and a taken branch or any jump
// redirects the pc and flushes the two younger instructions already fetched,
// in IF/ID and at the instruction memory's output. Taken costs two cycles;
// not taken costs none.
//
// Data hazards are handled in full (CLAUDE.md 5.3): EX/MEM and MEM/WB forward
// into EX, the register file's write-first bypass covers WB->ID, and a load
// followed directly by a use of its result stalls one cycle. riscv_hazard
// makes the decisions; the muxes and the stall live here.
//
// Instruction memory is external and BRAM-timed: it latches imem_addr_o at a
// clock edge and returns that word during the following cycle. The core
// therefore presents pc_next, not pc -- see the IF section for why.
//
// Data memory is external for the same reason. Its address comes straight off
// the EX/MEM register, so the BRAM sees a flop rather than the ALU's carry
// chain; it latches the address at the end of MEM and load data arrives in WB.
module riscv_core #(
    parameter int unsigned XLEN   = 32,
    parameter int unsigned ADDR_W = 5
) (
    input  logic            clk_i,
    input  logic            rst_i,

    // Instruction memory port (synchronous read, 1-cycle latency). The address
    // is the NEXT pc, combinational -- the BRAM's address register stands in
    // for the pc register, and imem_rdata_i is the word at pc.
    output logic [XLEN-1:0] imem_addr_o,
    input  logic [XLEN-1:0] imem_rdata_i,

    // Data memory port (synchronous read, 1-cycle latency, byte strobes).
    // The address is word-aligned: the low two bits select lanes via
    // dmem_wstrb_o on stores, and inside the core on loads. dmem_wstrb_o is
    // zero whenever dmem_we_o is low. There is no read enable -- a BRAM can
    // read every cycle, and a load simply uses the cycle's result.
    output logic [XLEN-1:0] dmem_addr_o,
    output logic [XLEN-1:0] dmem_wdata_o,
    output logic [3:0]      dmem_wstrb_o,
    output logic            dmem_we_o,
    input  logic [XLEN-1:0] dmem_rdata_i,

    // The register file write WB performs this cycle. Outputs, for observation:
    // these are rvfi_rd_addr / rvfi_rd_wdata in waiting (docs/rvfi-plan.md).
    output logic              wb_rd_we_o,
    output logic [ADDR_W-1:0] wb_rd_addr_o,
    output logic [XLEN-1:0]   wb_rd_wdata_o,

    // High once a trapping instruction (ECALL, EBREAK, a misaligned access or
    // target) has retired, and with it everything older: architectural state
    // is final. Sticky until reset.
    output logic              halt_o,

`ifdef RISCV_FORMAL
    // RISC-V Formal Interface (CLAUDE.md 5.4, docs/rvfi-plan.md): one record
    // per retired instruction, valid in WB. Verification-only -- compiled in
    // for simulation and riscv-formal, absent from synthesis, so the trend
    // table measures the core and not its trace harness.
    output logic              rvfi_valid_o,
    output logic [63:0]       rvfi_order_o,
    output logic [XLEN-1:0]   rvfi_insn_o,
    output logic              rvfi_trap_o,
    output logic              rvfi_halt_o,
    output logic              rvfi_intr_o,
    output logic [ADDR_W-1:0] rvfi_rs1_addr_o,
    output logic [ADDR_W-1:0] rvfi_rs2_addr_o,
    output logic [XLEN-1:0]   rvfi_rs1_rdata_o,
    output logic [XLEN-1:0]   rvfi_rs2_rdata_o,
    output logic [ADDR_W-1:0] rvfi_rd_addr_o,
    output logic [XLEN-1:0]   rvfi_rd_wdata_o,
    output logic [XLEN-1:0]   rvfi_pc_rdata_o,
    output logic [XLEN-1:0]   rvfi_pc_wdata_o,
    output logic [XLEN-1:0]   rvfi_mem_addr_o,
    output logic [3:0]        rvfi_mem_rmask_o,
    output logic [3:0]        rvfi_mem_wmask_o,
    output logic [XLEN-1:0]   rvfi_mem_rdata_o,
    output logic [XLEN-1:0]   rvfi_mem_wdata_o,
`endif

    // Pipeline registers, exposed for bring-up and ILA probing. Several carry
    // RVFI shadow fields (instr, pc, rs1_addr, rs2_addr) on their way to WB.
    output logic [XLEN-1:0]   if_id_pc_o,
    output logic [XLEN-1:0]   if_id_instr_o,
    output logic [XLEN-1:0]   id_ex_pc_o,
    output logic [XLEN-1:0]   id_ex_instr_o,
    output logic [ADDR_W-1:0] id_ex_rs1_addr_o,
    output logic [ADDR_W-1:0] id_ex_rs2_addr_o,
    output logic [XLEN-1:0]   id_ex_rs1_rdata_o,
    output logic [XLEN-1:0]   id_ex_rs2_rdata_o,
    output logic [XLEN-1:0]   id_ex_imm_o,
    output logic [ADDR_W-1:0] id_ex_rd_addr_o,
    output logic [XLEN-1:0]   ex_mem_pc_o,
    output logic [XLEN-1:0]   ex_mem_instr_o,
    output logic [XLEN-1:0]   ex_mem_alu_result_o,
    output logic [ADDR_W-1:0] ex_mem_rd_addr_o,
    output logic              ex_mem_rd_we_o,
    output logic [XLEN-1:0]   mem_wb_pc_o,
    output logic [XLEN-1:0]   mem_wb_instr_o
);

  localparam logic [XLEN-1:0] RESET_VECTOR = 32'h0000_0000;
  localparam logic [XLEN-1:0] NOP          = 32'h0000_0013;  // addi x0, x0, 0

  // ---------------------------------------------------------------- IF -----
  // The BRAM and the pc register must latch the SAME address on the SAME edge.
  // Then, throughout a cycle, pc holds address P and imem_rdata_i holds mem[P],
  // and IF/ID captures a matched pair.
  //
  // Presenting pc instead (the original design) puts the BRAM one cycle behind:
  // it latches P at the end of the cycle in which pc = P, so mem[P] arrives
  // while pc = P + 4, and every instruction reached IF/ID tagged with the PC
  // of the one after it. auipc at pc 8 wrote 12. It went unseen because the
  // testbench answered within the cycle, which no BRAM can do.
  //
  // During reset the address is forced to the reset vector, so the word
  // waiting at the BRAM output on the first cycle after reset is mem[0],
  // matching pc. A stall re-presents pc, so the BRAM reads the word it is
  // already holding again while the pc stays put. A redirect presents the
  // target, so the BRAM fetches it on the same edge the pc takes it -- the
  // first useful instruction after a taken branch is waiting one cycle later.
  // One mux feeds both the pc and the BRAM.
  //
  // Redirect outranks stall in the mux, although the two cannot both fire:
  // the stall needs a load in EX, the redirect a branch or jump in EX, and EX
  // holds one instruction. (A Phase B property.) If they could, the redirect
  // would have to win -- the stalled instruction is on the wrong path.
  //
  // Cost: imem_addr_o comes out of this mux rather than straight off a flop,
  // so the pc + 4 adder, the stall comparator and now the branch comparator
  // and target adder in EX all sit on the path into the BRAM address pins.
  logic [XLEN-1:0] pc, pc_next;
  logic            stall;      // load-use; driven by riscv_hazard in ID
  logic            redirect;   // taken branch or jump; driven in EX
  logic [XLEN-1:0] redirect_target;
  logic            freeze;     // a trap in EX, or after; driven in EX

  always_comb begin
    if      (redirect)        pc_next = redirect_target;
    else if (stall || freeze) pc_next = pc;
    else                      pc_next = pc + 32'd4;
  end

  assign imem_addr_o = rst_i ? RESET_VECTOR : pc_next;

  always_ff @(posedge clk_i) begin
    if (rst_i) pc <= RESET_VECTOR;
    else       pc <= pc_next;
  end

  // IF/ID. Reset injects a NOP so ID never sees X on the first cycle. A stall
  // holds it: the instruction waiting on a load stays in ID for another cycle.
  // A redirect flushes it: the word at the BRAM output is the one after the
  // branch, on the wrong path. A freeze does not need to: ID/EX takes a
  // bubble every cycle from then on, so the word here can never issue, and
  // redirect's flush is already the critical path's endpoint.
  always_ff @(posedge clk_i) begin
    if (rst_i || redirect) begin
      if_id_pc_o    <= RESET_VECTOR;
      if_id_instr_o <= NOP;
    end else if (!stall) begin
      if_id_pc_o    <= pc;
      if_id_instr_o <= imem_rdata_i;
    end
  end

  // ---------------------------------------------------------------- ID -----
  logic [ADDR_W-1:0] dec_rs1_addr, dec_rs2_addr, dec_rd_addr;
  logic [XLEN-1:0]   dec_imm;
  logic [2:0]        dec_funct3;
  logic              dec_alu_alt, dec_a_sel_pc, dec_a_sel_zero, dec_b_sel_imm;
  logic              dec_branch, dec_jump, dec_jalr;
  logic              dec_mem_read, dec_mem_write;
  logic [2:0]        dec_mem_funct3;
  logic              dec_rd_we;
  logic              dec_halt;

  riscv_decoder #(
      .XLEN   (XLEN),
      .ADDR_W (ADDR_W)
  ) u_decoder (
      .instr_i          (if_id_instr_o),
      .rs1_addr_o       (dec_rs1_addr),
      .rs2_addr_o       (dec_rs2_addr),
      .rd_addr_o        (dec_rd_addr),
      .imm_o            (dec_imm),
      .funct3_o         (dec_funct3),
      .alu_alt_o        (dec_alu_alt),
      .alu_a_sel_pc_o   (dec_a_sel_pc),
      .alu_a_sel_zero_o (dec_a_sel_zero),
      .alu_b_sel_imm_o  (dec_b_sel_imm),
      .branch_o         (dec_branch),
      .jump_o           (dec_jump),
      .jalr_o           (dec_jalr),
      .mem_read_o       (dec_mem_read),
      .mem_write_o      (dec_mem_write),
      .mem_funct3_o     (dec_mem_funct3),
      .rd_we_o          (dec_rd_we),
      .halt_o           (dec_halt)
  );

  logic [XLEN-1:0] rf_rs1_rdata, rf_rs2_rdata;

`ifdef FORMAL
  // f_reg: the one register the forwarding properties track (see the
  // properties at the end of this file). In a proof it is anyconst -- the
  // solver's choice, fixed for the whole trace -- so a proof for it is a
  // proof for every register. Simulation has no solver to choose, so it
  // tracks x1, the register the random programs and riscv-tests write most.
  // Declared here because the register file's observation port reads it.
`ifdef VERILATOR
  logic [ADDR_W-1:0] f_reg;
  assign f_reg = ADDR_W'(1);
`else
  (* anyconst *) logic [ADDR_W-1:0] f_reg;
`endif
  logic [XLEN-1:0] f_reg_stored;   // what the register file holds for f_reg
`endif

  // Driven by WB, below. Declared here because the register file is
  // instantiated in ID: it is read in ID and written in WB.
  logic [XLEN-1:0] wb_rd_wdata;

  riscv_regfile #(
      .XLEN   (XLEN),
      .ADDR_W (ADDR_W)
  ) u_regfile (
      .clk_i       (clk_i),
`ifdef FORMAL
      .f_raddr_i   (f_reg),
      .f_rdata_o   (f_reg_stored),
`endif
      .rs1_addr_i  (dec_rs1_addr),
      .rs1_rdata_o (rf_rs1_rdata),
      .rs2_addr_i  (dec_rs2_addr),
      .rs2_rdata_o (rf_rs2_rdata),
      .rd_we_i     (wb_rd_we_o),
      .rd_addr_i   (wb_rd_addr_o),
      .rd_wdata_i  (wb_rd_wdata)
  );

  // ID/EX. Resets to a NOP's decode: x0 sources and destination, zero data, so
  // EX never sees X and never appears to write a real register on cycle one.
  //
  // A stall inserts a bubble while IF/ID holds the waiting instruction; a
  // redirect inserts one in place of the wrong-path instruction in ID. A
  // bubble only has to be INERT, so only the six bits that can act are
  // cleared: rd_we (register write, forwarding), mem_read (load-use stall, WB
  // select), mem_write, branch and jump (redirect), and halt. Every other
  // field is consumed only under one of those six, so in a bubble it may hold the
  // wrong-path instruction's values -- they compute a result nothing writes.
  //
  // Clearing all ~170 flops instead puts redirect, the end of the critical
  // path, onto that many synchronous-reset pins. The cost of not doing so is
  // visibility: id_ex_pc_o / id_ex_instr_o show the squashed instruction
  // during a bubble, not a NOP. RVFI's valid bit has to tell bubbles apart
  // anyway (docs/rvfi-plan.md).
  //
  // RVFI note: id_ex_rs1_rdata_o / id_ex_rs2_rdata_o are what the register
  // file returned, which is NOT what the instruction computed with whenever
  // forwarding fires. The architectural operand values are ex_rs1 / ex_rs2,
  // the forwarding mux outputs in EX; that is where rvfi_rs1_rdata /
  // rvfi_rs2_rdata must be tapped -- docs/rvfi-plan.md.
  //
  // Control travels with its instruction rather than being re-decoded in EX.
  // Re-decoding would need the instruction word in every stage and would have
  // to be kept in step with the decoder by hand.
  logic [2:0] id_ex_funct3;
  logic       id_ex_alu_alt, id_ex_a_sel_pc, id_ex_a_sel_zero, id_ex_b_sel_imm;
  logic       id_ex_branch, id_ex_jump, id_ex_jalr;
  logic       id_ex_mem_read, id_ex_mem_write;
  logic [2:0] id_ex_mem_funct3;
  logic       id_ex_rd_we;
  logic       id_ex_halt;

  // Hazard detection. The forwarding selects are decided here in ID and
  // registered into ID/EX (id_ex_fwd_*), so EX's muxes switch off flops --
  // see riscv_hazard. The stall is consumed in IF, IF/ID and here.
  logic fwd_rs1_ex_mem, fwd_rs1_mem_wb, fwd_rs2_ex_mem, fwd_rs2_mem_wb;
  logic id_ex_fwd_rs1_ex_mem, id_ex_fwd_rs1_mem_wb;
  logic id_ex_fwd_rs2_ex_mem, id_ex_fwd_rs2_mem_wb;

  riscv_hazard #(
      .ADDR_W (ADDR_W)
  ) u_hazard (
      .id_rs1_addr_i    (dec_rs1_addr),
      .id_rs2_addr_i    (dec_rs2_addr),
      .ex_rd_addr_i     (id_ex_rd_addr_o),
      .ex_rd_we_i       (id_ex_rd_we),
      .ex_mem_read_i    (id_ex_mem_read),
      .mem_rd_addr_i    (ex_mem_rd_addr_o),
      .mem_rd_we_i      (ex_mem_rd_we_o),
      .fwd_rs1_ex_mem_o (fwd_rs1_ex_mem),
      .fwd_rs1_mem_wb_o (fwd_rs1_mem_wb),
      .fwd_rs2_ex_mem_o (fwd_rs2_ex_mem),
      .fwd_rs2_mem_wb_o (fwd_rs2_mem_wb),
      .stall_o          (stall)
  );

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      id_ex_pc_o        <= RESET_VECTOR;
      id_ex_instr_o     <= NOP;
      id_ex_rs1_addr_o  <= '0;
      id_ex_rs2_addr_o  <= '0;
      id_ex_rs1_rdata_o <= '0;
      id_ex_rs2_rdata_o <= '0;
      id_ex_imm_o       <= '0;
      id_ex_rd_addr_o   <= '0;
      id_ex_funct3      <= 3'b000;
      id_ex_alu_alt     <= 1'b0;
      id_ex_a_sel_pc    <= 1'b0;
      id_ex_a_sel_zero  <= 1'b1;
      id_ex_b_sel_imm   <= 1'b1;
      id_ex_jalr        <= 1'b0;
      id_ex_mem_funct3  <= 3'b000;
      id_ex_fwd_rs1_ex_mem <= 1'b0;
      id_ex_fwd_rs1_mem_wb <= 1'b0;
      id_ex_fwd_rs2_ex_mem <= 1'b0;
      id_ex_fwd_rs2_mem_wb <= 1'b0;
    end else begin
      id_ex_pc_o        <= if_id_pc_o;
      id_ex_instr_o     <= if_id_instr_o;
      id_ex_rs1_addr_o  <= dec_rs1_addr;
      id_ex_rs2_addr_o  <= dec_rs2_addr;
      id_ex_rs1_rdata_o <= rf_rs1_rdata;
      id_ex_rs2_rdata_o <= rf_rs2_rdata;
      id_ex_imm_o       <= dec_imm;
      id_ex_rd_addr_o   <= dec_rd_addr;
      id_ex_funct3      <= dec_funct3;
      id_ex_alu_alt     <= dec_alu_alt;
      id_ex_a_sel_pc    <= dec_a_sel_pc;
      id_ex_a_sel_zero  <= dec_a_sel_zero;
      id_ex_b_sel_imm   <= dec_b_sel_imm;
      id_ex_jalr        <= dec_jalr;
      id_ex_mem_funct3  <= dec_mem_funct3;
      id_ex_fwd_rs1_ex_mem <= fwd_rs1_ex_mem;
      id_ex_fwd_rs1_mem_wb <= fwd_rs1_mem_wb;
      id_ex_fwd_rs2_ex_mem <= fwd_rs2_ex_mem;
      id_ex_fwd_rs2_mem_wb <= fwd_rs2_mem_wb;
    end
  end

  // The six bits a bubble clears. halt is one of them for the same reason as
  // branch: a stall bubble holds a copy of the instruction in ID, so an
  // EBREAK stalled behind a load (its rs2 field is 1) would otherwise halt a
  // cycle early, from the bubble, and the real EBREAK would never retire.
  always_ff @(posedge clk_i) begin
    if (rst_i || stall || redirect || freeze) begin
      id_ex_rd_we       <= 1'b0;
      id_ex_mem_read    <= 1'b0;
      id_ex_mem_write   <= 1'b0;
      id_ex_branch      <= 1'b0;
      id_ex_jump        <= 1'b0;
      id_ex_halt        <= 1'b0;
    end else begin
      id_ex_rd_we       <= dec_rd_we;
      id_ex_mem_read    <= dec_mem_read;
      id_ex_mem_write   <= dec_mem_write;
      id_ex_branch      <= dec_branch;
      id_ex_jump        <= dec_jump;
      id_ex_halt        <= dec_halt;
    end
  end

  // ---------------------------------------------------------------- EX -----
  // Forwarding muxes, then operand selection. ex_rs1 / ex_rs2 are the values
  // this instruction architecturally read -- the RVFI rs1_rdata / rs2_rdata
  // taps. The selects were decided in ID and arrive here off flops.
  //
  // The MEM/WB source is wb_rd_wdata, the writeback mux output, so a load's
  // data forwards along with ALU results. That makes the longest path into EX
  // BRAM output -> load alignment -> writeback mux -> forwarding mux -> ALU ->
  // EX/MEM. The out-of-context run cannot time it: dmem_rdata_i is a port with
  // no input delay.
  logic [XLEN-1:0] ex_rs1, ex_rs2;
  logic [XLEN-1:0] alu_a, alu_b, alu_result;

  always_comb begin
    if      (id_ex_fwd_rs1_ex_mem) ex_rs1 = ex_mem_alu_result_o;
    else if (id_ex_fwd_rs1_mem_wb) ex_rs1 = wb_rd_wdata;
    else                           ex_rs1 = id_ex_rs1_rdata_o;
  end

  always_comb begin
    if      (id_ex_fwd_rs2_ex_mem) ex_rs2 = ex_mem_alu_result_o;
    else if (id_ex_fwd_rs2_mem_wb) ex_rs2 = wb_rd_wdata;
    else                           ex_rs2 = id_ex_rs2_rdata_o;
  end

  always_comb begin
    if      (id_ex_a_sel_zero) alu_a = '0;
    else if (id_ex_a_sel_pc)   alu_a = id_ex_pc_o;
    else                       alu_a = ex_rs1;
  end

  assign alu_b = id_ex_b_sel_imm ? id_ex_imm_o : ex_rs2;

  riscv_alu #(
      .XLEN (XLEN)
  ) u_alu (
      .a_i      (alu_a),
      .b_i      (alu_b),
      .funct3_i (id_ex_funct3),
      .alt_i    (id_ex_alu_alt),
      .result_o (alu_result)
  );

  // Branch resolution. The condition and the target each have their own logic
  // rather than borrowing the ALU: the ALU is busy with a jump's link address,
  // and the redirect path -- comparator or adder, into pc_next, into the pc
  // and the BRAM address -- should not pass through the ALU's result mux.
  // Both take the FORWARDED operands: `addi x1, ...; beq x1, ...` back to back
  // compares the new x1.
  //
  // The branch condition is funct3, which travels as mem_funct3 -- for a
  // branch, nothing in MEM reads it.
  //
  // Target bits [1:0]. JALR clears bit 0 by the spec, and branch and JAL
  // offsets are even, so bit 1 alone marks a misaligned target -- which traps
  // when the transfer is taken (see Halt below). The redirect still masks
  // both bits, so even a trapping redirect leaves the pc word-aligned. They
  // are masked off the sum, not left out of the add: base[1:0] + imm[1:0] can
  // carry into bit 2.
  logic            branch_cond;
  logic [XLEN-1:0] target_base, target_sum;

  riscv_branch #(
      .XLEN (XLEN)
  ) u_branch (
      .a_i      (ex_rs1),
      .b_i      (ex_rs2),
      .funct3_i (id_ex_mem_funct3),
      .cond_o   (branch_cond)
  );

  assign target_base     = id_ex_jalr ? ex_rs1 : id_ex_pc_o;
  assign target_sum      = target_base + id_ex_imm_o;
  // Concatenation, not `target_sum & ~XLEN'(2'b11)`: Yosys 0.69 binds that
  // `~` to the cast's width rather than to the cast, giving a mask of 3
  // instead of ~3. Verilator and Vivado read it as intended, so simulation
  // and synthesis never showed it; riscv-formal, which runs on Yosys, did --
  // as would the LibreLane flow, whose synthesis is Yosys too.
  assign redirect_target = {target_sum[XLEN-1:2], 2'b00};

  // Bit 0 of the sum is never needed: branch and JAL offsets are even, and
  // JALR clears it by the spec. Named unused_* so lint knows it is deliberate.
  logic unused_target_bit0;
  assign unused_target_bit0 = target_sum[0];
  assign redirect        = id_ex_jump || (id_ex_branch && branch_cond);

  // A jump writes its link address, pc + 4, in place of the ALU result -- so
  // it forwards from EX/MEM and MEM/WB like any result, and WB needs no third
  // source. The select comes straight off a flop and pc + 4 off a short adder,
  // so the only cost on the ALU's path is this one mux.
  logic [XLEN-1:0] ex_link, ex_result;
  assign ex_link   = id_ex_pc_o + 32'd4;
  assign ex_result = id_ex_jump ? ex_link : alu_result;

  // Halt. Every exception resolves here, where branches do, and for the same
  // reason: by EX an instruction is known to be on the right path -- an ECALL
  // in ID may sit behind a taken branch. Two kinds:
  //
  //   id_ex_halt  ECALL / EBREAK, decided in ID, arriving on a flop.
  //   ex_trap     known only now: a load or store whose address is not a
  //               multiple of its size, or a taken branch or jump whose
  //               target has bit 1 set.
  //
  // The address's low bits get their own 2-bit add rather than coming from
  // alu_result: bits [1:0] of a sum depend only on bits [1:0] of its
  // operands, so two LUTs off the forwarding mux are exact. alu_result[0] is
  // the ALU's final mux output, which also carries SLT's full 32-bit compare;
  // synthesis cannot know a load only adds, and taking it from there put that
  // compare and the pc + 4 carry chain in series (21 levels, -0.912 ns).
  //
  // A trapping instruction has no architectural effect: EX/MEM below drops
  // its register write and memory access. riscv-formal checks exactly this
  // (rvfi_trap must equal the spec's trap, under RISCV_FORMAL_ALIGNED_MEM).
  //
  // From the cycle a trap is in EX the front end freezes: the pc holds and
  // ID/EX takes bubbles, so the two younger words -- in IF/ID and at the BRAM
  // output -- never issue. Nothing is fetched or issued again until reset.
  // Stages past EX always advance, so everything older still retires, and
  // the trapping instruction itself retires two cycles later.
  //
  // freeze may coincide with stall (a misaligned load with a dependent
  // instruction in ID) -- both hold the pc and bubble ID/EX, so they agree.
  // A misaligned taken target is left out of freeze on purpose: it is a
  // redirect, which already flushes IF/ID, bubbles ID/EX and wins the pc mux
  // (landing on the masked target), and halted_q takes over the next cycle.
  // Adding it to freeze would hang the branch comparator -- the slowest
  // logic in EX -- on a second net for no change in behaviour.
  logic [1:0] mem_addr_lo;
  logic       mem_misaligned, ex_trap, halted_q;

  assign mem_addr_lo = ex_rs1[1:0] + id_ex_imm_o[1:0];

  always_comb begin
    mem_misaligned = 1'b0;
    if (id_ex_mem_read || id_ex_mem_write) begin
      case (id_ex_mem_funct3[1:0])
        2'b01:   mem_misaligned = mem_addr_lo[0];              // halfword
        2'b10:   mem_misaligned = (mem_addr_lo != 2'b00);      // word
        default: mem_misaligned = 1'b0;                        // byte
      endcase
    end
  end

  assign ex_trap = mem_misaligned || (redirect && target_sum[1]);

  always_ff @(posedge clk_i) begin
    if      (rst_i)                 halted_q <= 1'b0;
    else if (id_ex_halt || ex_trap) halted_q <= 1'b1;
  end

  assign freeze = id_ex_halt || mem_misaligned || halted_q;

  // EX/MEM. rd_we and mem_write reset low so nothing appears to retire, and
  // nothing is stored, on cycle one. alu_result_o is the EX result: the ALU's,
  // or a jump's link address. rs2_rdata is a store's data, and it must
  // be the FORWARDED value: `addi x1, ...` directly followed by `sw x1, ...`
  // would otherwise store x1's stale contents. A trap in EX drops the
  // register write and both memory controls here, so the trapping
  // instruction reaches WB with no effect but its halt bit.
  logic [XLEN-1:0] ex_mem_rs2_rdata;
  logic            ex_mem_mem_read, ex_mem_mem_write, ex_mem_halt;
  logic [2:0]      ex_mem_mem_funct3;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      ex_mem_pc_o         <= RESET_VECTOR;
      ex_mem_instr_o      <= NOP;
      ex_mem_alu_result_o <= '0;
      ex_mem_rs2_rdata    <= '0;
      ex_mem_rd_addr_o    <= '0;
      ex_mem_mem_read     <= 1'b0;
      ex_mem_mem_write    <= 1'b0;
      ex_mem_mem_funct3   <= 3'b000;
      ex_mem_rd_we_o      <= 1'b0;
      ex_mem_halt         <= 1'b0;
    end else begin
      ex_mem_pc_o         <= id_ex_pc_o;
      ex_mem_instr_o      <= id_ex_instr_o;
      ex_mem_alu_result_o <= ex_result;
      ex_mem_rs2_rdata    <= ex_rs2;
      ex_mem_rd_addr_o    <= id_ex_rd_addr_o;
      ex_mem_mem_read     <= id_ex_mem_read  && !ex_trap;
      ex_mem_mem_write    <= id_ex_mem_write && !ex_trap;
      ex_mem_mem_funct3   <= id_ex_mem_funct3;
      ex_mem_rd_we_o      <= id_ex_rd_we && !ex_trap;
      ex_mem_halt         <= id_ex_halt || ex_trap;
    end
  end

  // --------------------------------------------------------------- MEM -----
  // One alignment block serves both directions: the store side reads EX/MEM
  // here, the load side reads MEM/WB in WB below. See riscv_mem_align for why
  // the two halves share a module.
  logic [XLEN-1:0] st_wdata, load_data;
  logic [3:0]      st_wstrb;

  // Declared ahead of use by the alignment block; driven in the MEM/WB
  // register below.
  logic [XLEN-1:0] mem_wb_alu_result;
  logic [2:0]      mem_wb_mem_funct3;

  riscv_mem_align u_mem_align (
      .st_size_i    (ex_mem_mem_funct3[1:0]),
      .st_addr_lo_i (ex_mem_alu_result_o[1:0]),
      .st_data_i    (ex_mem_rs2_rdata),
      .st_wdata_o   (st_wdata),
      .st_wstrb_o   (st_wstrb),
      .ld_funct3_i  (mem_wb_mem_funct3),
      .ld_addr_lo_i (mem_wb_alu_result[1:0]),
      .ld_rdata_i   (dmem_rdata_i),
      .ld_data_o    (load_data)
  );

  assign dmem_addr_o  = {ex_mem_alu_result_o[XLEN-1:2], 2'b00};
  assign dmem_wdata_o = st_wdata;
  // Gated by reset. EX/MEM is cleared AT the end of the reset cycle, so
  // during it the register still holds its power-up contents -- on an ASIC,
  // anything -- and an ungated port would store garbage into memory that is
  // not undefined at reset: it holds the program's data. FPGA flops and
  // simulators both start at 0, so only formal showed this (X1, below).
  logic mem_store;
  assign mem_store    = ex_mem_mem_write && !rst_i;
  assign dmem_we_o    = mem_store;
  // Gated so a non-store never shows strobes. The memory ignores them while
  // dmem_we_o is low, but rvfi_mem_wmask must read zero for anything that is
  // not a store, and this is where it will be tapped.
  assign dmem_wstrb_o = mem_store ? st_wstrb : 4'b0000;

  // MEM/WB. Load data is NOT registered here: the BRAM's own output register
  // is this stage's register for it. Registering dmem_rdata_i again would add
  // a cycle of load latency and buy nothing. The ALU result rides along both
  // as the non-load writeback value and for its low bits, which tell the load
  // side which lane to pick.
  logic [ADDR_W-1:0] mem_wb_rd_addr;
  logic              mem_wb_rd_we, mem_wb_mem_read, mem_wb_halt;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      mem_wb_pc_o        <= RESET_VECTOR;
      mem_wb_instr_o     <= NOP;
      mem_wb_alu_result  <= '0;
      mem_wb_rd_addr     <= '0;
      mem_wb_mem_read    <= 1'b0;
      mem_wb_mem_funct3  <= 3'b000;
      mem_wb_rd_we       <= 1'b0;
      mem_wb_halt        <= 1'b0;
    end else begin
      mem_wb_pc_o        <= ex_mem_pc_o;
      mem_wb_instr_o     <= ex_mem_instr_o;
      mem_wb_alu_result  <= ex_mem_alu_result_o;
      mem_wb_rd_addr     <= ex_mem_rd_addr_o;
      mem_wb_mem_read    <= ex_mem_mem_read;
      mem_wb_mem_funct3  <= ex_mem_mem_funct3;
      mem_wb_rd_we       <= ex_mem_rd_we_o;
      mem_wb_halt        <= ex_mem_halt;
    end
  end

  // ---------------------------------------------------------------- WB -----
  assign wb_rd_wdata   = mem_wb_mem_read ? load_data : mem_wb_alu_result;
  // Gated by reset for the same reason as the store above. Here it matters
  // less -- RV32I leaves x1-x31 undefined at reset -- but nothing should
  // commit while reset is held, and the rule is simpler with no exception.
  assign wb_rd_we_o    = mem_wb_rd_we && !rst_i;
  assign wb_rd_addr_o  = mem_wb_rd_addr;
  assign wb_rd_wdata_o = wb_rd_wdata;

  // halt_o rises the cycle after the halting instruction leaves WB, so when
  // it is seen nothing older is still in flight. The halt bit rides the
  // pipeline to get here, rather than halted_q being delayed by hand, so the
  // retirement and the halt are visibly the same instruction -- RVFI marks it.
  always_ff @(posedge clk_i) begin
    if      (rst_i)       halt_o <= 1'b0;
    else if (mem_wb_halt) halt_o <= 1'b1;
  end

`ifdef RISCV_FORMAL
  // ------------------------------------------------------------- RVFI -----
  // Every field is captured in the stage where it is born and rides shadow
  // registers to WB, so one record describes one instruction. See
  // docs/rvfi-plan.md for the field-by-field capture points.
  //
  // Valid bit. A bubble is not a retirement: reset NOPs, load-use bubbles and
  // flushed wrong-path words must not raise rvfi_valid, and a bubble in ID/EX
  // can even carry the squashed instruction's pc and instr. IF/ID's word is
  // valid unless reset or a redirect squashed it, and holds through a stall;
  // ID/EX's is cleared by every bubble, exactly like its six control bits.
  // Past ID nothing holds or is squashed, so the bit simply rides along.
  logic if_id_valid, id_ex_valid, ex_mem_valid, mem_wb_valid;

  always_ff @(posedge clk_i) begin
    if (rst_i || redirect) if_id_valid <= 1'b0;
    else if (!stall)       if_id_valid <= 1'b1;
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      id_ex_valid  <= 1'b0;
      ex_mem_valid <= 1'b0;
      mem_wb_valid <= 1'b0;
    end else begin
      id_ex_valid  <= if_id_valid && !stall && !redirect && !freeze;
      ex_mem_valid <= id_ex_valid;
      mem_wb_valid <= ex_mem_valid;
    end
  end

  // EX: the operands the instruction architecturally read -- the forwarding
  // mux outputs, NOT id_ex_rs*_rdata_o, which is stale whenever forwarding
  // fired (the "one that bites" in the plan) -- and the next pc. rs2's value
  // already rides EX/MEM as store data, ex_mem_rs2_rdata.
  //
  // The shadow registers have no reset: a shadow is read only when the valid
  // bit says its instruction retired, and that instruction wrote it.
  logic [XLEN-1:0]   ex_pc_wdata;
  assign ex_pc_wdata = redirect ? redirect_target : ex_link;

  logic [ADDR_W-1:0] ex_mem_rs1_addr, ex_mem_rs2_addr;
  logic [XLEN-1:0]   ex_mem_rs1_rdata, ex_mem_pc_wdata;

  always_ff @(posedge clk_i) begin
    ex_mem_rs1_addr  <= id_ex_rs1_addr_o;
    ex_mem_rs2_addr  <= id_ex_rs2_addr_o;
    ex_mem_rs1_rdata <= ex_rs1;
    ex_mem_pc_wdata  <= ex_pc_wdata;
  end

  // MEM: the access, lane-style like the port itself -- a word address, byte
  // masks, data in its lanes. The store strobes are the write mask. The read
  // mask reuses the same lane logic: mem_funct3[1:0] is the access size for
  // loads as for stores, so st_wstrb is a load's lanes too.
  logic [ADDR_W-1:0] mem_wb_rs1_addr, mem_wb_rs2_addr;
  logic [XLEN-1:0]   mem_wb_rs1_rdata, mem_wb_rs2_rdata, mem_wb_pc_wdata;
  logic [XLEN-1:0]   mem_wb_mem_addr, mem_wb_mem_wdata;
  logic [3:0]        mem_wb_mem_rmask, mem_wb_mem_wmask;

  always_ff @(posedge clk_i) begin
    mem_wb_rs1_addr  <= ex_mem_rs1_addr;
    mem_wb_rs2_addr  <= ex_mem_rs2_addr;
    mem_wb_rs1_rdata <= ex_mem_rs1_rdata;
    mem_wb_rs2_rdata <= ex_mem_rs2_rdata;
    mem_wb_pc_wdata  <= ex_mem_pc_wdata;
    mem_wb_mem_addr  <= dmem_addr_o;
    mem_wb_mem_rmask <= ex_mem_mem_read ? st_wstrb : 4'b0000;
    mem_wb_mem_wmask <= dmem_wstrb_o;
    mem_wb_mem_wdata <= dmem_wdata_o;
  end

  // WB: the record. rd reads zero when nothing is written, and rd_wdata reads
  // zero whenever rd_addr does -- riscv-formal requires both. Load data is
  // the BRAM output, which is this stage's register for it.
  logic [63:0] order;

  always_ff @(posedge clk_i) begin
    if (rst_i)             order <= '0;
    else if (mem_wb_valid) order <= order + 64'd1;
  end

  assign rvfi_valid_o     = mem_wb_valid;
  assign rvfi_order_o     = order;
  assign rvfi_insn_o      = mem_wb_instr_o;
  // Every trapping instruction sets both, since every trap halts. halt: the
  // last retirement before the core stops. trap: the instruction raised an
  // exception and had no other effect -- riscv-formal's NERV, built without
  // CSRs, reports ECALL/EBREAK the same way.
  assign rvfi_trap_o      = mem_wb_halt;
  assign rvfi_halt_o      = mem_wb_halt;
  assign rvfi_intr_o      = 1'b0;
  assign rvfi_rs1_addr_o  = mem_wb_rs1_addr;
  assign rvfi_rs2_addr_o  = mem_wb_rs2_addr;
  assign rvfi_rs1_rdata_o = mem_wb_rs1_rdata;
  assign rvfi_rs2_rdata_o = mem_wb_rs2_rdata;
  assign rvfi_rd_addr_o   = wb_rd_we_o ? wb_rd_addr_o : '0;
  assign rvfi_rd_wdata_o  = (rvfi_rd_addr_o != '0) ? wb_rd_wdata : '0;
  assign rvfi_pc_rdata_o  = mem_wb_pc_o;
  assign rvfi_pc_wdata_o  = mem_wb_pc_wdata;
  assign rvfi_mem_addr_o  = mem_wb_mem_addr;
  assign rvfi_mem_rmask_o = mem_wb_mem_rmask;
  assign rvfi_mem_wmask_o = mem_wb_mem_wmask;
  assign rvfi_mem_rdata_o = dmem_rdata_i;
  assign rvfi_mem_wdata_o = mem_wb_mem_wdata;
`endif

`ifdef FORMAL
  // ------------------------------------------------------- properties -----
  // CLAUDE.md 5.5, proven by tb/formal/core.sby (k-induction) and checked in
  // every cocotb test (Verilator --assert). Not synthesized: nothing defines
  // FORMAL for Vivado. The environment -- reset at the start, free inputs --
  // is the harness's business (tb/formal/core_formal.sv); this block only
  // states what must hold. docs/formal-properties.md lists each one.
  //
  // "Previous cycle" values are explicit flops rather than $past(): the two
  // tools that read these -- Yosys and Verilator -- sample assertions in
  // clocked blocks at different moments. Every assertion is combinational.
  // (No comment line here may begin with the word "verilator": the tool
  // takes such comments as directives to itself.)
  //
  // f_past_valid: at least one clock edge has passed, so every register has
  // been written by reset or by the pipeline. Before that the formal tools
  // start from arbitrary state, and nothing here is claimed about it.
  // f_past_valid MUST start false -- formal starts from arbitrary state, and
  // every assertion is gated on it -- so it needs an initial value, which
  // only this block may have (rtl/ proper never does; CLAUDE.md 3). Lint
  // flags both spellings: an initial block next to always_ff (MULTIDRIVEN),
  // and a declaration initialiser (PROCASSINIT). The latter is waived here,
  // for the two variables that need it, on purpose.
  /* verilator lint_off PROCASSINIT */
  logic            f_past_valid = 1'b0;
  logic            f_shadow_known = 1'b0;   // see forwarding, below
  /* verilator lint_on PROCASSINIT */
  logic            f_past_rst, f_past_stall;
  logic [XLEN-1:0] f_past_pc, f_past_if_id_pc, f_past_if_id_instr;

  always_ff @(posedge clk_i) begin
    f_past_valid       <= 1'b1;
    f_past_rst         <= rst_i;
    f_past_stall       <= stall;
    f_past_pc          <= pc;
    f_past_if_id_pc    <= if_id_pc_o;
    f_past_if_id_instr <= if_id_instr_o;
  end

  // The cycle after a load-use stall, with no reset in between -- and the
  // cycle after that, when the instruction that waited reaches EX.
  logic f_after_stall, f_after_stall_q;
  assign f_after_stall = f_past_valid && !f_past_rst && f_past_stall;

  always_ff @(posedge clk_i) f_after_stall_q <= f_after_stall && !rst_i;

  always_comb begin
    if (f_past_valid) begin
      // S1: stall and redirect never fire together. The stall needs a load in
      // EX, the redirect a branch or jump in EX, and EX holds one instruction
      // (the claim the pc mux's priority comment rests on).
      //
      // Induction proves this from k = 2 with no helper invariant: an
      // induction start state can hold an ID/EX no decoder produces (load AND
      // jump), but ID/EX is rewritten every cycle, so two steps of history
      // rule it out. k = 1 fails for every property here, because the f_past_*
      // flops can start out disagreeing with what they remember.
      assert (!(stall && redirect));
    end

    if (f_after_stall) begin
      // S2: a stalled front end holds. The instruction waiting on the load is
      // neither lost nor replaced, and the pc does not skip ahead.
      assert (pc            == f_past_pc);
      assert (if_id_pc_o    == f_past_if_id_pc);
      assert (if_id_instr_o == f_past_if_id_instr);

      // S3: the stall put a bubble into ID/EX -- every bit that can act is
      // clear -- so the waiting instruction is not issued twice.
      assert (!id_ex_rd_we && !id_ex_mem_read && !id_ex_mem_write);
      assert (!id_ex_branch && !id_ex_jump && !id_ex_halt);

      // S4: a stall lasts exactly one cycle. The bubble cannot be a load, so
      // nothing in EX can stall ID again.
      assert (!stall);
    end
  end

  // ---- No X into committed state (5.5): reset commits nothing ----
  // X1: while reset is asserted, no register write and no store. NOT gated
  // on f_past_valid: the state it guards against is exactly the arbitrary
  // power-up state before the first edge, when MEM/WB and EX/MEM hold
  // whatever the flops woke up with. An FPGA's flops power up to 0, and so
  // does a simulator's state, so neither ever shows it; an ASIC's do not.
  always_comb begin
    if (rst_i) begin
      assert (!wb_rd_we_o);
      assert (!dmem_we_o);
    end
  end

  // ---- Forwarding correctness (5.5) ----
  // EX must compute with the ARCHITECTURAL value of each source register: its
  // value once every older instruction has committed. The older instructions
  // still in flight are in EX/MEM and MEM/WB, so for the tracked register:
  //
  //   arch = 0                      if f_reg is x0
  //        = EX/MEM's result        if EX/MEM writes f_reg (the youngest older
  //                                 writer, so it wins)
  //        = MEM/WB's writeback     else if MEM/WB writes f_reg
  //        = the committed value    otherwise
  //
  // The committed value is f_shadow, a copy updated from WB's writes -- the
  // commits -- and known once f_reg has been written. Until then the register
  // holds whatever it powered up with (no regfile reset), and nothing is
  // claimed. A load in EX/MEM has no value yet (it arrives in WB): that case
  // must never meet a reader, which L1 asserts.
  //
  // Which instructions count: those RVFI's valid bit says are real, so
  // bubbles -- which carry stale register fields -- are skipped. This reuses
  // design logic (id_ex_valid) as part of the property; riscv-formal's pc
  // and reg checks cover that bit independently. The FORMAL block therefore
  // needs RISCV_FORMAL; core.sby defines both.
  logic [XLEN-1:0] f_shadow;

  always_ff @(posedge clk_i) begin
    if (wb_rd_we_o && (wb_rd_addr_o == f_reg) && (f_reg != '0)) begin
      f_shadow_known <= 1'b1;
      f_shadow       <= wb_rd_wdata;
    end
  end

  logic            f_arch_known;
  logic [XLEN-1:0] f_arch;

  always_comb begin
    f_arch_known = 1'b1;
    f_arch       = '0;
    if (f_reg == '0)                                          f_arch = '0;
    else if (ex_mem_rd_we_o && (ex_mem_rd_addr_o == f_reg)) begin
      if (ex_mem_mem_read)                                    f_arch_known = 1'b0;
      else                                                    f_arch = ex_mem_alu_result_o;
    end
    else if (wb_rd_we_o && (wb_rd_addr_o == f_reg))           f_arch = wb_rd_wdata;
    else if (f_shadow_known)                                  f_arch = f_shadow;
    else                                                      f_arch_known = 1'b0;
  end

  // A load in EX/MEM writing a register the instruction in EX names.
  logic f_load_in_mem_feeds_ex;
  assign f_load_in_mem_feeds_ex = ex_mem_mem_read && ex_mem_rd_we_o && (ex_mem_rd_addr_o != '0)
                                  && ((ex_mem_rd_addr_o == id_ex_rs1_addr_o)
                                      || (ex_mem_rd_addr_o == id_ex_rs2_addr_o));

  always_comb begin
    if (f_past_valid) begin
      // R1, the strengthening invariant: once known, the shadow and the
      // register file's storage agree. Induction needs it -- without it a
      // start state could have them differ, and no number of steps rules
      // that out, since a register can go unwritten for any length of time.
      if (f_shadow_known) assert (f_reg_stored == f_shadow);

      // Not during reset: the instruction in EX then never commits -- reset
      // clears it -- and X1 has already blocked MEM/WB's write, so "the value
      // once older instructions commit" stops being defined. The first run
      // without this guard failed exactly there, at a mid-run reset.
      if (id_ex_valid && !rst_i) begin
        // F1 / F2: the operands EX computes with are the architectural values.
        if (f_arch_known && (id_ex_rs1_addr_o == f_reg)) assert (ex_rs1 == f_arch);
        if (f_arch_known && (id_ex_rs2_addr_o == f_reg)) assert (ex_rs2 == f_arch);

        // L1: the load-use stall did its job -- no instruction in EX ever
        // needs a load result that is still in flight.
        assert (!f_load_in_mem_feeds_ex);
      end
    end
  end

  // ---- Branch flush correctness (5.5) ----
  // "No wrong-path instruction ever reaches WB", as two halves that need
  // each other:
  //
  //   B1  a stage the valid bit calls a bubble can do nothing: no write to a
  //       register other than x0 (a flushed NOP is addi x0, so rd_we alone
  //       proves nothing), no memory access, no redirect, no halt. Checked
  //       in every stage whose bits can act.
  //   B2  the valid instructions retire in control-flow order: each one's pc
  //       is the pc_wdata of the one before it, and the first after a reset
  //       is at the reset vector.
  //
  // B2 alone is not enough: the valid bits are a hand-kept copy of the flush
  // logic, not the flush itself. A design that missed a wrong-path
  // instruction while its valid bit was cleared would pass B2 and still let
  // that instruction write a register. B1 ties the copy to the design --
  // whatever the valid bits drop, the design dropped. B1 alone is not enough
  // either: it says bubbles are inert, not that wrong-path instructions are
  // bubbles. B2 says that, since a wrong-path instruction retiring valid
  // would carry the wrong pc. riscv-formal's insn checks prove each pc_wdata
  // is the spec's next pc, so together the stream that commits is the
  // program's control flow and nothing else.
  logic            f_retire;
  logic [XLEN-1:0] f_next_pc;   // the pc the next retirement must have

  // A retirement during reset is not one: WB's write is gated off (X1).
  assign f_retire = mem_wb_valid && !rst_i;

  always_ff @(posedge clk_i) begin
    if      (rst_i)    f_next_pc <= RESET_VECTOR;
    else if (f_retire) f_next_pc <= mem_wb_pc_wdata;
  end

  // For a cover: the last retirement transferred control, so the next one
  // is the first after a flush.
  logic f_retired_taken;

  always_ff @(posedge clk_i) begin
    if      (rst_i)    f_retired_taken <= 1'b0;
    else if (f_retire) f_retired_taken <= (mem_wb_pc_wdata != mem_wb_pc_o + 32'd4);
  end

  always_comb begin
    if (f_past_valid) begin
      // B1, stage by stage, oldest last.
      if (!id_ex_valid) begin
        assert (!(id_ex_rd_we && (id_ex_rd_addr_o != '0)));
        assert (!id_ex_mem_read && !id_ex_mem_write);
        assert (!id_ex_branch && !id_ex_jump && !id_ex_halt);
      end
      if (!ex_mem_valid) begin
        assert (!(ex_mem_rd_we_o && (ex_mem_rd_addr_o != '0)));
        assert (!ex_mem_mem_read && !ex_mem_mem_write && !ex_mem_halt);
      end
      if (!mem_wb_valid) begin
        assert (!(mem_wb_rd_we && (mem_wb_rd_addr != '0)));
        assert (!mem_wb_halt);
      end

      // B2.
      if (f_retire) assert (mem_wb_pc_o == f_next_pc);
    end
  end

  // Reachability: each antecedent above must actually occur, or the
  // assertions under it pass vacuously (CLAUDE.md 5.5, 9). Guarded like the
  // assertions, and outside reset: before the first edge the registers hold
  // whatever the solver picks, so a cover "reached" there proves nothing.
  // (The first run, unguarded, reported three of these at step 0.)
  always_comb begin
    if (f_past_valid && !rst_i) begin
      cover (stall);
      cover (f_after_stall);
      // The stall and a misaligned-load trap in the same cycle.
      cover (stall && freeze);
      // The instruction that waited out a stall is a taken branch or jump.
      // Not in f_after_stall's cycle: EX then holds the bubble (S3), and the
      // waiting instruction reaches EX one cycle later.
      cover (f_after_stall_q && redirect);
    end
    // X1's case after power-up: a reset arriving while a store or a register
    // write is in flight (rst_i is high here, so outside the guard above).
    if (f_past_valid && rst_i) begin
      cover (ex_mem_mem_write);
      cover (mem_wb_rd_we);
    end
    if (f_past_valid && !rst_i) begin
      // Each source of F1/F2's value, for a register that is not x0.
      if (id_ex_valid && (f_reg != '0)) begin
        cover ((id_ex_rs1_addr_o == f_reg) && id_ex_fwd_rs1_ex_mem);
        cover ((id_ex_rs1_addr_o == f_reg) && id_ex_fwd_rs1_mem_wb);
        cover ((id_ex_rs1_addr_o == f_reg) && f_shadow_known
               && !id_ex_fwd_rs1_ex_mem && !id_ex_fwd_rs1_mem_wb);
        cover ((id_ex_rs2_addr_o == f_reg) && id_ex_fwd_rs2_ex_mem);
        cover ((id_ex_rs2_addr_o == f_reg) && id_ex_fwd_rs2_mem_wb);
        cover ((id_ex_rs2_addr_o == f_reg) && f_shadow_known
               && !id_ex_fwd_rs2_ex_mem && !id_ex_fwd_rs2_mem_wb);
      end
      // B2's case: a retirement straight after a taken transfer.
      cover (f_retire && f_retired_taken);
      // B1's: the wrong-path instruction in ID, squashed by a redirect, is
      // one that would act -- a register write, a store, a jump.
      if (redirect && if_id_valid) begin
        cover (dec_rd_we && (dec_rd_addr != '0));
        cover (dec_mem_write);
        cover (dec_jump);
      end
    end
  end
`endif

endmodule
