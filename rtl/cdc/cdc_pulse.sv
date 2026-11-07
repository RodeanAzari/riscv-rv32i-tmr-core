// Pulse synchronizer with handshake: a one-cycle pulse in the source domain
// becomes exactly one one-cycle pulse in the destination domain, whatever the
// two clocks.
//
// The pulse flips a toggle (src_tog_q); the toggle crosses (cdc_sync), and
// the destination pulses on the edge it sees and keeps the toggle it saw
// (dst_tog_q). That copy crosses back as the acknowledgement: src_busy_o is
// high from the pulse until the acknowledgement arrives, about
// 2 * SYNC_STAGES cycles of the two clocks. A pulse while busy is ignored, so
// the source must wait for !src_busy_o; one toggle in flight at a time is
// what keeps a single-bit crossing safe.
//
// Resets: synchronous, one per side, and they must overlap (as in
// cdc_async_fifo). A pulse in flight when they rise is lost.
module cdc_pulse #(
    parameter int unsigned SYNC_STAGES = 2
) (
    input  logic src_clk_i,
    input  logic src_rst_i,
    input  logic src_pulse_i,
    output logic src_busy_o,

    input  logic dst_clk_i,
    input  logic dst_rst_i,
    output logic dst_pulse_o
`ifdef FORMAL
    ,
    // for the harness's pulse count (tb/formal/cdc_pulse_formal.sv)
    output logic f_src_tog_o,
    output logic f_dst_tog_o
`endif
);

  logic src_tog_q, ack_s;            // source side
  logic dst_tog_q, tog_s;            // destination side

  assign src_busy_o  = (src_tog_q != ack_s);
  assign dst_pulse_o = (tog_s != dst_tog_q);

  always_ff @(posedge src_clk_i) begin
    if (src_rst_i)                       src_tog_q <= 1'b0;
    else if (src_pulse_i && !src_busy_o) src_tog_q <= !src_tog_q;
  end

  always_ff @(posedge dst_clk_i) begin
    if (dst_rst_i) dst_tog_q <= 1'b0;
    else           dst_tog_q <= tog_s;
  end

`ifdef FORMAL
  logic [SYNC_STAGES-1:0] f_fwd, f_ack;
`endif

  cdc_sync #(
      .WIDTH  (1),
      .STAGES (SYNC_STAGES)
  ) u_fwd_sync (
      .clk_i      (dst_clk_i),
      .rst_i      (dst_rst_i),
`ifdef FORMAL
      .f_stages_o (f_fwd),
`endif
      .d_i        (src_tog_q),
      .q_o        (tog_s)
  );

  cdc_sync #(
      .WIDTH  (1),
      .STAGES (SYNC_STAGES)
  ) u_ack_sync (
      .clk_i      (src_clk_i),
      .rst_i      (src_rst_i),
`ifdef FORMAL
      .f_stages_o (f_ack),
`endif
      .d_i        (dst_tog_q),
      .q_o        (ack_s)
  );

`ifdef FORMAL
  assign f_src_tog_o = src_tog_q;
  assign f_dst_tog_o = dst_tog_q;

  // P3: around the loop src_tog -> f_fwd -> dst_tog -> f_ack -> (src_tog),
  // the toggle changes value at most once: one toggle in flight, never two.
  // That is what makes the destination see each flip exactly once (P1, P2
  // in the harness). Proven by tb/formal/cdc_pulse.sby, checked in every
  // simulation.
  // f_loop in flop order: [0] src_tog, [1 .. S] f_fwd[0 .. S-1], [S+1]
  // dst_tog, [S+2 .. 2S+1] f_ack[0 .. S-1]
  logic [2*SYNC_STAGES+1:0] f_loop;
  int unsigned              f_flips;
  always_comb begin
    f_loop[0]               = src_tog_q;
    f_loop[SYNC_STAGES+1]   = dst_tog_q;
    for (int i = 0; i < SYNC_STAGES; i++) begin
      f_loop[1 + i]               = f_fwd[i];
      f_loop[SYNC_STAGES + 2 + i] = f_ack[i];
    end
  end
  always_comb begin
    f_flips = 0;
    for (int i = 0; i < 2 * SYNC_STAGES + 1; i++) f_flips += (f_loop[i] != f_loop[i+1]) ? 1 : 0;
    if (!src_rst_i && !dst_rst_i) assert (f_flips <= 1);
  end
`endif

endmodule
