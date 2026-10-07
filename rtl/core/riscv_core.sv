// RV32I core. Phase A: all five stages -- IF, ID, EX, MEM, WB.
//
// Not yet here, and deliberately so: branches and jumps (they pair with the
// flush machinery, which pairs with the hazard unit), and EX->EX / MEM->EX
// forwarding with the load-use stall. Branches and jumps decode inert -- see
// the decoder -- rather than half-working.
//
// WITHOUT FORWARDING, a dependent instruction must trail its producer by at
// least three instructions: the producer writes the register file in WB, and
// the register file's write-first bypass hands the value to whatever is in ID
// that same cycle. Anything closer reads a stale register. Software and tests
// pad with NOPs until the hazard unit lands.
//
// Instruction memory is external: the core drives imem_addr_o and captures
// imem_rdata_i one cycle later, which is the timing a BRAM gives us on the
// Arty A7. Branch redirection enters at pc_next when EX lands.
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

    // Instruction memory port (synchronous read, 1-cycle latency)
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
  logic       id_ex_mem_read, id_ex_mem_write;
  logic [2:0] id_ex_mem_funct3;
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
      id_ex_mem_read    <= dec_mem_read;
      id_ex_mem_write   <= dec_mem_write;
      id_ex_mem_funct3  <= dec_mem_funct3;
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

  // EX/MEM. rd_we and mem_write reset low so nothing appears to retire, and
  // nothing is stored, on cycle one. rs2_rdata is carried from here on because
  // it is a store's data -- nothing needed it past EX until now.
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
      ex_mem_alu_result_o <= alu_result;
      ex_mem_rs2_rdata    <= id_ex_rs2_rdata_o;
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
