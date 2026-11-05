// Core data port -> AXI4-Lite master (Phase G). Carries the core's loads and
// stores to the AXI region (the DMA's registers, later the accelerator's)
// and holds the core (riscv_core MEM_WAIT, dmem_ready_i) until each answers.
//
// The core issues an access from EX and expects it done in MEM. req_i is
// the access in EX for this region (soc.sv decodes it from dmem_re_o /
// dmem_we_o, which a hold already gates). It is taken at the edge it is
// seen with ready_o high, so the access moves to MEM as the bridge starts
// the transaction; ready_o is then low, holding the core with the access in
// MEM, until the response is in: one cycle of ready_o high with the load
// data on rdata_o completes it. The next access to the region can be taken
// in that same cycle, so back-to-back accesses lose no extra cycle.
//
// One transaction at a time, in program order, so a read after a write to
// the same register returns what was written. AWVALID and WVALID rise
// together; every VALID and READY here is a flop's output.
//
// The core cannot take a bus error: an SLVERR or DECERR completes the access
// (a load reads 0) and sets err_o, sticky until err_clr_i, which soc.sv
// shows to software.

module core_axil_bridge #(
  parameter  int ADDR_W = 32,
  localparam int DATA_W = 32,
  localparam int STRB_W = DATA_W / 8
) (
  input  logic              clk_i,
  input  logic              rst_i,

  // the core's access in EX, for this region
  input  logic              req_i,
  input  logic              we_i,
  input  logic [ADDR_W-1:0] addr_i,
  input  logic [DATA_W-1:0] wdata_i,
  input  logic [STRB_W-1:0] wstrb_i,
  output logic              ready_o,      // to the core's dmem_ready_i
  output logic [DATA_W-1:0] rdata_o,      // valid while ready_o completes a load
  output logic              err_o,
  input  logic              err_clr_i,

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

  typedef enum logic [2:0] {S_IDLE, S_WRITE, S_B, S_AR, S_R, S_DONE} state_t;
  state_t state_q;

  logic [ADDR_W-1:0] addr_q;
  logic [DATA_W-1:0] wdata_q, rdata_q;
  logic [STRB_W-1:0] wstrb_q;
  logic              aw_done_q, w_done_q;

  assign ready_o     = state_q == S_IDLE || state_q == S_DONE;
  assign rdata_o     = rdata_q;

  assign m_awaddr_o  = addr_q;
  assign m_awvalid_o = state_q == S_WRITE && !aw_done_q;
  assign m_wdata_o   = wdata_q;
  assign m_wstrb_o   = wstrb_q;
  assign m_wvalid_o  = state_q == S_WRITE && !w_done_q;
  assign m_bready_o  = state_q == S_B;
  assign m_araddr_o  = addr_q;
  assign m_arvalid_o = state_q == S_AR;
  assign m_rready_o  = state_q == S_R;

  logic take;
  assign take = req_i && ready_o;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q   <= S_IDLE;
      addr_q    <= '0;
      wdata_q   <= '0;
      wstrb_q   <= '0;
      rdata_q   <= '0;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
      err_o     <= 1'b0;
    end else begin
      if (err_clr_i) err_o <= 1'b0;
      unique case (state_q)
        S_IDLE, S_DONE: begin
          state_q <= S_IDLE;
          if (take) begin
            addr_q    <= addr_i;
            wdata_q   <= wdata_i;
            wstrb_q   <= wstrb_i;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
            state_q   <= we_i ? S_WRITE : S_AR;
          end
        end
        S_WRITE: begin
          if (m_awvalid_o && m_awready_i) aw_done_q <= 1'b1;
          if (m_wvalid_o && m_wready_i)   w_done_q  <= 1'b1;
          if ((aw_done_q || m_awready_i) && (w_done_q || m_wready_i)) state_q <= S_B;
        end
        S_B: if (m_bvalid_i) begin
          if (m_bresp_i[1]) err_o <= 1'b1;
          state_q <= S_DONE;
        end
        S_AR: if (m_arready_i) state_q <= S_R;
        S_R: if (m_rvalid_i) begin
          rdata_q <= m_rresp_i[1] ? '0 : m_rdata_i;
          if (m_rresp_i[1]) err_o <= 1'b1;
          state_q <= S_DONE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // RESP[0] tells SLVERR from DECERR; both are an error here.
  logic unused_resp;
  assign unused_resp = m_bresp_i[0] ^ m_rresp_i[0];

endmodule
