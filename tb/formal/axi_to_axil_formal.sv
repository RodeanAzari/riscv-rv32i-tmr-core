// Formal harness for axi_to_axil (rtl/bus/axi_to_axil.sv): the AXI rules
// on both its sides, whatever the blocks around it do within theirs.
// Added with fpga-coord 0014, after test_ext found AWVALID falling before
// AWREADY when the AXI4-Lite slave takes W first (the SoC's own slaves
// always took both together, so Phase G never saw it).
//
// Environment (assumptions), 8-bit addresses:
//   upstream (the crossbar): AR, AW, W held and stable until READY; bursts
//     of up to 4 beats (arlen, awlen <= 3), W beats only after their AW
//     was taken (as the crossbar routes them)
//   downstream (the AXI4-Lite slave): R only for an AR it took, B only once
//     it took both AW and W, each held and stable until READY; it takes AW
//     and W in either order
// Properties (assertions):
//   downstream, as a master: AR, AW, W held and stable until READY
//   upstream, as a slave: R and B held and stable until READY; RLAST on
//     the burst's last beat; as many R beats and B responses as were asked
//     for, never more
// The first cycle is a reset.
module axi_to_axil_formal (
    input logic       clk_i,
    input logic       rst_i,
    input logic [7:0] s_araddr_i, s_awaddr_i,
    input logic [7:0] s_arlen_i, s_awlen_i,
    input logic [2:0] s_arsize_i, s_awsize_i,
    input logic [1:0] s_arburst_i, s_awburst_i,
    input logic       s_arvalid_i, s_awvalid_i, s_wvalid_i, s_wlast_i,
    input logic       s_rready_i, s_bready_i,
    input logic [31:0] s_wdata_i,
    input logic [3:0] s_wstrb_i,
    input logic       m_awready_i, m_wready_i, m_arready_i,
    input logic       m_bvalid_i, m_rvalid_i,
    input logic [1:0] m_bresp_i, m_rresp_i,
    input logic [31:0] m_rdata_i
);
  logic [7:0]  m_awaddr_o, m_araddr_o;
  logic        m_awvalid_o, m_wvalid_o, m_bready_o, m_arvalid_o, m_rready_o;
  logic [31:0] m_wdata_o, s_rdata_o;
  logic [3:0]  m_wstrb_o;
  logic        s_arready_o, s_awready_o, s_wready_o, s_rvalid_o, s_rlast_o, s_bvalid_o;
  logic [1:0]  s_rresp_o, s_bresp_o;

  logic [2:0] f_state;
  logic [7:0] f_left;
  logic       f_aw_done, f_w_done;

  axi_to_axil #(.ADDR_W(8)) u_dut (
      .clk_i, .rst_i,
      .f_state_o (f_state), .f_left_o (f_left),
      .f_aw_done_o (f_aw_done), .f_w_done_o (f_w_done),
      .s_araddr_i, .s_arlen_i, .s_arsize_i, .s_arburst_i, .s_arvalid_i, .s_arready_o,
      .s_rdata_o, .s_rresp_o, .s_rlast_o, .s_rvalid_o, .s_rready_i,
      .s_awaddr_i, .s_awlen_i, .s_awsize_i, .s_awburst_i, .s_awvalid_i, .s_awready_o,
      .s_wdata_i, .s_wstrb_i, .s_wlast_i, .s_wvalid_i, .s_wready_o,
      .s_bresp_o, .s_bvalid_o, .s_bready_i,
      .m_awaddr_o, .m_awvalid_o, .m_awready_i, .m_wdata_o, .m_wstrb_o, .m_wvalid_o,
      .m_wready_i, .m_bresp_i, .m_bvalid_i, .m_bready_o,
      .m_araddr_o, .m_arvalid_o, .m_arready_i, .m_rdata_i, .m_rresp_i, .m_rvalid_i,
      .m_rready_o
  );

  logic f_first = 1'b1;
  always_ff @(posedge clk_i) f_first <= 1'b0;
  always_comb if (f_first) assume (rst_i);

  logic live;
  assign live = !f_first && !rst_i;

  // ---- previous cycle, explicit flops ----
  logic        p_live;
  logic        p_sar, p_saw, p_sw, p_mr, p_mb;              // upstream / downstream VALID waiting
  logic        p_mar, p_maw, p_mw, p_sr, p_sb;              // the DUT's VALID waiting
  logic [20:0] p_sar_d, p_saw_d;
  logic [36:0] p_sw_d;
  logic [33:0] p_mr_d;
  logic [1:0]  p_mb_d;
  logic [7:0]  p_mar_d, p_maw_d;
  logic [35:0] p_mw_d;
  logic [34:0] p_sr_d;
  logic [1:0]  p_sb_d;
  always_ff @(posedge clk_i) begin
    p_live  <= live;
    p_sar   <= s_arvalid_i && !s_arready_o;
    p_saw   <= s_awvalid_i && !s_awready_o;
    p_sw    <= s_wvalid_i && !s_wready_o;
    p_mr    <= m_rvalid_i && !m_rready_o;
    p_mb    <= m_bvalid_i && !m_bready_o;
    p_mar   <= m_arvalid_o && !m_arready_i;
    p_maw   <= m_awvalid_o && !m_awready_i;
    p_mw    <= m_wvalid_o && !m_wready_i;
    p_sr    <= s_rvalid_o && !s_rready_i;
    p_sb    <= s_bvalid_o && !s_bready_i;
    p_sar_d <= {s_araddr_i, s_arlen_i, s_arsize_i, s_arburst_i};
    p_saw_d <= {s_awaddr_i, s_awlen_i, s_awsize_i, s_awburst_i};
    p_sw_d  <= {s_wdata_i, s_wstrb_i, s_wlast_i};
    p_mr_d  <= {m_rdata_i, m_rresp_i};
    p_mb_d  <= m_bresp_i;
    p_mar_d <= m_araddr_o;
    p_maw_d <= m_awaddr_o;
    p_mw_d  <= {m_wdata_o, m_wstrb_o};
    p_sr_d  <= {s_rdata_o, s_rresp_o, s_rlast_o};
    p_sb_d  <= s_bresp_o;
  end

  // ---- transaction counts ----
  // upstream: R beats owed for the read taken, W beats allowed and B owed
  // for the write taken; downstream: R and B the slave owes
  logic [8:0] up_r_left, up_w_left;
  logic       up_r_busy, up_b_owed, up_w_busy;
  logic       dn_r_owed, dn_aw_in, dn_w_in;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      up_r_busy <= 1'b0; up_w_busy <= 1'b0; up_b_owed <= 1'b0;
      up_r_left <= '0;   up_w_left <= '0;
      dn_r_owed <= 1'b0; dn_aw_in <= 1'b0; dn_w_in <= 1'b0;
    end else begin
      if (s_arvalid_i && s_arready_o) begin
        up_r_busy <= 1'b1; up_r_left <= {1'b0, s_arlen_i} + 9'd1;
      end else if (s_rvalid_o && s_rready_i) begin
        up_r_left <= up_r_left - 9'd1;
        if (up_r_left == 9'd1) up_r_busy <= 1'b0;
      end
      if (s_awvalid_i && s_awready_o) begin
        up_w_busy <= 1'b1; up_w_left <= {1'b0, s_awlen_i} + 9'd1;
      end else if (s_wvalid_i && s_wready_o) begin
        up_w_left <= up_w_left - 9'd1;
        if (up_w_left == 9'd1) up_b_owed <= 1'b1;
      end
      if (s_bvalid_o && s_bready_i) begin
        up_b_owed <= 1'b0; up_w_busy <= 1'b0;
      end
      if (m_arvalid_o && m_arready_i) dn_r_owed <= 1'b1;
      else if (m_rvalid_i && m_rready_o) dn_r_owed <= 1'b0;
      if (m_awvalid_o && m_awready_i) dn_aw_in <= 1'b1;
      if (m_wvalid_o && m_wready_i) dn_w_in <= 1'b1;
      if (m_bvalid_i && m_bready_o) begin
        dn_aw_in <= 1'b0; dn_w_in <= 1'b0;
      end
    end
  end

  // ---- environment ----
  always_comb if (live) begin
    assume (s_arlen_i <= 8'd3 && s_awlen_i <= 8'd3);
    // the crossbar: one transaction each way at a time; W only after its AW,
    // and no more beats than the burst has
    if (up_r_busy) assume (!s_arvalid_i);
    if (up_w_busy) assume (!s_awvalid_i);
    if (!up_w_busy || up_w_left == 9'd0) assume (!s_wvalid_i);
    // the slave: responses only for what it took; one of each at a time
    if (m_rvalid_i) assume (dn_r_owed);
    if (m_bvalid_i) assume (dn_aw_in && dn_w_in);
    if (dn_r_owed) assume (!m_arready_i);
    if (dn_aw_in) assume (!m_awready_i);
    if (dn_w_in) assume (!m_wready_i);
  end
  always_comb if (live && p_live) begin
    if (p_sar) assume (s_arvalid_i && p_sar_d == {s_araddr_i, s_arlen_i, s_arsize_i, s_arburst_i});
    if (p_saw) assume (s_awvalid_i && p_saw_d == {s_awaddr_i, s_awlen_i, s_awsize_i, s_awburst_i});
    if (p_sw)  assume (s_wvalid_i && p_sw_d == {s_wdata_i, s_wstrb_i, s_wlast_i});
    if (p_mr)  assume (m_rvalid_i && p_mr_d == {m_rdata_i, m_rresp_i});
    if (p_mb)  assume (m_bvalid_i && p_mb_d == m_bresp_i);
  end

  // ---- properties ----
  always_comb if (live && p_live) begin
    if (p_mar) assert (m_arvalid_o && p_mar_d == m_araddr_o);
    if (p_maw) assert (m_awvalid_o && p_maw_d == m_awaddr_o);
    if (p_mw)  assert (m_wvalid_o && p_mw_d == {m_wdata_o, m_wstrb_o});
    if (p_sr)  assert (s_rvalid_o && p_sr_d == {s_rdata_o, s_rresp_o, s_rlast_o});
    if (p_sb)  assert (s_bvalid_o && p_sb_d == s_bresp_o);
  end
  always_comb if (live) begin
    if (s_rvalid_o) assert (up_r_busy && s_rlast_o == (up_r_left == 9'd1));
    if (s_bvalid_o) assert (up_b_owed);
  end

  // ---- strengthening invariants: the converter's state is the harness's
  // view of both sides (true from reset; induction needs to be told).
  // States as axi_to_axil's state_t: 0 IDLE, 1 AR, 2 R, 3 W, 4 WB, 5 B.
  localparam logic [2:0] S_IDLE = 3'd0, S_AR = 3'd1, S_R = 3'd2, S_W = 3'd3,
                         S_WB = 3'd4, S_B = 3'd5;
  always_comb if (live) begin
    assert (f_state <= S_B);
    assert (up_r_busy == (f_state == S_AR || f_state == S_R));
    if (up_r_busy) assert (up_r_left == {1'b0, f_left} + 9'd1);
    assert (dn_r_owed == (f_state == S_R));
    assert (up_w_busy == (f_state == S_W || f_state == S_WB || f_state == S_B));
    if (f_state == S_W)  assert (up_w_left == {1'b0, f_left} + (f_w_done ? 9'd0 : 9'd1));
    if (f_state == S_WB) assert (up_w_left == {1'b0, f_left} && f_aw_done && f_w_done);
    if (f_state == S_B)  assert (up_w_left == 9'd0);
    assert (up_b_owed == (f_state == S_B ||
                          (f_left == 8'd0 && f_w_done && (f_state == S_W || f_state == S_WB))));
    assert (dn_aw_in == f_aw_done && dn_w_in == f_w_done);
    if (f_state != S_W && f_state != S_WB) assert (!f_aw_done && !f_w_done);
  end

  // ---- reachability ----
  always_comb if (live) begin
    cover (m_wvalid_o && m_wready_i && m_awvalid_o && !m_awready_i);   // W taken before AW
    cover (s_bvalid_o && s_bready_i && up_w_left == 9'd0 && p_live);    // a write burst done
    cover (s_rvalid_o && s_rready_i && s_rlast_o);                      // a read burst done
  end
endmodule
