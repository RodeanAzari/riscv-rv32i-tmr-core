// Two neighbouring PEs of the systolic array sharing one DSP48E1
// (docs/buildplan.md 6.1: 256 MACs on 240 DSPs). Behaves as two
// systolic_pe side by side, columns 2p and 2p + 1 of the array, except that
// both see the activation in the same cycle: the pair passes it on, not each
// PE. Golden model: pack_weights() / unpack_lanes() in sw/model/gemm_model.py.
//
// Both products come from one multiply by the packed weight w0 + w1 * 2^16
// (PACK_W = 25 bits: the DSP48E1's A port): a * w0 is the low 16 bits,
// signed, and a * w1 the bits above plus the low lane's sign, borrowed from
// it. Spacing 16 rather than 17 keeps the packed weight within 25 bits
// signed for every pair of INT8 weights. The DSP only multiplies: a 16-bit
// lane cannot hold a column's sum, so the two additions are in fabric.
//
// Weights: two shadow registers shift down their columns as in systolic_pe;
// w_swap_i packs them into w_packed_q (the DSP's A register, enabled by the
// swap), in effect from the next cycle. w_swap_o passes the swap on with the
// activation.
module systolic_pe_pair #(
    parameter int unsigned DATA_W = 8,
    parameter int unsigned ACC_W  = 32
) (
    input  logic                         clk_i,
    input  logic                         rst_i,
    input  logic signed [DATA_W-1:0]     a_i,
    output logic signed [DATA_W-1:0]     a_o,
    input  logic [1:0][ACC_W-1:0]        psum_i,
    output logic [1:0][ACC_W-1:0]        psum_o,
    input  logic [1:0][DATA_W-1:0]       w_i,
    output logic [1:0][DATA_W-1:0]       w_o,
    input  logic                         w_shift_i,
    input  logic                         w_swap_i,
    output logic                         w_swap_o
);

  localparam int unsigned SHIFT  = 2 * DATA_W;           // one lane
  localparam int unsigned PACK_W = SHIFT + DATA_W + 1;   // 25
  localparam int unsigned PROD_W = PACK_W + DATA_W;      // 33

  logic [1:0][DATA_W-1:0]    w_shadow_q;
  logic signed [PACK_W-1:0]  w_packed_q;
  logic signed [PACK_W-1:0]  w_packed_d;
  logic signed [DATA_W-1:0]  a_q;
  logic                      swap_q;
  logic [1:0][ACC_W-1:0]     psum_q;

  // w0 + w1 * 2^SHIFT, both sign-extended to PACK_W by concatenation.
  assign w_packed_d = {{(PACK_W - DATA_W - SHIFT){w_shadow_q[1][DATA_W-1]}}, w_shadow_q[1], {SHIFT{1'b0}}}
                    + {{(PACK_W - DATA_W){w_shadow_q[0][DATA_W-1]}}, w_shadow_q[0]};

  // use_dsp on the product alone: on the module it also put the packing
  // adder (which only runs at a swap) in a DSP of its own, two per pair.
  (* use_dsp = "yes" *)
  logic signed [PROD_W-1:0] prod;
  logic [SHIFT-1:0]         lane0;   // a * w0, signed
  logic [PROD_W-SHIFT-1:0]  lane1;   // a * w1, signed
  logic [1:0][ACC_W-1:0]    lane_ext;

  assign prod  = a_i * w_packed_q;
  assign lane0 = prod[SHIFT-1:0];
  // The upper field, plus the borrow the low lane took if negative. Two's
  // complement addition, so the bits are the same signed or not.
  assign lane1 = prod[PROD_W-1:SHIFT] + {{(PROD_W - SHIFT - 1){1'b0}}, prod[SHIFT-1]};
  assign lane_ext[0] = {{(ACC_W - SHIFT){lane0[SHIFT-1]}}, lane0};
  assign lane_ext[1] = {{(ACC_W - (PROD_W - SHIFT)){lane1[PROD_W-SHIFT-1]}}, lane1};

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      w_shadow_q <= '0;
      w_packed_q <= '0;
      a_q        <= '0;
      swap_q     <= 1'b0;
      psum_q     <= '0;
    end else begin
      if (w_shift_i) w_shadow_q <= w_i;
      if (w_swap_i)  w_packed_q <= w_packed_d;
      a_q       <= a_i;
      swap_q    <= w_swap_i;
      psum_q[0] <= psum_i[0] + lane_ext[0];
      psum_q[1] <= psum_i[1] + lane_ext[1];
    end
  end

  assign a_o      = a_q;
  assign psum_o   = psum_q;
  assign w_o      = w_shadow_q;
  assign w_swap_o = swap_q;

endmodule
