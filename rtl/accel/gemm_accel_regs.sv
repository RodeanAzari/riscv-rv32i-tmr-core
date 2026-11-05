// The GEMM accelerator's control registers (Phase G): an AXI4-Lite slave.
// Map and meaning: sw/model/accel_model.py (the golden model) and
// sw/lib/gemm.h (the driver's view).
//
//   0x00 CTRL    W: bit 0 START (ignored while busy)      R: 0
//   0x04 STATUS  R: bit 0 BUSY, bit 1 DONE, bit 2 ERROR    W: ignored
//   0x08 M, 0x0C K, 0x10 N   R/W, DIM_W bits
//   0x14 CYCLES  R: busy cycles of the last job
//   anything else reads 0, writes are ignored
//
// The handshake is dmaeng_regs': AW and W are taken independently, the
// write commits when both are held, and its response follows. As there, a
// write without all four strobes changes nothing and answers SLVERR (the
// core's driver uses sw).
module gemm_accel_regs #(
    parameter  int unsigned OFF_W = 12,
    parameter  int unsigned DIM_W = 16,
    localparam int unsigned DATA_W = 32,
    localparam int unsigned STRB_W = DATA_W / 8
) (
    input  logic              clk_i,
    input  logic              rst_i,

    input  logic [OFF_W-1:0]  s_awaddr_i,
    input  logic              s_awvalid_i,
    output logic              s_awready_o,
    input  logic [DATA_W-1:0] s_wdata_i,
    input  logic [STRB_W-1:0] s_wstrb_i,
    input  logic              s_wvalid_i,
    output logic              s_wready_o,
    output logic [1:0]        s_bresp_o,
    output logic              s_bvalid_o,
    input  logic              s_bready_i,
    input  logic [OFF_W-1:0]  s_araddr_i,
    input  logic              s_arvalid_i,
    output logic              s_arready_o,
    output logic [DATA_W-1:0] s_rdata_o,
    output logic [1:0]        s_rresp_o,
    output logic              s_rvalid_o,
    input  logic              s_rready_i,

    output logic              start_o,
    output logic [DIM_W-1:0]  m_o,
    output logic [DIM_W-1:0]  k_o,
    output logic [DIM_W-1:0]  n_o,
    input  logic              busy_i,
    input  logic              done_i,
    input  logic              error_i
);

  localparam logic [OFF_W-1:0] REG_CTRL   = OFF_W'(12'h000);
  localparam logic [OFF_W-1:0] REG_STATUS = OFF_W'(12'h004);
  localparam logic [OFF_W-1:0] REG_M      = OFF_W'(12'h008);
  localparam logic [OFF_W-1:0] REG_K      = OFF_W'(12'h00C);
  localparam logic [OFF_W-1:0] REG_N      = OFF_W'(12'h010);
  localparam logic [OFF_W-1:0] REG_CYCLES = OFF_W'(12'h014);
  localparam logic [1:0]       RESP_OKAY   = 2'b00;
  localparam logic [1:0]       RESP_SLVERR = 2'b10;

  // ---- writes ----
  logic              aw_q, w_q, bvalid_q;
  logic [OFF_W-1:0]  awaddr_q;
  logic [DATA_W-1:0] wdata_q;
  logic [STRB_W-1:0] wstrb_q;
  logic [1:0]        bresp_q;
  logic              do_write, wr_ok;

  assign do_write    = aw_q && w_q && !bvalid_q;
  assign wr_ok       = do_write && wstrb_q == '1;
  assign s_awready_o = !aw_q;
  assign s_wready_o  = !w_q;
  assign s_bvalid_o  = bvalid_q;
  assign s_bresp_o   = bresp_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      aw_q     <= 1'b0;
      w_q      <= 1'b0;
      bvalid_q <= 1'b0;
      bresp_q  <= RESP_OKAY;
      awaddr_q <= '0;
      wdata_q  <= '0;
      wstrb_q  <= '0;
    end else begin
      if (s_awvalid_i && s_awready_o) begin
        aw_q     <= 1'b1;
        awaddr_q <= s_awaddr_i;
      end
      if (s_wvalid_i && s_wready_o) begin
        w_q     <= 1'b1;
        wdata_q <= s_wdata_i;
        wstrb_q <= s_wstrb_i;
      end
      if (do_write) begin
        aw_q     <= 1'b0;
        w_q      <= 1'b0;
        bvalid_q <= 1'b1;
        bresp_q  <= wr_ok ? RESP_OKAY : RESP_SLVERR;
      end else if (bvalid_q && s_bready_i) begin
        bvalid_q <= 1'b0;
      end
    end
  end

  // ---- registers ----
  logic             done_q, error_q;
  logic [DATA_W-1:0] cycles_q;

  assign start_o = wr_ok && awaddr_q == REG_CTRL && wdata_q[0] && !busy_i;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      m_o      <= '0;
      k_o      <= '0;
      n_o      <= '0;
      done_q   <= 1'b0;
      error_q  <= 1'b0;
      cycles_q <= '0;
    end else begin
      if (wr_ok && awaddr_q == REG_M) m_o <= wdata_q[DIM_W-1:0];
      if (wr_ok && awaddr_q == REG_K) k_o <= wdata_q[DIM_W-1:0];
      if (wr_ok && awaddr_q == REG_N) n_o <= wdata_q[DIM_W-1:0];
      if (start_o) begin
        done_q   <= 1'b0;
        error_q  <= 1'b0;
        cycles_q <= '0;
      end else begin
        if (done_i)  done_q  <= 1'b1;
        if (error_i) error_q <= 1'b1;
        if (busy_i)  cycles_q <= cycles_q + 1'b1;
      end
    end
  end

  // ---- reads ----
  logic              rvalid_q;
  logic [DATA_W-1:0] rdata_q, rdata;

  always_comb begin
    case (s_araddr_i)
      REG_STATUS: rdata = {29'd0, error_q, done_q, busy_i};
      REG_M:      rdata = DATA_W'(m_o);
      REG_K:      rdata = DATA_W'(k_o);
      REG_N:      rdata = DATA_W'(n_o);
      REG_CYCLES: rdata = cycles_q;
      default:    rdata = '0;
    endcase
  end

  assign s_arready_o = !rvalid_q;
  assign s_rvalid_o  = rvalid_q;
  assign s_rdata_o   = rdata_q;
  assign s_rresp_o   = RESP_OKAY;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else if (s_arvalid_i && s_arready_o) begin
      rvalid_q <= 1'b1;
      rdata_q  <= rdata;
    end else if (rvalid_q && s_rready_i) begin
      rvalid_q <= 1'b0;
    end
  end

  logic unused_regs;
  assign unused_regs = ^{wdata_q[DATA_W-1:DIM_W]};

endmodule
