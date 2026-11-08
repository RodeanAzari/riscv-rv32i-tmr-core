// Array clock control (Phase H box 4): the core's way to reprogram the array
// MMCM at run time, through one I/O register (soc.sv, ACLK at 0x1000_001C).
//
//   W: [15:0]  DI    data for a DRP write
//      [22:16] ADDR  DRP address
//      [23]    WE    1: the access is a write, 0: a read
//      [24]    GO    start the DRP access above (ignored while BUSY)
//      [31]    RST   the MMCM's RST, as written (every write sets it)
//   R: [15:0]  DO    the last DRP read's data
//      [16]    BUSY  a DRP access is in flight (DRDY not yet back)
//      [17]    LOCKED  the MMCM's LOCKED, synchronised
//      [31]    RST   as written
//
// Software follows AMD's flow (XAPP888; the clocking wizard's reference
// state machine, sw/model/mmcm_drp.py): RST = 1; per register a read, then
// a write of (read & mask) | bits, each waited out on BUSY; RST = 0; wait
// for LOCKED. sw/lib/aclk.c does it.
//
// The array is never released on a clock that is not locked: array_rst_o,
// which soc.sv ORs into the accelerator's reset, is high while RST is or
// LOCKED is not, whatever software does. The accelerator's own reset
// synchronizers (gemm_accel.sv) then keep its clk_i side in reset until
// clk_array has run clean edges, and its READYs low: an access to it waits
// until the clock is back. While RST is high the MMCM's outputs stop and
// LOCKED falls; between RST falling and LOCKED rising the output is not
// guaranteed (UG472), which the array, held in reset, ignores.
//
// The DRP runs on clk_i (DCLK is the core clock, arty_a7_top.sv), so the
// DRP signals need no crossing; LOCKED comes from the MMCM unclocked and is
// synchronised. DEN is high for one cycle and never again before DRDY
// (UG472: a second DEN before DRDY is an error).
module array_clk_ctl #(
    parameter int unsigned SYNC_STAGES = 2
) (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic        we_i,          // a store to ACLK
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,

    output logic        array_rst_o,   // hold the accelerator in reset

    output logic        mmcm_rst_o,
    input  logic        mmcm_locked_i, // asynchronous
    output logic        drp_den_o,
    output logic        drp_dwe_o,
    output logic [6:0]  drp_daddr_o,
    output logic [15:0] drp_di_o,
    input  logic [15:0] drp_do_i,
    input  logic        drp_drdy_i
);

  logic        go, busy_q, wr_q, locked_s;
  logic [15:0] do_q;

  assign go = we_i && wdata_i[24] && !busy_q;

  logic unused_wdata;                         // [30:25] reserved
  assign unused_wdata = ^wdata_i[30:25];

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      mmcm_rst_o  <= 1'b0;
      drp_den_o   <= 1'b0;
      drp_dwe_o   <= 1'b0;
      drp_daddr_o <= '0;
      drp_di_o    <= '0;
      busy_q      <= 1'b0;
      wr_q        <= 1'b0;
      do_q        <= '0;
    end else begin
      if (we_i) mmcm_rst_o <= wdata_i[31];
      drp_den_o <= go;
      drp_dwe_o <= go && wdata_i[23];
      if (go) begin
        drp_daddr_o <= wdata_i[22:16];
        drp_di_o    <= wdata_i[15:0];
        wr_q        <= wdata_i[23];
        busy_q      <= 1'b1;
      end else if (drp_drdy_i) begin
        busy_q <= 1'b0;
      end
      // DO is valid with DRDY; a write's means nothing, so only a read's
      // is kept (wr_q: the kind of the access in flight)
      if (drp_drdy_i && !wr_q) do_q <= drp_do_i;
    end
  end

`ifdef FORMAL
  logic [SYNC_STAGES-1:0] f_locked_stages;    // unread: no invariant needs it
  logic                   unused_f_locked;
  assign unused_f_locked = ^f_locked_stages;
`endif

  cdc_sync #(
      .WIDTH  (1),
      .STAGES (SYNC_STAGES)
  ) u_locked_sync (
      .clk_i      (clk_i),
      .rst_i      (rst_i),
`ifdef FORMAL
      .f_stages_o (f_locked_stages),
`endif
      .d_i        (mmcm_locked_i),
      .q_o        (locked_s)
  );

  assign array_rst_o = mmcm_rst_o || !locked_s;
  assign rdata_o     = {mmcm_rst_o, 13'b0, locked_s, busy_q, do_q};

`ifdef FORMAL
  // The DRP master's rules (UG472), checked in every simulation: DEN only
  // with no access in flight (it rises with busy_q, so busy_q was low the
  // cycle before), and DRDY only for an access in flight. Both judged on
  // values sampled at one edge (f_past_*), not on the input as it moves:
  // DRDY may fall in the same timestep busy_q does.
  logic f_past_busy, f_past_drdy, f_past_rst;
  always_ff @(posedge clk_i) begin
    f_past_busy <= busy_q;
    f_past_drdy <= drp_drdy_i;
    f_past_rst  <= rst_i;
  end
  always_comb if (!rst_i) begin
    assert (!(drp_den_o && f_past_busy));
    if (!f_past_rst) assert (!(f_past_drdy && !f_past_busy));
  end
`endif

endmodule
