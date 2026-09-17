// RV32I core. Phase A: IF, ID and EX (ALU, EX/MEM).
//
// Not yet here, and deliberately so: branches and jumps (they pair with the
// flush machinery, which pairs with the hazard unit), loads and stores (they
// need MEM), and EX->EX / MEM->EX forwarding (nothing downstream exists to
// forward from). Instructions in those classes decode inert -- see the
// decoder -- rather than half-working.
//
// Instruction memory is external: the core drives imem_addr_o and captures
// imem_rdata_i one cycle later, which is the timing a BRAM gives us on the
// Arty A7. Branch redirection enters at pc_next when EX lands.
module riscv_core #(
    parameter int unsigned XLEN   = 32,
    parameter int unsigned ADDR_W = 5
) (
    input  logic            clk_i,
    input  logic            rst_i,

    // Instruction memory port (synchronous read, 1-cycle latency)
    output logic [XLEN-1:0] imem_addr_o,
    input  logic [XLEN-1:0] imem_rdata_i,

    // Register file write port.
    //
    // TEMPORARY: this belongs to the WB stage, which does not exist yet. It is
    // a port rather than a tie-off for two reasons: a constant-zero write
    // enable would let synthesis delete the whole register file, making the
    // area row in the trend table a fiction; and x0 invariance and WB->ID
    // forwarding are formal properties (§5.5) that want driving from a
    // testbench now, not after four more stages land. Collapses into WB.
    input  logic            wb_rd_we_i,
    input  logic [ADDR_W-1:0] wb_rd_addr_i,
    input  logic [XLEN-1:0] wb_rd_wdata_i,

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
    output logic              ex_mem_rd_we_o
);

  localparam logic [XLEN-1:0] RESET_VECTOR = 32'h0000_0000;
  localparam logic [XLEN-1:0] NOP          = 32'h0000_0013;  // addi x0, x0, 0

  // ---------------------------------------------------------------- IF -----
  logic [XLEN-1:0] pc, pc_next;

  assign pc_next     = pc + 32'd4;
  assign imem_addr_o = pc;

  always_ff @(posedge clk_i) begin
    if (rst_i) pc <= RESET_VECTOR;
    else       pc <= pc_next;
  end

  // IF/ID. Reset injects a NOP so ID never sees X on the first cycle.
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      if_id_pc_o    <= RESET_VECTOR;
      if_id_instr_o <= NOP;
    end else begin
      if_id_pc_o    <= pc;
      if_id_instr_o <= imem_rdata_i;
    end
  end

  // ---------------------------------------------------------------- ID -----
  logic [ADDR_W-1:0] dec_rs1_addr, dec_rs2_addr, dec_rd_addr;
  logic [XLEN-1:0]   dec_imm;
  logic [2:0]        dec_funct3;
  logic              dec_alu_alt, dec_a_sel_pc, dec_a_sel_zero, dec_b_sel_imm;
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
      .rd_we_o          (dec_rd_we)
  );

  logic [XLEN-1:0] rf_rs1_rdata, rf_rs2_rdata;

  riscv_regfile #(
      .XLEN   (XLEN),
      .ADDR_W (ADDR_W)
  ) u_regfile (
      .clk_i       (clk_i),
      .rs1_addr_i  (dec_rs1_addr),
      .rs1_rdata_o (rf_rs1_rdata),
      .rs2_addr_i  (dec_rs2_addr),
      .rs2_rdata_o (rf_rs2_rdata),
      .rd_we_i     (wb_rd_we_i),
      .rd_addr_i   (wb_rd_addr_i),
      .rd_wdata_i  (wb_rd_wdata_i)
  );

  // ID/EX. Resets to a NOP's decode: x0 sources and destination, zero data, so
  // EX never sees X and never appears to write a real register on cycle one.
  //
  // RVFI note: id_ex_rs1_rdata_o / id_ex_rs2_rdata_o are the architectural
  // operand values ONLY while no EX forwarding exists. When the EX slice adds
  // forwarding muxes, the RVFI taps for these two move to the mux outputs --
  // the value latched here becomes stale in exactly the cycles forwarding
  // fires. docs/rvfi-plan.md explains why that failure is hard to recognise.
  // Control travels with its instruction rather than being re-decoded in EX.
  // Re-decoding would need the instruction word in every stage and would have
  // to be kept in step with the decoder by hand.
  logic [2:0] id_ex_funct3;
  logic       id_ex_alu_alt, id_ex_a_sel_pc, id_ex_a_sel_zero, id_ex_b_sel_imm;
  logic       id_ex_rd_we;

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
      id_ex_rd_we       <= dec_rd_we;
    end
  end

  // ---------------------------------------------------------------- EX -----
  // Operand selection. The forwarding muxes belong here, between the ID/EX
  // register and these selects: when they arrive, they replace id_ex_rs1_rdata_o
  // and id_ex_rs2_rdata_o as the mux inputs, and the RVFI taps for
  // rvfi_rs1_rdata / rvfi_rs2_rdata move to the forwarded values -- see
  // docs/rvfi-plan.md.
  logic [XLEN-1:0] alu_a, alu_b, alu_result;

  always_comb begin
    if      (id_ex_a_sel_zero) alu_a = '0;
    else if (id_ex_a_sel_pc)   alu_a = id_ex_pc_o;
    else                       alu_a = id_ex_rs1_rdata_o;
  end

  assign alu_b = id_ex_b_sel_imm ? id_ex_imm_o : id_ex_rs2_rdata_o;

  riscv_alu #(
      .XLEN (XLEN)
  ) u_alu (
      .a_i      (alu_a),
      .b_i      (alu_b),
      .funct3_i (id_ex_funct3),
      .alt_i    (id_ex_alu_alt),
      .result_o (alu_result)
  );

  // EX/MEM. rd_we resets low so nothing appears to retire on cycle one.
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      ex_mem_pc_o         <= RESET_VECTOR;
      ex_mem_instr_o      <= NOP;
      ex_mem_alu_result_o <= '0;
      ex_mem_rd_addr_o    <= '0;
      ex_mem_rd_we_o      <= 1'b0;
    end else begin
      ex_mem_pc_o         <= id_ex_pc_o;
      ex_mem_instr_o      <= id_ex_instr_o;
      ex_mem_alu_result_o <= alu_result;
      ex_mem_rd_addr_o    <= id_ex_rd_addr_o;
      ex_mem_rd_we_o      <= id_ex_rd_we;
    end
  end

endmodule
