// AXI4 slave onto a block RAM port shared with the core (Phase G): the DMA
// reaches the SoC's RAM through the core's data port B, in the cycles the
// core leaves free -- cycle stealing, decided with the user (docs/PROGRESS.md).
//
// The core has fixed priority: in a cycle with core_busy_i (a load or store
// in EX, which a hold already gates) the port is the core's and this slave
// waits. Otherwise it may drive the port (ram_en_o and its address, strobes
// and data); a read's word is at ram_rdata_i the next cycle, a cycle in
// which the core never reads the port, because it did not use it the cycle
// before. So the core never waits for the DMA, and Stage 1's timing holds.
//
// INCR bursts of full-width beats; the address wraps within the RAM (soc.sv
// decodes partially, as it always has). One beat at a time: a read beat is
// issued, then offered on R until taken; a write beat is taken on W when the
// port is free. Simple before fast -- the DMA's measured copy rate says
// whether more is worth it.

module axi_ram_port #(
  parameter  int ADDR_W = 32,
  parameter  int WORDS  = 8192,
  localparam int DATA_W = 32,
  localparam int STRB_W = DATA_W / 8,
  localparam int RAM_AW = $clog2(WORDS),
  localparam int LANE_W = $clog2(STRB_W)
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

  // the shared RAM port
  input  logic              core_busy_i,
  output logic              ram_en_o,
  output logic [RAM_AW-1:0] ram_addr_o,
  output logic [STRB_W-1:0] ram_we_o,
  output logic [DATA_W-1:0] ram_wdata_o,
  input  logic [DATA_W-1:0] ram_rdata_i
);

  localparam logic [1:0] RESP_OKAY = 2'b00;

  typedef enum logic [2:0] {S_IDLE, S_RD_ISSUE, S_RD_DATA, S_RD_OFFER, S_WR, S_B} state_t;
  state_t state_q;

  logic [RAM_AW-1:0] addr_q;
  logic [7:0]        left_q;        // beats after this one
  logic [DATA_W-1:0] rdata_q;

  // a read beat is issued when the port is free; its word arrives next cycle
  logic rd_issue, wr_take;
  assign rd_issue = state_q == S_RD_ISSUE && !core_busy_i;
  assign wr_take  = state_q == S_WR && !core_busy_i && s_wvalid_i;

  assign ram_en_o    = rd_issue || wr_take;
  assign ram_addr_o  = addr_q;
  assign ram_we_o    = wr_take ? s_wstrb_i : '0;
  assign ram_wdata_o = s_wdata_i;

  // reads take priority over writes when both arrive together
  assign s_arready_o = state_q == S_IDLE;
  assign s_awready_o = state_q == S_IDLE && !s_arvalid_i;
  assign s_rvalid_o  = state_q == S_RD_OFFER;
  assign s_rdata_o   = rdata_q;
  assign s_rresp_o   = RESP_OKAY;
  assign s_rlast_o   = left_q == '0;
  assign s_wready_o  = state_q == S_WR && !core_busy_i;
  assign s_bvalid_o  = state_q == S_B;
  assign s_bresp_o   = RESP_OKAY;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= S_IDLE;
      addr_q  <= '0;
      left_q  <= '0;
      rdata_q <= '0;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (s_arvalid_i) begin
            addr_q  <= s_araddr_i[RAM_AW+LANE_W-1:LANE_W];
            left_q  <= s_arlen_i;
            state_q <= S_RD_ISSUE;
          end else if (s_awvalid_i) begin
            addr_q  <= s_awaddr_i[RAM_AW+LANE_W-1:LANE_W];
            left_q  <= s_awlen_i;
            state_q <= S_WR;
          end
        end
        S_RD_ISSUE: if (!core_busy_i) state_q <= S_RD_DATA;
        S_RD_DATA: begin
          rdata_q <= ram_rdata_i;
          state_q <= S_RD_OFFER;
        end
        S_RD_OFFER: if (s_rready_i) begin
          if (left_q == '0) begin
            state_q <= S_IDLE;
          end else begin
            left_q  <= left_q - 1'b1;
            addr_q  <= addr_q + 1'b1;
            state_q <= S_RD_ISSUE;
          end
        end
        S_WR: if (wr_take) begin
          addr_q <= addr_q + 1'b1;
          left_q <= left_q - 1'b1;
          if (s_wlast_i) state_q <= S_B;
        end
        S_B: if (s_bready_i) state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // INCR of full-width beats is all the DMA issues (axi_mem.py checks it);
  // the upper address bits alias, as soc.sv's decode always has.
  logic unused_ax;
  assign unused_ax = ^{s_arsize_i, s_arburst_i, s_awsize_i, s_awburst_i,
                       s_araddr_i[ADDR_W-1:RAM_AW+LANE_W], s_araddr_i[LANE_W-1:0],
                       s_awaddr_i[ADDR_W-1:RAM_AW+LANE_W], s_awaddr_i[LANE_W-1:0]};

endmodule
