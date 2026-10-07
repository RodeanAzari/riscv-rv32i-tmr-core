// RV32I core. Phase A: all five stages -- IF, ID, EX, MEM, WB.
//
// Not yet here: FENCE, ECALL and EBREAK. They decode inert -- see the decoder
// -- rather than half-working.
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

    // Pipeline registers, exposed for bring-up and ILA probing. The RVFI
    // shadow fields (instr, pc, rs1_addr, rs2_addr) are carried here and go to
    // the RVFI port when WB exists -- see docs/rvfi-plan.md.
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

  always_comb begin
    if      (redirect) pc_next = redirect_target;
    else if (stall)    pc_next = pc;
    else               pc_next = pc + 32'd4;
  end

  assign imem_addr_o = rst_i ? RESET_VECTOR : pc_next;

  always_ff @(posedge clk_i) begin
    if (rst_i) pc <= RESET_VECTOR;
    else       pc <= pc_next;
  end

  // IF/ID. Reset injects a NOP so ID never sees X on the first cycle. A stall
  // holds it: the instruction waiting on a load stays in ID for another cycle.
  // A redirect flushes it: the word at the BRAM output is the one after the
  // branch, on the wrong path.
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
      .rd_we_o          (dec_rd_we)
  );

  logic [XLEN-1:0] rf_rs1_rdata, rf_rs2_rdata;
  // Driven by WB, below. Declared here because the register file is
  // instantiated in ID: it is read in ID and written in WB.
  logic [XLEN-1:0] wb_rd_wdata;

  riscv_regfile #(
      .XLEN   (XLEN),
      .ADDR_W (ADDR_W)
  ) u_regfile (
      .clk_i       (clk_i),
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
  // A stall loads the same NOP decode -- a bubble -- while IF/ID holds the
  // waiting instruction. A redirect loads it too: the instruction in ID is
  // the one directly behind the branch, on the wrong path.
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

  // Hazard detection. Forwarding selects are consumed in EX, the stall in IF,
  // IF/ID and here.
  logic fwd_rs1_ex_mem, fwd_rs1_mem_wb, fwd_rs2_ex_mem, fwd_rs2_mem_wb;

  riscv_hazard #(
      .ADDR_W (ADDR_W)
  ) u_hazard (
      .id_rs1_addr_i    (dec_rs1_addr),
      .id_rs2_addr_i    (dec_rs2_addr),
      .ex_rs1_addr_i    (id_ex_rs1_addr_o),
      .ex_rs2_addr_i    (id_ex_rs2_addr_o),
      .ex_rd_addr_i     (id_ex_rd_addr_o),
      .ex_mem_read_i    (id_ex_mem_read),
      .mem_rd_addr_i    (ex_mem_rd_addr_o),
      .mem_rd_we_i      (ex_mem_rd_we_o),
      .wb_rd_addr_i     (wb_rd_addr_o),
      .wb_rd_we_i       (wb_rd_we_o),
      .fwd_rs1_ex_mem_o (fwd_rs1_ex_mem),
      .fwd_rs1_mem_wb_o (fwd_rs1_mem_wb),
      .fwd_rs2_ex_mem_o (fwd_rs2_ex_mem),
      .fwd_rs2_mem_wb_o (fwd_rs2_mem_wb),
      .stall_o          (stall)
  );

  always_ff @(posedge clk_i) begin
    if (rst_i || stall || redirect) begin
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
      id_ex_branch      <= 1'b0;
      id_ex_jump        <= 1'b0;
      id_ex_jalr        <= 1'b0;
      id_ex_mem_read    <= 1'b0;
      id_ex_mem_write   <= 1'b0;
      id_ex_mem_funct3  <= 3'b000;
      id_ex_rd_we       <= 1'b0;
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
      id_ex_branch      <= dec_branch;
      id_ex_jump        <= dec_jump;
      id_ex_jalr        <= dec_jalr;
      id_ex_mem_read    <= dec_mem_read;
      id_ex_mem_write   <= dec_mem_write;
      id_ex_mem_funct3  <= dec_mem_funct3;
      id_ex_rd_we       <= dec_rd_we;
    end
  end

  // ---------------------------------------------------------------- EX -----
  // Forwarding muxes, then operand selection. ex_rs1 / ex_rs2 are the values
  // this instruction architecturally read -- the RVFI rs1_rdata / rs2_rdata
  // taps.
  //
  // The MEM/WB source is wb_rd_wdata, the writeback mux output, so a load's
  // data forwards along with ALU results. That makes the longest path into EX
  // BRAM output -> load alignment -> writeback mux -> forwarding mux -> ALU ->
  // EX/MEM. The out-of-context run cannot time it: dmem_rdata_i is a port with
  // no input delay.
  logic [XLEN-1:0] ex_rs1, ex_rs2;
  logic [XLEN-1:0] alu_a, alu_b, alu_result;

  always_comb begin
    if      (fwd_rs1_ex_mem) ex_rs1 = ex_mem_alu_result_o;
    else if (fwd_rs1_mem_wb) ex_rs1 = wb_rd_wdata;
    else                     ex_rs1 = id_ex_rs1_rdata_o;
  end

  always_comb begin
    if      (fwd_rs2_ex_mem) ex_rs2 = ex_mem_alu_result_o;
    else if (fwd_rs2_mem_wb) ex_rs2 = wb_rd_wdata;
    else                     ex_rs2 = id_ex_rs2_rdata_o;
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
  // Target bits [1:0] are dropped. JALR clears bit 0 by the spec; bit 1 set
  // means a misaligned target, which RV32I would trap on. Traps are out of
  // scope, so this follows the load/store misalignment assumption: the low
  // bits are ignored, and the pc stays word-aligned. They are masked off the
  // sum, not left out of the add: base[1:0] + imm[1:0] can carry into bit 2.
  logic            branch_cond;
  logic [XLEN-1:0] target_base;

  riscv_branch #(
      .XLEN (XLEN)
  ) u_branch (
      .a_i      (ex_rs1),
      .b_i      (ex_rs2),
      .funct3_i (id_ex_mem_funct3),
      .cond_o   (branch_cond)
  );

  assign target_base     = id_ex_jalr ? ex_rs1 : id_ex_pc_o;
  assign redirect_target = (target_base + id_ex_imm_o) & ~XLEN'(2'b11);
  assign redirect        = id_ex_jump || (id_ex_branch && branch_cond);

  // A jump writes its link address, pc + 4, in place of the ALU result -- so
  // it forwards from EX/MEM and MEM/WB like any result, and WB needs no third
  // source. The select comes straight off a flop and pc + 4 off a short adder,
  // so the only cost on the ALU's path is this one mux.
  logic [XLEN-1:0] ex_result;
  assign ex_result = id_ex_jump ? id_ex_pc_o + 32'd4 : alu_result;

  // EX/MEM. rd_we and mem_write reset low so nothing appears to retire, and
  // nothing is stored, on cycle one. alu_result_o is the EX result: the ALU's,
  // or a jump's link address. rs2_rdata is a store's data, and it must
  // be the FORWARDED value: `addi x1, ...` directly followed by `sw x1, ...`
  // would otherwise store x1's stale contents.
  logic [XLEN-1:0] ex_mem_rs2_rdata;
  logic            ex_mem_mem_read, ex_mem_mem_write;
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
    end else begin
      ex_mem_pc_o         <= id_ex_pc_o;
      ex_mem_instr_o      <= id_ex_instr_o;
      ex_mem_alu_result_o <= ex_result;
      ex_mem_rs2_rdata    <= ex_rs2;
      ex_mem_rd_addr_o    <= id_ex_rd_addr_o;
      ex_mem_mem_read     <= id_ex_mem_read;
      ex_mem_mem_write    <= id_ex_mem_write;
      ex_mem_mem_funct3   <= id_ex_mem_funct3;
      ex_mem_rd_we_o      <= id_ex_rd_we;
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
  assign dmem_we_o    = ex_mem_mem_write;
  // Gated so a non-store never shows strobes. The memory ignores them while
  // dmem_we_o is low, but rvfi_mem_wmask must read zero for anything that is
  // not a store, and this is where it will be tapped.
  assign dmem_wstrb_o = ex_mem_mem_write ? st_wstrb : 4'b0000;

  // MEM/WB. Load data is NOT registered here: the BRAM's own output register
  // is this stage's register for it. Registering dmem_rdata_i again would add
  // a cycle of load latency and buy nothing. The ALU result rides along both
  // as the non-load writeback value and for its low bits, which tell the load
  // side which lane to pick.
  logic [ADDR_W-1:0] mem_wb_rd_addr;
  logic              mem_wb_rd_we, mem_wb_mem_read;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      mem_wb_pc_o        <= RESET_VECTOR;
      mem_wb_instr_o     <= NOP;
      mem_wb_alu_result  <= '0;
      mem_wb_rd_addr     <= '0;
      mem_wb_mem_read    <= 1'b0;
      mem_wb_mem_funct3  <= 3'b000;
      mem_wb_rd_we       <= 1'b0;
    end else begin
      mem_wb_pc_o        <= ex_mem_pc_o;
      mem_wb_instr_o     <= ex_mem_instr_o;
      mem_wb_alu_result  <= ex_mem_alu_result_o;
      mem_wb_rd_addr     <= ex_mem_rd_addr_o;
      mem_wb_mem_read    <= ex_mem_mem_read;
      mem_wb_mem_funct3  <= ex_mem_mem_funct3;
      mem_wb_rd_we       <= ex_mem_rd_we_o;
    end
  end

  // ---------------------------------------------------------------- WB -----
  assign wb_rd_wdata   = mem_wb_mem_read ? load_data : mem_wb_alu_result;
  assign wb_rd_we_o    = mem_wb_rd_we;
  assign wb_rd_addr_o  = mem_wb_rd_addr;
  assign wb_rd_wdata_o = wb_rd_wdata;

endmodule
