// RV32I core. Phase A, step 1: PC and IF stage.
//
// Instruction memory is external: the core drives imem_addr_o and captures
// imem_rdata_i one cycle later, which is the timing a BRAM gives us on the
// Arty A7. Branch redirection enters at pc_next when EX lands.
module riscv_core (
    input  logic        clk_i,
    input  logic        rst_i,

    // Instruction memory port (synchronous read, 1-cycle latency)
    output logic [31:0] imem_addr_o,
    input  logic [31:0] imem_rdata_i,

    // IF/ID pipeline register, exposed for bring-up and ILA probing
    output logic [31:0] if_id_pc_o,
    output logic [31:0] if_id_instr_o
);

  localparam logic [31:0] RESET_VECTOR = 32'h0000_0000;
  localparam logic [31:0] NOP          = 32'h0000_0013;  // addi x0, x0, 0

  logic [31:0] pc, pc_next;

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

endmodule
