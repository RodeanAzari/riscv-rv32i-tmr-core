// DMA engine register file behind an AXI4-Lite slave (Phase G, buildplan 6.3).
//
// The register map is DMA-Engine's (https://github.com/RodeanAzari/DMA-Engine,
// submodule sw/dma-engine/): offsets, bits and constants come from its
// generated package, dmaeng_pkg (spec/dmaeng.yaml), so none is typed here.
// Behaviour follows its QEMU device (qemu-device/dmaeng.c), as ported to
// sw/model/dmaeng_model.py, which the testbench checks every read against.
//
// This block is the registers and the AXI4-Lite transport only. The
// descriptor engine sits behind the engine-side ports: it runs while run_o
// is high and reports back through head_adv_i, done_irq_i and err_i, so the
// descriptor logic never sees an AXI signal (buildplan 6.3 design note).
//
//   ID, VERSION, MAX_XFER   constants
//   CTRL        ENABLE stored; a write with RESET set clears every register
//               (ENABLE in that write is ignored) and pulses soft_rst_o
//   STATUS      BUSY = ENABLE && !ERROR && HEAD != TAIL (the model's
//               has_work), ERROR sticky until CTRL.RESET
//   RING_BASE_LO/HI, RING_SIZE, TAIL, IRQ_MASK   32 bits, read back as written
//   HEAD        advanced by the engine: (HEAD + 1) & (RING_SIZE - 1)
//   IRQ_STATUS  write 1 to clear; an engine set in the same cycle wins
//   ERR_CODE    the code of the last error
//   irq_o       level: |(IRQ_STATUS & IRQ_MASK)
//
// AXI4-Lite: 32-bit data. Registers are 32-bit only (DMA-Engine 5.6 rule
// 1): a write without all four strobes changes nothing and answers SLVERR.
// Unmapped offsets read 0 and ignore writes, answering OKAY, as the model
// does. Write address and data are accepted independently, in either
// order; every READY is a flop's output, never a function of a VALID.

module dmaeng_regs
  import dmaeng_pkg::*;
#(
  localparam int OFF_W  = $bits(REG_ID),    // register offset width (4 KiB)
  localparam int DATA_W = 32,
  localparam int STRB_W = DATA_W / 8,
  localparam int CODE_W = $bits(ERR_OK)
) (
  input  logic              clk_i,
  input  logic              rst_i,

  // AXI4-Lite slave
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

  // engine side
  output logic              run_o,          // descriptors to process
  output logic              soft_rst_o,     // CTRL.RESET written, one cycle
  output logic [DATA_W-1:0] ring_base_lo_o,
  output logic [DATA_W-1:0] ring_base_hi_o,
  output logic [DATA_W-1:0] ring_size_o,
  output logic [DATA_W-1:0] head_o,
  input  logic              head_adv_i,     // the descriptor at HEAD is done
  input  logic              done_irq_i,     // ... and it had DESC_IRQ set
  input  logic              err_i,          // stop with err_code_i
  input  logic [CODE_W-1:0] err_code_i,

  output logic              irq_o
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [STRB_W-1:0] STRB_ALL = '1;

  // --- registers -------------------------------------------------------------
  logic              enable_q;
  logic              error_q;
  logic [DATA_W-1:0] ring_base_lo_q, ring_base_hi_q, ring_size_q;
  logic [DATA_W-1:0] head_q, tail_q;
  logic              irq_cmpl_q, irq_err_q;     // IRQ_STATUS bits
  logic [DATA_W-1:0] irq_mask_q;
  logic [CODE_W-1:0] err_code_q;

  // --- AXI4-Lite write channel -----------------------------------------------
  logic              aw_q, w_q, bvalid_q;
  logic [OFF_W-1:0]  awaddr_q;
  logic [DATA_W-1:0] wdata_q;
  logic [STRB_W-1:0] wstrb_q;
  logic [1:0]        bresp_q;

  // both halves held and the previous response taken: perform the write
  logic do_write;
  logic wr_ok;        // full-word write: it takes effect
  assign do_write = aw_q && w_q && !bvalid_q;
  assign wr_ok    = do_write && (wstrb_q == STRB_ALL);

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

  // which register a full-word write lands in
  logic wr_ctrl, wr_reset, wr_base_lo, wr_base_hi, wr_size, wr_tail;
  logic wr_irq_status, wr_irq_mask;
  assign wr_ctrl       = wr_ok && awaddr_q == REG_CTRL;
  assign wr_reset      = wr_ctrl && wdata_q[CTRL_RESET_BIT];
  assign wr_base_lo    = wr_ok && awaddr_q == REG_RING_BASE_LO;
  assign wr_base_hi    = wr_ok && awaddr_q == REG_RING_BASE_HI;
  assign wr_size       = wr_ok && awaddr_q == REG_RING_SIZE;
  assign wr_tail       = wr_ok && awaddr_q == REG_TAIL;
  assign wr_irq_status = wr_ok && awaddr_q == REG_IRQ_STATUS;
  assign wr_irq_mask   = wr_ok && awaddr_q == REG_IRQ_MASK;

  // --- register file -------------------------------------------------------
  // CTRL.RESET wins over everything in its cycle, engine reports included:
  // it clears every register, as dmaeng.c's reset does.
  always_ff @(posedge clk_i) begin
    if (rst_i || wr_reset) begin
      enable_q       <= 1'b0;
      error_q        <= 1'b0;
      ring_base_lo_q <= '0;
      ring_base_hi_q <= '0;
      ring_size_q    <= '0;
      head_q         <= '0;
      tail_q         <= '0;
      irq_cmpl_q     <= 1'b0;
      irq_err_q      <= 1'b0;
      irq_mask_q     <= '0;
      err_code_q     <= ERR_OK;
    end else begin
      if (wr_ctrl)    enable_q       <= wdata_q[CTRL_ENABLE_BIT];
      if (wr_base_lo) ring_base_lo_q <= wdata_q;
      if (wr_base_hi) ring_base_hi_q <= wdata_q;
      if (wr_size)    ring_size_q    <= wdata_q;
      if (wr_tail)    tail_q         <= wdata_q;
      if (wr_irq_mask) irq_mask_q    <= wdata_q;
      if (head_adv_i) head_q <= (head_q + 1'b1) & (ring_size_q - 1'b1);
      if (err_i) begin
        error_q    <= 1'b1;
        err_code_q <= err_code_i;
      end
      // write 1 to clear, but a set in the same cycle is not lost
      irq_cmpl_q <= (irq_cmpl_q && !(wr_irq_status && wdata_q[IRQ_STATUS_COMPLETION_BIT]))
                    || done_irq_i;
      irq_err_q  <= (irq_err_q && !(wr_irq_status && wdata_q[IRQ_STATUS_ERROR_BIT]))
                    || err_i;
    end
  end

  // --- engine side -----------------------------------------------------------
  assign run_o          = enable_q && !error_q && (head_q != tail_q);
  assign soft_rst_o     = wr_reset;
  assign ring_base_lo_o = ring_base_lo_q;
  assign ring_base_hi_o = ring_base_hi_q;
  assign ring_size_o    = ring_size_q;
  assign head_o         = head_q;

  logic [DATA_W-1:0] irq_status;
  always_comb begin
    irq_status = '0;
    irq_status[IRQ_STATUS_COMPLETION_BIT] = irq_cmpl_q;
    irq_status[IRQ_STATUS_ERROR_BIT]      = irq_err_q;
  end
  assign irq_o = |(irq_status & irq_mask_q);

  // --- AXI4-Lite read channel ------------------------------------------------
  logic [DATA_W-1:0] rdata;
  logic [DATA_W-1:0] ctrl_rd, status_rd;
  always_comb begin
    ctrl_rd   = '0;
    ctrl_rd[CTRL_ENABLE_BIT] = enable_q;          // RESET reads 0: self-clearing
    status_rd = '0;
    status_rd[STATUS_BUSY_BIT]  = run_o;
    status_rd[STATUS_ERROR_BIT] = error_q;
    case (s_araddr_i)
      REG_ID:           rdata = ID_MAGIC;
      REG_VERSION:      rdata = VERSION;
      REG_CTRL:         rdata = ctrl_rd;
      REG_STATUS:       rdata = status_rd;
      REG_RING_BASE_LO: rdata = ring_base_lo_q;
      REG_RING_BASE_HI: rdata = ring_base_hi_q;
      REG_RING_SIZE:    rdata = ring_size_q;
      REG_HEAD:         rdata = head_q;
      REG_TAIL:         rdata = tail_q;
      REG_IRQ_STATUS:   rdata = irq_status;
      REG_IRQ_MASK:     rdata = irq_mask_q;
      REG_ERR_CODE:     rdata = {{(DATA_W - CODE_W){1'b0}}, err_code_q};
      REG_MAX_XFER:     rdata = MAX_XFER_DEFAULT;
      default:          rdata = '0;
    endcase
  end

  logic              rvalid_q;
  logic [DATA_W-1:0] rdata_q;
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

endmodule
