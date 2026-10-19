// One processing element of the weight-stationary systolic array
// (docs/buildplan.md 6.1). The golden model is sw/model/gemm_model.py: this
// is its pe(), registered.
//
// Each cycle the PE multiplies the activation arriving from the left by its
// stationary weight, adds the partial sum arriving from above, and registers
// both: the activation passes right unchanged, the sum passes down. Products
// are signed INT8 x INT8; the sum wraps at ACC_W bits, as the model's does.
//
// Weights are double-buffered so the array never waits for them: a shadow
// register shifts down the column (w_i from the PE above, w_o to the one
// below) while w_shift_i is high, during the previous tile's compute, and
// w_swap_i copies it into the active weight at the tile boundary. The active
// weight takes effect on the cycle after w_swap_i. The swap is passed right
// with the activation (w_swap_o, registered): in the array each PE then
// switches exactly when the last row of the old tile has gone through it.
module systolic_pe #(
    parameter int unsigned DATA_W = 8,
    parameter int unsigned ACC_W  = 32
) (
    input  logic                     clk_i,
    input  logic                     rst_i,
    input  logic signed [DATA_W-1:0] a_i,
    output logic signed [DATA_W-1:0] a_o,
    input  logic signed [ACC_W-1:0]  psum_i,
    output logic signed [ACC_W-1:0]  psum_o,
    input  logic signed [DATA_W-1:0] w_i,
    output logic signed [DATA_W-1:0] w_o,
    input  logic                     w_shift_i,
    input  logic                     w_swap_i,
    output logic                     w_swap_o
);

  logic signed [DATA_W-1:0] w_shadow_q;
  logic signed [DATA_W-1:0] w_q;
  logic signed [DATA_W-1:0] a_q;
  logic                     swap_q;
  logic signed [ACC_W-1:0]  psum_q;
  logic signed [2*DATA_W-1:0] prod;
  logic signed [ACC_W-1:0]  prod_ext;

  // Both operands signed: a signed product, sign-extended to the sum's
  // width by concatenation (no size cast: CLAUDE.md, Yosys reads them wrong).
  assign prod     = a_i * w_q;
  assign prod_ext = {{(ACC_W - 2 * DATA_W){prod[2*DATA_W-1]}}, prod};

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      w_shadow_q <= '0;
      w_q        <= '0;
      a_q        <= '0;
      swap_q     <= 1'b0;
      psum_q     <= '0;
    end else begin
      if (w_shift_i) w_shadow_q <= w_i;
      if (w_swap_i)  w_q        <= w_shadow_q;
      a_q    <= a_i;
      swap_q <= w_swap_i;
      psum_q <= psum_i + prod_ext;
    end
  end

  assign a_o      = a_q;
  assign psum_o   = psum_q;
  assign w_o      = w_shadow_q;
  assign w_swap_o = swap_q;

endmodule
