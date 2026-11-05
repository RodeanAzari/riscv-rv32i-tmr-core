// Formal harness for axi_xbar's properties (the `ifdef FORMAL block in
// rtl/bus/axi_xbar.sv: X1 handshake stability, X2 grant progress, X3
// outstanding limit, X4 write response after write data; buildplan 6.2).
// A 2 x 2 crossbar with 8-bit addresses and data: slave 0 at 0x00-0x3F,
// slave 1 at 0x40-0x7F, the rest DECERR.
//
// Every master and slave input is free, constrained only by what AXI asks
// of the blocks around the crossbar -- the assumptions below, and nothing
// about the crossbar itself:
//   masters: AR, AW, W held, payload stable, until READY
//   slaves:  R, B held, payload stable, until READY; R only for a read the
//            slave took, RLAST on its last beat; B only after the slave
//            took AW and the W beat with WLAST
// The first cycle is a reset.
module axi_xbar_formal (
    input logic clk_i,
    input logic rst_i,
    input logic [1:0][7:0] m_araddr_i, m_awaddr_i,
    input logic [1:0][7:0] m_arlen_i, m_awlen_i,
    input logic [1:0][2:0] m_arsize_i, m_awsize_i,
    input logic [1:0][1:0] m_arburst_i, m_awburst_i,
    input logic [1:0]      m_arvalid_i, m_awvalid_i, m_wvalid_i, m_wlast_i,
    input logic [1:0]      m_rready_i, m_bready_i,
    input logic [1:0][7:0] m_wdata_i,
    input logic [1:0][0:0] m_wstrb_i,
    input logic [1:0]      s_arready_i, s_awready_i, s_wready_i,
    input logic [1:0]      s_rvalid_i, s_rlast_i, s_bvalid_i,
    input logic [1:0][7:0] s_rdata_i,
    input logic [1:0][1:0] s_rresp_i, s_bresp_i
);
  localparam int N = 2, M = 2;

  logic [N-1:0]      m_arready_o, m_awready_o, m_wready_o, m_rvalid_o, m_rlast_o, m_bvalid_o;
  logic [N-1:0][7:0] m_rdata_o;
  logic [N-1:0][1:0] m_rresp_o, m_bresp_o;
  logic [M-1:0]      s_arvalid_o, s_awvalid_o, s_wvalid_o, s_wlast_o, s_rready_o, s_bready_o;
  logic [M-1:0][7:0] s_araddr_o, s_awaddr_o, s_arlen_o, s_awlen_o, s_wdata_o;
  logic [M-1:0][2:0] s_arsize_o, s_awsize_o;
  logic [M-1:0][1:0] s_arburst_o, s_awburst_o;
  logic [M-1:0][0:0] s_wstrb_o;
  logic [M:0]        f_rb, f_wb, f_wl;

  axi_xbar #(
      .N(N), .M(M), .ADDR_W(8), .DATA_W(8),
      .S_BASE({8'h40, 8'h00}),
      .S_MASK({8'hC0, 8'hC0})
  ) u_xbar (
      .clk_i, .rst_i,
      .f_rb_o (f_rb), .f_wb_o (f_wb), .f_wl_o (f_wl),
      .m_araddr_i, .m_arlen_i, .m_arsize_i, .m_arburst_i, .m_arvalid_i, .m_arready_o,
      .m_rdata_o, .m_rresp_o, .m_rlast_o, .m_rvalid_o, .m_rready_i,
      .m_awaddr_i, .m_awlen_i, .m_awsize_i, .m_awburst_i, .m_awvalid_i, .m_awready_o,
      .m_wdata_i, .m_wstrb_i, .m_wlast_i, .m_wvalid_i, .m_wready_o,
      .m_bresp_o, .m_bvalid_o, .m_bready_i,
      .s_araddr_o, .s_arlen_o, .s_arsize_o, .s_arburst_o, .s_arvalid_o, .s_arready_i,
      .s_rdata_i, .s_rresp_i, .s_rlast_i, .s_rvalid_i, .s_rready_o,
      .s_awaddr_o, .s_awlen_o, .s_awsize_o, .s_awburst_o, .s_awvalid_o, .s_awready_i,
      .s_wdata_o, .s_wstrb_o, .s_wlast_o, .s_wvalid_o, .s_wready_i,
      .s_bresp_i, .s_bvalid_i, .s_bready_o
  );

  logic f_first = 1'b1;
  always_ff @(posedge clk_i) f_first <= 1'b0;
  always_comb if (f_first) assume (rst_i);

  // ---- masters: VALID held, payload stable, until READY
  logic [N-1:0] ar_w, aw_w, w_w;
  logic [N-1:0][20:0] ar_p, aw_p;
  logic [N-1:0][9:0]  w_p;
  always_ff @(posedge clk_i) begin
    for (int m = 0; m < N; m++) begin
      ar_w[m] <= !rst_i && m_arvalid_i[m] && !m_arready_o[m];
      aw_w[m] <= !rst_i && m_awvalid_i[m] && !m_awready_o[m];
      w_w[m]  <= !rst_i && m_wvalid_i[m] && !m_wready_o[m];
      ar_p[m] <= {m_araddr_i[m], m_arlen_i[m], m_arsize_i[m], m_arburst_i[m]};
      aw_p[m] <= {m_awaddr_i[m], m_awlen_i[m], m_awsize_i[m], m_awburst_i[m]};
      w_p[m]  <= {m_wdata_i[m], m_wstrb_i[m], m_wlast_i[m]};
    end
  end
  always_comb begin
    for (int m = 0; m < N; m++) if (!f_first && !rst_i) begin
      if (ar_w[m]) assume (m_arvalid_i[m] && ar_p[m] == {m_araddr_i[m], m_arlen_i[m], m_arsize_i[m], m_arburst_i[m]});
      if (aw_w[m]) assume (m_awvalid_i[m] && aw_p[m] == {m_awaddr_i[m], m_awlen_i[m], m_awsize_i[m], m_awburst_i[m]});
      if (w_w[m])  assume (m_wvalid_i[m] && w_p[m] == {m_wdata_i[m], m_wstrb_i[m], m_wlast_i[m]});
    end
  end

  // ---- slaves: R and B only for what they took, held until READY
  logic [M-1:0]      r_out, aw_in, wl_in, r_w, b_w;
  logic [M-1:0][7:0] r_left;
  logic [M-1:0][10:0] r_p;
  logic [M-1:0][1:0]  b_p;
  always_ff @(posedge clk_i) begin
    for (int s = 0; s < M; s++) begin
      if (rst_i) begin
        r_out[s] <= 1'b0; aw_in[s] <= 1'b0; wl_in[s] <= 1'b0;
      end else begin
        if (s_arvalid_o[s] && s_arready_i[s]) begin
          r_out[s] <= 1'b1; r_left[s] <= s_arlen_o[s];
        end else if (s_rvalid_i[s] && s_rready_o[s]) begin
          if (r_left[s] == 0) r_out[s] <= 1'b0;
          else                r_left[s] <= r_left[s] - 1'b1;
        end
        if (s_awvalid_o[s] && s_awready_i[s]) aw_in[s] <= 1'b1;
        if (s_wvalid_o[s] && s_wready_i[s] && s_wlast_o[s]) wl_in[s] <= 1'b1;
        if (s_bvalid_i[s] && s_bready_o[s]) begin
          aw_in[s] <= 1'b0; wl_in[s] <= 1'b0;
        end
      end
      r_w[s] <= !rst_i && s_rvalid_i[s] && !s_rready_o[s];
      b_w[s] <= !rst_i && s_bvalid_i[s] && !s_bready_o[s];
      r_p[s] <= {s_rdata_i[s], s_rresp_i[s], s_rlast_i[s]};
      b_p[s] <= s_bresp_i[s];
    end
  end
  always_comb begin
    for (int s = 0; s < M; s++) if (!f_first && !rst_i) begin
      if (s_rvalid_i[s]) assume (r_out[s] && s_rlast_i[s] == (r_left[s] == 0));
      if (s_bvalid_i[s]) assume (aw_in[s] && wl_in[s]);
      // a slave takes no second address while one is outstanding
      if (r_out[s]) assume (!s_arready_i[s]);
      if (aw_in[s]) assume (!s_awready_i[s]);
      if (wl_in[s]) assume (!s_wready_i[s]);
      if (r_w[s]) assume (s_rvalid_i[s] && r_p[s] == {s_rdata_i[s], s_rresp_i[s], s_rlast_i[s]});
      if (b_w[s]) assume (s_bvalid_i[s] && b_p[s] == s_bresp_i[s]);
    end
  end

  // strengthening invariants: each slave's view of its transactions is the
  // crossbar's (true from reset; induction needs to be told)
  always_comb begin
    if (!f_first && !rst_i)
      for (int s = 0; s < M; s++) begin
        assert (r_out[s] == f_rb[s]);
        assert (aw_in[s] == f_wb[s]);
        assert (wl_in[s] == f_wl[s]);
      end
  end

  // reachability: each kind of event happens, so the proof is not vacuous
  always_comb begin
    if (!f_first && !rst_i) begin
      cover (m_rvalid_o[0] && m_rready_i[0] && m_rlast_o[0] && m_rresp_o[0] == 2'b11);  // DECERR read
      cover (m_bvalid_o[1] && m_bready_i[1] && m_bresp_o[1] == 2'b00);
      cover (s_arvalid_o[0] && s_arready_i[0] && s_awvalid_o[1] && s_awready_i[1]);
      cover (m_arvalid_i[0] && m_arvalid_i[1] && m_araddr_i[0][7:6] == 2'b00 &&
             m_araddr_i[1][7:6] == 2'b00 && !m_arready_o[1]);              // contention
    end
  end
endmodule
