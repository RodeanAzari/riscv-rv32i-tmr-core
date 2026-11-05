// AXI4 slave -> AXI4-Lite master (Phase G): puts an AXI4-Lite slave (the
// DMA's registers) on the AXI4 crossbar. A burst becomes one AXI4-Lite
// transaction per beat, in order, at addresses 4 apart (INCR of full-width
// beats, all this SoC's masters issue). Reads: each beat's AR, then its R
// passed through, RLAST on the last. Writes: each W beat goes out with its
// own AW; the burst's B is the worst of the beats' responses.
//
// VALIDs out are flop-decoded states or pass-throughs of VALIDs in, READYs
// out are pass-throughs of READYs in: no READY depends on a VALID.

module axi_to_axil #(
  parameter  int ADDR_W = 32,
  localparam int DATA_W = 32,
  localparam int STRB_W = DATA_W / 8
) (
  input  logic              clk_i,
  input  logic              rst_i,

  // AXI4 slave
  input  logic [ADDR_W-1:0] s_araddr_i,
  input  logic [7:0]        s_arlen_i,
  input  logic [2:0]        s_arsize_i,
  input  logic [1:0]        s_arburst_i,
  input  logic              s_arvalid_i,
  output logic              s_arready_o,
  output logic [DATA_W-1:0] s_rdata_o,
  output logic [1:0]        s_rresp_o,
  output logic              s_rlast_o,
  output logic              s_rvalid_o,
  input  logic              s_rready_i,
  input  logic [ADDR_W-1:0] s_awaddr_i,
  input  logic [7:0]        s_awlen_i,
  input  logic [2:0]        s_awsize_i,
  input  logic [1:0]        s_awburst_i,
  input  logic              s_awvalid_i,
  output logic              s_awready_o,
  input  logic [DATA_W-1:0] s_wdata_i,
  input  logic [STRB_W-1:0] s_wstrb_i,
  input  logic              s_wlast_i,
  input  logic              s_wvalid_i,
  output logic              s_wready_o,
  output logic [1:0]        s_bresp_o,
  output logic              s_bvalid_o,
  input  logic              s_bready_i,

  // AXI4-Lite master
  output logic [ADDR_W-1:0] m_awaddr_o,
  output logic              m_awvalid_o,
  input  logic              m_awready_i,
  output logic [DATA_W-1:0] m_wdata_o,
  output logic [STRB_W-1:0] m_wstrb_o,
  output logic              m_wvalid_o,
  input  logic              m_wready_i,
  input  logic [1:0]        m_bresp_i,
  input  logic              m_bvalid_i,
  output logic              m_bready_o,
  output logic [ADDR_W-1:0] m_araddr_o,
  output logic              m_arvalid_o,
  input  logic              m_arready_i,
  input  logic [DATA_W-1:0] m_rdata_i,
  input  logic [1:0]        m_rresp_i,
  input  logic              m_rvalid_i,
  output logic              m_rready_o
);

  typedef enum logic [2:0] {S_IDLE, S_AR, S_R, S_W, S_WB, S_B} state_t;
  state_t state_q;

  logic [ADDR_W-1:0] addr_q;
  logic [7:0]        left_q;            // beats after this one
  logic              aw_done_q, w_done_q;
  logic [1:0]        bresp_q;

  assign s_arready_o = state_q == S_IDLE;
  assign s_awready_o = state_q == S_IDLE && !s_arvalid_i;

  // reads: one AR per beat, R passed through
  assign m_araddr_o  = addr_q;
  assign m_arvalid_o = state_q == S_AR;
  assign s_rvalid_o  = state_q == S_R && m_rvalid_i;
  assign s_rdata_o   = m_rdata_i;
  assign s_rresp_o   = m_rresp_i;
  assign s_rlast_o   = left_q == '0;
  assign m_rready_o  = state_q == S_R && s_rready_i;

  // writes: per W beat, its AW and the beat together, then its B
  assign m_awaddr_o  = addr_q;
  assign m_awvalid_o = state_q == S_W && !aw_done_q && s_wvalid_i;
  assign m_wdata_o   = s_wdata_i;
  assign m_wstrb_o   = s_wstrb_i;
  assign m_wvalid_o  = state_q == S_W && !w_done_q && s_wvalid_i;
  assign s_wready_o  = state_q == S_W && !w_done_q && m_wready_i;
  assign m_bready_o  = state_q == S_WB;
  assign s_bvalid_o  = state_q == S_B;
  assign s_bresp_o   = bresp_q;

  // the worse of two responses (DECERR 3 > SLVERR 2 > OKAY 0)
  function automatic logic [1:0] worse(input logic [1:0] a, input logic [1:0] b);
    worse = (a > b) ? a : b;
  endfunction

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q   <= S_IDLE;
      addr_q    <= '0;
      left_q    <= '0;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
      bresp_q   <= 2'b00;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          aw_done_q <= 1'b0;
          w_done_q  <= 1'b0;
          bresp_q   <= 2'b00;
          if (s_arvalid_i) begin
            addr_q  <= s_araddr_i;
            left_q  <= s_arlen_i;
            state_q <= S_AR;
          end else if (s_awvalid_i) begin
            addr_q  <= s_awaddr_i;
            left_q  <= s_awlen_i;
            state_q <= S_W;
          end
        end
        S_AR: if (m_arready_i) state_q <= S_R;
        S_R: if (m_rvalid_i && s_rready_i) begin
          if (left_q == '0) begin
            state_q <= S_IDLE;
          end else begin
            left_q  <= left_q - 1'b1;
            addr_q  <= addr_q + ADDR_W'(STRB_W);
            state_q <= S_AR;
          end
        end
        S_W: begin
          if (m_awvalid_o && m_awready_i) aw_done_q <= 1'b1;
          if (m_wvalid_o && m_wready_i)   w_done_q  <= 1'b1;
          if ((aw_done_q || (m_awvalid_o && m_awready_i)) &&
              (w_done_q || (m_wvalid_o && m_wready_i)))
            state_q <= S_WB;
        end
        S_WB: if (m_bvalid_i) begin
          bresp_q   <= worse(bresp_q, m_bresp_i);
          aw_done_q <= 1'b0;
          w_done_q  <= 1'b0;
          if (left_q == '0) begin
            state_q <= S_B;
          end else begin
            left_q  <= left_q - 1'b1;
            addr_q  <= addr_q + ADDR_W'(STRB_W);
            state_q <= S_W;
          end
        end
        S_B: if (s_bready_i) state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // the burst's length gives RLAST/B; WLAST, size and burst type are what
  // the masters always send (INCR, full width)
  logic unused;
  assign unused = ^{s_wlast_i, s_arsize_i, s_arburst_i, s_awsize_i, s_awburst_i};

endmodule
