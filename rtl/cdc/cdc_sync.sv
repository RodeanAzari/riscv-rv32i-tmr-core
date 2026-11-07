// Multi-flop synchronizer: d_i from another clock domain, q_o in clk_i's.
//
// STAGES flops in a chain, all marked ASYNC_REG so Vivado places them in one
// slice and reports them as a synchronizer (report_cdc). The first flop may
// go metastable; the rest give it a clock period each to settle. A bus is
// safe to pass only when at most one bit changes between two samples (a
// gray-coded pointer, a toggle): each bit resolves on its own, so a bus
// with several bits changing can come out as a value it never had.
//
// rst_i (clk_i's synchronous reset) clears the chain, so a flush leaves no
// stale value from before it.
//
// Formal: tb/formal/cdc_sync_meta.sv replaces this module in the proofs with
// one whose first flop takes, per changing bit, the old or the new value,
// the solver's choice. f_stages_o shows every flop to the users'
// invariants (the FIFO's pointer windows, the pulse loop).
module cdc_sync #(
    parameter int unsigned WIDTH  = 1,
    parameter int unsigned STAGES = 2
) (
    input  logic                         clk_i,
    input  logic                         rst_i,
`ifdef FORMAL
    output logic [STAGES-1:0][WIDTH-1:0] f_stages_o,   // [0] first flop
`endif
    input  logic [WIDTH-1:0]             d_i,
    output logic [WIDTH-1:0]             q_o
);

  if (STAGES < 2) begin : gen_stages_check
    $error("cdc_sync: STAGES must be at least 2");
  end

  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0][WIDTH-1:0] sync_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) sync_q <= '0;
    else       sync_q <= {sync_q[STAGES-2:0], d_i};
  end

  assign q_o = sync_q[STAGES-1];

`ifdef FORMAL
  assign f_stages_o = sync_q;
`endif

endmodule
