// Formal stand-in for rtl/cdc/cdc_sync.sv with metastability and skew: the
// proofs of cdc_async_fifo and cdc_pulse read this file instead of the real
// one.
//
// Same ports and flops, except what the first flop captures: each bit of
// d_i that has changed since the source last changed may still arrive as its
// value before that change, the solver's choice per bit per edge. That
// covers a metastable first flop settling either way and routing skew
// between bits of up to one source clock period -- the bound the board
// build's set_max_delay on these crossings is there to keep. A bus that
// changes one bit per source edge (gray, a toggle) still arrives as a value
// it had; a bus that changes several (a binary pointer) can arrive, edge
// after edge, as values it never had, and the users' properties catch
// that. The real module's ideal sampling would hide it.
module cdc_sync #(
    parameter int unsigned WIDTH  = 1,
    parameter int unsigned STAGES = 2
) (
    input  logic                         clk_i,
    input  logic                         rst_i,
    output logic [STAGES-1:0][WIDTH-1:0] f_stages_o,
    input  logic [WIDTH-1:0]             d_i,
    output logic [WIDTH-1:0]             q_o
);

  logic [WIDTH-1:0]              d_last;   // d_i one global step ago
  logic [WIDTH-1:0]              d_old;    // d_i before its latest change
  logic [WIDTH-1:0]              arrived;  // bits whose latest change a capture has seen
  logic                          clk_last;
  (* anyseq *) logic [WIDTH-1:0] pick;
  logic                          changed;
  logic [WIDTH-1:0]              old_eff, arr_eff, d_meta;
  logic [STAGES-1:0][WIDTH-1:0]  sync_q;

  // A bit may arrive old (pick) only while its latest change has not yet
  // been captured: once the first flop has seen the new value, it keeps
  // seeing it until d_i changes again. In reset d_i is taken as arrived, so
  // the first value after it is clean.
  assign changed = (d_i != d_last);
  assign old_eff = changed ? d_last : d_old;
  assign arr_eff = changed ? '0 : arrived;
  assign d_meta  = d_i ^ ((d_i ^ old_eff) & pick & ~arr_eff);

  always @($global_clock) begin
    d_last   <= d_i;
    clk_last <= clk_i;
    if (rst_i) begin
      d_old   <= d_i;
      arrived <= '1;
    end else begin
      d_old   <= old_eff;
      arrived <= (clk_i && !clk_last) ? (arr_eff | ~(sync_q[0] ^ d_i)) : arr_eff;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) sync_q <= '0;
    else       sync_q <= {sync_q[STAGES-2:0], d_meta};
  end

  // reachability: the model is not vacuous -- a stale bit does get captured
  always_comb if (!rst_i) cover (clk_i && !clk_last && |(pick & ~arr_eff & (d_i ^ old_eff)));

  assign q_o        = sync_q[STAGES-1];
  assign f_stages_o = sync_q;

endmodule
