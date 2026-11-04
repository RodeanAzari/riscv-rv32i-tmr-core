// The DMA engine (Phase G, buildplan 6.3): DMA-Engine's device
// (https://github.com/RodeanAzari/DMA-Engine) as RTL. What crosses its
// boundary is what DMA-Engine 14.2 allows: one AXI4-Lite slave (registers),
// one AXI4 master (descriptors, data, status), one level interrupt; one
// clock, synchronous reset, no vendor primitives.
//
//   dmaeng_regs   AXI4-Lite slave + register file
//   dmaeng_desc   descriptor sequencer, bus-agnostic
//   dmaeng_axi    AXI4 master transport: fetch, copy (byte realigning,
//                 split at 4 KiB), status and flag writes

module dmaeng
  import dmaeng_pkg::*;
#(
  parameter  int ADDR_W    = 32,
  parameter  int DATA_W    = 32,
  parameter  int BUF_WORDS = 16,
  localparam int OFF_W     = $bits(REG_ID),
  localparam int REG_W     = 32,
  localparam int STRB_W    = DATA_W / 8,
  localparam int LEN_W     = $clog2(MAX_XFER_DEFAULT + 1),
  localparam int CODE_W    = $bits(ERR_OK)
) (
  input  logic              clk_i,
  input  logic              rst_i,

  // AXI4-Lite slave: registers
  input  logic [OFF_W-1:0]  s_awaddr_i,
  input  logic              s_awvalid_i,
  output logic              s_awready_o,
  input  logic [REG_W-1:0]  s_wdata_i,
  input  logic [3:0]        s_wstrb_i,
  input  logic              s_wvalid_i,
  output logic              s_wready_o,
  output logic [1:0]        s_bresp_o,
  output logic              s_bvalid_o,
  input  logic              s_bready_i,
  input  logic [OFF_W-1:0]  s_araddr_i,
  input  logic              s_arvalid_i,
  output logic              s_arready_o,
  output logic [REG_W-1:0]  s_rdata_o,
  output logic [1:0]        s_rresp_o,
  output logic              s_rvalid_o,
  input  logic              s_rready_i,

  // AXI4 master: memory
  output logic [ADDR_W-1:0] m_araddr_o,
  output logic [7:0]        m_arlen_o,
  output logic [2:0]        m_arsize_o,
  output logic [1:0]        m_arburst_o,
  output logic              m_arvalid_o,
  input  logic              m_arready_i,
  input  logic [DATA_W-1:0] m_rdata_i,
  input  logic [1:0]        m_rresp_i,
  input  logic              m_rlast_i,
  input  logic              m_rvalid_i,
  output logic              m_rready_o,
  output logic [ADDR_W-1:0] m_awaddr_o,
  output logic [7:0]        m_awlen_o,
  output logic [2:0]        m_awsize_o,
  output logic [1:0]        m_awburst_o,
  output logic              m_awvalid_o,
  input  logic              m_awready_i,
  output logic [DATA_W-1:0] m_wdata_o,
  output logic [STRB_W-1:0] m_wstrb_o,
  output logic              m_wlast_o,
  output logic              m_wvalid_o,
  input  logic              m_wready_i,
  input  logic [1:0]        m_bresp_i,
  input  logic              m_bvalid_i,
  output logic              m_bready_o,

  output logic              irq_o
);

  logic              run, soft_rst;
  logic [REG_W-1:0]  ring_base_lo, ring_base_hi, ring_size, head;
  logic              head_adv, done_irq, err;
  logic [CODE_W-1:0] err_code;

  logic              cmd_valid, cmd_ready, abort;
  logic [1:0]        cmd_op;
  logic [ADDR_W-1:0] cmd_src, cmd_dst;
  logic [LEN_W-1:0]  cmd_len;
  logic [REG_W-1:0]  cmd_wdata;
  logic              rd_valid, done, done_err;
  logic [DATA_W-1:0] rd_data;

  dmaeng_regs u_regs (
    .clk_i          (clk_i),
    .rst_i          (rst_i),
    .s_awaddr_i     (s_awaddr_i),
    .s_awvalid_i    (s_awvalid_i),
    .s_awready_o    (s_awready_o),
    .s_wdata_i      (s_wdata_i),
    .s_wstrb_i      (s_wstrb_i),
    .s_wvalid_i     (s_wvalid_i),
    .s_wready_o     (s_wready_o),
    .s_bresp_o      (s_bresp_o),
    .s_bvalid_o     (s_bvalid_o),
    .s_bready_i     (s_bready_i),
    .s_araddr_i     (s_araddr_i),
    .s_arvalid_i    (s_arvalid_i),
    .s_arready_o    (s_arready_o),
    .s_rdata_o      (s_rdata_o),
    .s_rresp_o      (s_rresp_o),
    .s_rvalid_o     (s_rvalid_o),
    .s_rready_i     (s_rready_i),
    .run_o          (run),
    .soft_rst_o     (soft_rst),
    .ring_base_lo_o (ring_base_lo),
    .ring_base_hi_o (ring_base_hi),
    .ring_size_o    (ring_size),
    .head_o         (head),
    .head_adv_i     (head_adv),
    .done_irq_i     (done_irq),
    .err_i          (err),
    .err_code_i     (err_code),
    .irq_o          (irq_o)
  );

  dmaeng_desc #(.ADDR_W(ADDR_W)) u_desc (
    .clk_i          (clk_i),
    .rst_i          (rst_i),
    .run_i          (run),
    .soft_rst_i     (soft_rst),
    .ring_base_lo_i (ring_base_lo),
    .ring_base_hi_i (ring_base_hi),
    .ring_size_i    (ring_size),
    .head_i         (head),
    .head_adv_o     (head_adv),
    .done_irq_o     (done_irq),
    .err_o          (err),
    .err_code_o     (err_code),
    .cmd_valid_o    (cmd_valid),
    .cmd_ready_i    (cmd_ready),
    .cmd_op_o       (cmd_op),
    .cmd_src_o      (cmd_src),
    .cmd_dst_o      (cmd_dst),
    .cmd_len_o      (cmd_len),
    .cmd_wdata_o    (cmd_wdata),
    .abort_o        (abort),
    .rd_valid_i     (rd_valid),
    .rd_data_i      (rd_data),
    .done_i         (done),
    .done_err_i     (done_err)
  );

  dmaeng_axi #(
    .ADDR_W    (ADDR_W),
    .DATA_W    (DATA_W),
    .BUF_WORDS (BUF_WORDS)
  ) u_axi (
    .clk_i       (clk_i),
    .rst_i       (rst_i),
    .cmd_valid_i (cmd_valid),
    .cmd_ready_o (cmd_ready),
    .cmd_op_i    (cmd_op),
    .cmd_src_i   (cmd_src),
    .cmd_dst_i   (cmd_dst),
    .cmd_len_i   (cmd_len),
    .cmd_wdata_i (cmd_wdata),
    .abort_i     (abort),
    .rd_valid_o  (rd_valid),
    .rd_data_o   (rd_data),
    .done_o      (done),
    .done_err_o  (done_err),
    .m_araddr_o  (m_araddr_o),
    .m_arlen_o   (m_arlen_o),
    .m_arsize_o  (m_arsize_o),
    .m_arburst_o (m_arburst_o),
    .m_arvalid_o (m_arvalid_o),
    .m_arready_i (m_arready_i),
    .m_rdata_i   (m_rdata_i),
    .m_rresp_i   (m_rresp_i),
    .m_rlast_i   (m_rlast_i),
    .m_rvalid_i  (m_rvalid_i),
    .m_rready_o  (m_rready_o),
    .m_awaddr_o  (m_awaddr_o),
    .m_awlen_o   (m_awlen_o),
    .m_awsize_o  (m_awsize_o),
    .m_awburst_o (m_awburst_o),
    .m_awvalid_o (m_awvalid_o),
    .m_awready_i (m_awready_i),
    .m_wdata_o   (m_wdata_o),
    .m_wstrb_o   (m_wstrb_o),
    .m_wlast_o   (m_wlast_o),
    .m_wvalid_o  (m_wvalid_o),
    .m_wready_i  (m_wready_i),
    .m_bresp_i   (m_bresp_i),
    .m_bvalid_i  (m_bvalid_i),
    .m_bready_o  (m_bready_o)
  );

endmodule
