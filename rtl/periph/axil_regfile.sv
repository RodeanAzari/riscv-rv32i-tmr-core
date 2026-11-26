// A plain AXI4-Lite register file: WORDS 32-bit read/write registers,
// aliasing through the window (word index = address bits above [1:0]),
// byte strobes honoured, every response OKAY, all reset to 0. It stands on
// the SoC's external window (soc EXT_EN) in the board build, so that build
// has a real slave to time and software has something to read back; it is
// also the simplest example of a consumer's register block.
//
// A write is taken when AW and W are both valid and no B is waiting (AXI
// lets a slave wait for both); a read when no R is waiting. B and R each
// follow one cycle later and are held until taken.

module axil_regfile #(
    parameter int unsigned WORDS  = 16,
    parameter int unsigned ADDR_W = 12,
    localparam int unsigned IDX_W = (WORDS > 1) ? $clog2(WORDS) : 1
) (
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic [ADDR_W-1:0] s_awaddr_i,
    input  logic              s_awvalid_i,
    output logic              s_awready_o,
    input  logic [31:0]       s_wdata_i,
    input  logic [3:0]        s_wstrb_i,
    input  logic              s_wvalid_i,
    output logic              s_wready_o,
    output logic [1:0]        s_bresp_o,
    output logic              s_bvalid_o,
    input  logic              s_bready_i,
    input  logic [ADDR_W-1:0] s_araddr_i,
    input  logic              s_arvalid_i,
    output logic              s_arready_o,
    output logic [31:0]       s_rdata_o,
    output logic [1:0]        s_rresp_o,
    output logic              s_rvalid_o,
    input  logic              s_rready_i
);

  logic [WORDS-1:0][31:0] regs_q;
  logic                   bvalid_q, rvalid_q;
  logic [31:0]            rdata_q;

  logic do_write, do_read;
  assign do_write = s_awvalid_i && s_wvalid_i && !bvalid_q;
  assign do_read  = s_arvalid_i && !rvalid_q;

  logic [IDX_W-1:0] widx, ridx;
  assign widx = s_awaddr_i[2 +: IDX_W];
  assign ridx = s_araddr_i[2 +: IDX_W];

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      regs_q   <= '0;
      bvalid_q <= 1'b0;
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else begin
      if (do_write) begin
        for (int b = 0; b < 4; b++)
          if (s_wstrb_i[b]) regs_q[widx][8*b +: 8] <= s_wdata_i[8*b +: 8];
        bvalid_q <= 1'b1;
      end else if (s_bready_i) begin
        bvalid_q <= 1'b0;
      end
      if (do_read) begin
        rdata_q  <= regs_q[ridx];
        rvalid_q <= 1'b1;
      end else if (s_rready_i) begin
        rvalid_q <= 1'b0;
      end
    end
  end

  assign s_awready_o = do_write;
  assign s_wready_o  = do_write;
  assign s_bresp_o   = 2'b00;
  assign s_bvalid_o  = bvalid_q;
  assign s_arready_o = do_read;
  assign s_rdata_o   = rdata_q;
  assign s_rresp_o   = 2'b00;
  assign s_rvalid_o  = rvalid_q;

  // the address bits outside the index: the window aliases
  logic unused_addr;
  assign unused_addr = ^{s_awaddr_i[1:0], s_araddr_i[1:0],
                         s_awaddr_i[ADDR_W-1:2+IDX_W], s_araddr_i[ADDR_W-1:2+IDX_W]};

endmodule
