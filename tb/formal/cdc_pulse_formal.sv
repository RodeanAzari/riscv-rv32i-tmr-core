// Formal harness for cdc_pulse (array clock domain, Phase H slice 1).
//
// Two free clocks, a free source pulse, metastable synchronizers
// (cdc_sync_meta.sv), reset as in cdc_async_fifo_formal.sv. The RTL checks
// P3 (one toggle in flight). Here, counting pulses at both ends:
//   P1  delivered = accepted, or one behind while it crosses: never a pulse
//       lost (it would fall two behind), duplicated or stretched over two
//       destination cycles (it would get ahead)
//   P2  !src_busy_o only once the last accepted pulse has been delivered
module cdc_pulse_formal #(
    parameter int unsigned SYNC_STAGES = 2
) (
    input logic src_clk_i,
    input logic src_pulse_i,
    input logic dst_clk_i
);

  localparam int unsigned RST_EDGES = SYNC_STAGES + 1;
  int unsigned f_sn = 0, f_dn = 0;
  logic rst;
  assign rst = !(f_sn >= RST_EDGES && f_dn >= RST_EDGES);
  always_ff @(posedge src_clk_i) if (rst && f_sn < RST_EDGES) f_sn <= f_sn + 1;
  always_ff @(posedge dst_clk_i) if (rst && f_dn < RST_EDGES) f_dn <= f_dn + 1;

  logic src_busy_o, dst_pulse_o, f_src_tog, f_dst_tog;

  cdc_pulse #(
      .SYNC_STAGES (SYNC_STAGES)
  ) u_pulse (
      .src_clk_i, .src_rst_i (rst), .src_pulse_i, .src_busy_o,
      .dst_clk_i, .dst_rst_i (rst), .dst_pulse_o,
      .f_src_tog_o (f_src_tog), .f_dst_tog_o (f_dst_tog)
  );

  logic [1:0] f_acc = '0, f_del = '0;
  always_ff @(posedge src_clk_i) if (!rst && src_pulse_i && !src_busy_o) f_acc <= f_acc + 1'b1;
  always_ff @(posedge dst_clk_i) if (!rst && dst_pulse_o) f_del <= f_del + 1'b1;

  always_comb begin
    if (!rst) begin
      assert (f_acc - f_del == {1'b0, f_src_tog ^ f_dst_tog});   // P1
      if (!src_busy_o) assert (f_acc == f_del);                   // P2
      cover (f_acc == 2'd3 && f_del == 2'd3 && !src_busy_o);      // three round trips
      cover (dst_pulse_o && src_busy_o);
    end
  end

endmodule
