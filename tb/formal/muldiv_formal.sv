// Formal harness: the M-extension unit (rtl/core/riscv_muldiv.sv). Its
// properties live in the RTL under `ifdef FORMAL (latency) and
// `ifdef MULDIV_ARITH (the result is the ISA's); see muldiv.sby.
//
// The environment is nothing but a reset in the first cycle. Every other
// input -- valid, ack, the operands and funct3, and reset itself -- is free
// every cycle: the unit samples valid only when idle and ack only when done,
// so a core that holds valid and waits for done before acking is one of the
// behaviours covered, not a premise of the proof. In particular the operands
// change freely while an operation runs, as forwarded values do in the core.
module muldiv_formal #(
    parameter int unsigned XLEN = 8
) (
    input logic            clk_i,
    input logic            rst_i,
    input logic            valid_i,
    input logic            ack_i,
    input logic [XLEN-1:0] a_i,
    input logic [XLEN-1:0] b_i,
    input logic [2:0]      funct3_i
);

  logic f_first = 1'b1;
  always_ff @(posedge clk_i) f_first <= 1'b0;
  always_comb if (f_first) assume (rst_i);

  riscv_muldiv #(.XLEN(XLEN)) u_dut (
      .clk_i    (clk_i),
      .rst_i    (rst_i),
      .valid_i  (valid_i),
      .ack_i    (ack_i),
      .a_i      (a_i),
      .b_i      (b_i),
      .funct3_i (funct3_i),
      .done_o   (),
      .result_o ()
  );

endmodule
