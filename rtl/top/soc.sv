// First-light SoC: the core, one dual-port RAM, four LEDs, a UART
// (transmitter and receiver) and a cycle counter. Board-independent -- clock and reset arrive ready to use --
// so cocotb can run it whole with the real program; arty_a7_top.sv adds the
// clocking and the pins.
//
// Memory map (decoded on address bits [31:28] and [4:2] only, so each region
// aliases through its window):
//
//   0x0000_0000  RAM, RAM_WORDS x 32 bits, code and data (ram_dp.sv)
//   0x1000_0000  LED      W: bits [3:0] drive the LEDs    R: their value
//   0x1000_0004  UART TX  W: bits [7:0] are sent           R: 0
//   0x1000_0008  UART ST  R: bit 0 = TX ready for a byte   W: ignored
//                            bit 1 = RX byte waiting
//                            bit 2 = RX overrun (a byte arrived unread; dropped)
//                            bit 3 = RX framing error (a byte dropped)
//   0x1000_000C  UART RX  R: bits [7:0] the waiting byte   W: acknowledge --
//                            clears bits 1-3 of UART ST, ready for the next
//   0x1000_0010  CYCLE    R: cycles since reset, mod 2^32     W: ignored
//   0x1000_0014  TMR      R: TMR mismatches since reset (0 without TMR)
//                            W: fault injection -- the word's set bits are
//                            flipped in copy B's pc, once (ignored without TMR)
//   0x1000_0018  BUSERR   R: bit 0 = an AXI access answered SLVERR/DECERR
//                            (sticky; a load from it read 0)   W: clears it
//   0x2000_0000  AXI      the AXI4-Lite region (Phase G): the DMA engine's
//                            registers at 0x2000_0000-0x2000_0FFF (DMA-Engine's
//                            map, rtl/bus/dmaeng.sv); the GEMM accelerator's
//                            registers at 0x2000_1000-0x2000_1FFF and its
//                            buffers at 0x2010_0000 (A), 0x2010_4000 (W),
//                            0x2010_8000 (C) (rtl/accel/gemm_accel.sv; the
//                            DMA fills and empties them). Loads and stores
//                            here hold the core until the bus answers
//                            (core_axil_bridge.sv); RAM and I/O never do.
//
// The DMA engine's AXI4 master reaches the RAM through the core's data port
// (port B) in the cycles the core issues no load or store: the core keeps
// fixed priority and never waits for the DMA (axi_ram_port.sv). Its
// interrupt is not connected: the core has none; software polls.
//
// The cycle counter is how software times itself (the core has no CSRs, so
// rdcycle is an illegal instruction). 32 bits wrap after 43 s at 100 MHz;
// the difference of two reads is exact for any interval shorter than that.
//
// A byte written to UART TX while it is not ready is dropped: software polls
// UART ST first. Receiving is read, then acknowledge with a write: reading
// UART RX changes nothing, because the core's data port has no read enable
// and so the SoC cannot tell a load from an address merely passing by. Byte
// stores (sb) work on every register: the core puts a byte in every lane and
// raises its strobe, and the registers read lane 0.
//
// The core's data port is BRAM-timed: the address is taken at the end of EX
// and the load data is expected during MEM. The I/O read path matches it with
// one register, so a load from I/O lands exactly like a load from RAM.
module soc #(
    parameter int unsigned CLK_HZ    = 50_000_000,
    parameter int unsigned BAUD      = 115_200,
    parameter int unsigned RAM_WORDS = 8192,
    parameter string       INIT_FILE = "",
    // Triple modular redundancy: three voted copies of the core
    // (rtl/tmr/riscv_core_tmr.sv) instead of one. Either way the core is at
    // g_cpu.u_core.
    parameter bit          TMR       = 1'b0
) (
    input  logic       clk_i,
    input  logic       rst_i,
    output logic [3:0] led_o,
    output logic       uart_tx_o,
    input  logic       uart_rx_i,

    // The core's pipeline registers and writeback, for the board top's ILA
    // (make impl ILA=1). Left open otherwise, and then trimmed.
    output logic [31:0] dbg_if_id_pc_o,
    output logic [31:0] dbg_if_id_instr_o,
    output logic [31:0] dbg_id_ex_pc_o,
    output logic [31:0] dbg_id_ex_instr_o,
    output logic [31:0] dbg_ex_mem_pc_o,
    output logic [31:0] dbg_ex_mem_instr_o,
    output logic [31:0] dbg_ex_mem_alu_result_o,
    output logic [31:0] dbg_mem_wb_pc_o,
    output logic [31:0] dbg_mem_wb_instr_o,
    output logic        dbg_wb_rd_we_o,
    output logic [4:0]  dbg_wb_rd_addr_o,
    output logic [31:0] dbg_wb_rd_wdata_o,
    output logic        dbg_halt_o
);

  localparam int unsigned RAM_AW = $clog2(RAM_WORDS);

  localparam logic [3:0] REGION_RAM = 4'h0;
  localparam logic [3:0] REGION_IO  = 4'h1;
  localparam logic [2:0] IO_LED     = 3'd0;
  localparam logic [2:0] IO_UART_TX = 3'd1;
  localparam logic [2:0] IO_UART_ST = 3'd2;
  localparam logic [2:0] IO_UART_RX = 3'd3;
  localparam logic [2:0] IO_CYCLE   = 3'd4;
  localparam logic [2:0] IO_TMR     = 3'd5;
  localparam logic [2:0] IO_BUSERR  = 3'd6;
  localparam logic [3:0] REGION_AXI = 4'h2;
  localparam int unsigned DMA_OFF_W = 12;      // the DMA's 4 KiB register window
  localparam int unsigned ACC_OFF_W = 12;      // the accelerator's, likewise
  localparam int unsigned ACC_BUF   = 16384;   // bytes per buffer (A, W, C)

  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_we;

  // The core, single or triplicated. Its remaining debug outputs (operand
  // values, RVFI) are left open on purpose: not needed by this top. Waived
  // here only.
  logic [31:0] tmr_mismatches;
  logic        io_we;
  logic        dmem_re, dmem_ready;

  /* verilator lint_off PINCONNECTEMPTY */
  if (TMR) begin : g_cpu
    // The injection, registered: a pulse a cycle after the store, so the
    // store's decode does not reach copy B's pc in the same cycle.
    logic [31:0] inject_q;

    always_ff @(posedge clk_i) begin
      if (rst_i) inject_q <= '0;
      else       inject_q <= (io_we && (dmem_addr[4:2] == IO_TMR)) ? dmem_wdata : '0;
    end

    riscv_core_tmr #(.MEM_WAIT(1'b1)) u_core (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .imem_addr_o         (imem_addr),
        .imem_rdata_i        (imem_rdata),
        .dmem_addr_o         (dmem_addr),
        .dmem_wdata_o        (dmem_wdata),
        .dmem_wstrb_o        (dmem_wstrb),
        .dmem_we_o           (dmem_we),
        .dmem_re_o           (dmem_re),
        .dmem_rdata_i        (dmem_rdata),
        .dmem_ready_i        (dmem_ready),
        .wb_rd_we_o          (dbg_wb_rd_we_o),
        .wb_rd_addr_o        (dbg_wb_rd_addr_o),
        .wb_rd_wdata_o       (dbg_wb_rd_wdata_o),
        .halt_o              (dbg_halt_o),
        .mismatch_o          (),
        .disagree_o          (),
        .mismatch_count_o    (tmr_mismatches),
        .inject_pc_i         (inject_q),
  `ifdef RISCV_FORMAL
        .rvfi_valid_o        (),
        .rvfi_order_o        (),
        .rvfi_insn_o         (),
        .rvfi_trap_o         (),
        .rvfi_halt_o         (),
        .rvfi_intr_o         (),
        .rvfi_rs1_addr_o     (),
        .rvfi_rs2_addr_o     (),
        .rvfi_rs1_rdata_o    (),
        .rvfi_rs2_rdata_o    (),
        .rvfi_rd_addr_o      (),
        .rvfi_rd_wdata_o     (),
        .rvfi_pc_rdata_o     (),
        .rvfi_pc_wdata_o     (),
        .rvfi_mem_addr_o     (),
        .rvfi_mem_rmask_o    (),
        .rvfi_mem_wmask_o    (),
        .rvfi_mem_rdata_o    (),
        .rvfi_mem_wdata_o    (),
  `endif
        .if_id_pc_o          (dbg_if_id_pc_o),
        .if_id_instr_o       (dbg_if_id_instr_o),
        .id_ex_pc_o          (dbg_id_ex_pc_o),
        .id_ex_instr_o       (dbg_id_ex_instr_o),
        .id_ex_rs1_addr_o    (),
        .id_ex_rs2_addr_o    (),
        .id_ex_rs1_rdata_o   (),
        .id_ex_rs2_rdata_o   (),
        .id_ex_imm_o         (),
        .id_ex_rd_addr_o     (),
        .ex_mem_pc_o         (dbg_ex_mem_pc_o),
        .ex_mem_instr_o      (dbg_ex_mem_instr_o),
        .ex_mem_alu_result_o (dbg_ex_mem_alu_result_o),
        .ex_mem_rd_addr_o    (),
        .ex_mem_rd_we_o      (),
        .mem_wb_pc_o         (dbg_mem_wb_pc_o),
        .mem_wb_instr_o      (dbg_mem_wb_instr_o)
    );
  end else begin : g_cpu
    riscv_core #(.MEM_WAIT(1'b1)) u_core (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
  `ifdef FORMAL
        .f_regs_o            (),
  `endif
        .imem_addr_o         (imem_addr),
        .imem_rdata_i        (imem_rdata),
        .dmem_addr_o         (dmem_addr),
        .dmem_wdata_o        (dmem_wdata),
        .dmem_wstrb_o        (dmem_wstrb),
        .dmem_we_o           (dmem_we),
        .dmem_re_o           (dmem_re),
        .dmem_rdata_i        (dmem_rdata),
        .dmem_ready_i        (dmem_ready),
        .wb_rd_we_o          (dbg_wb_rd_we_o),
        .wb_rd_addr_o        (dbg_wb_rd_addr_o),
        .wb_rd_wdata_o       (dbg_wb_rd_wdata_o),
        .halt_o              (dbg_halt_o),
        // Not voted: VOTED = 0, so the vote inputs are ignored.
        .halt_next_o         (),
        .vote_pc_i           ('0),
        .vote_halt_i         ('0),
        .vote_rd_we_i        (1'b0),
        .vote_rd_addr_i      ('0),
        .vote_rd_wdata_i     ('0),
  `ifdef RISCV_FORMAL
        .rvfi_valid_o        (),
        .rvfi_order_o        (),
        .rvfi_insn_o         (),
        .rvfi_trap_o         (),
        .rvfi_halt_o         (),
        .rvfi_intr_o         (),
        .rvfi_rs1_addr_o     (),
        .rvfi_rs2_addr_o     (),
        .rvfi_rs1_rdata_o    (),
        .rvfi_rs2_rdata_o    (),
        .rvfi_rd_addr_o      (),
        .rvfi_rd_wdata_o     (),
        .rvfi_pc_rdata_o     (),
        .rvfi_pc_wdata_o     (),
        .rvfi_mem_addr_o     (),
        .rvfi_mem_rmask_o    (),
        .rvfi_mem_wmask_o    (),
        .rvfi_mem_rdata_o    (),
        .rvfi_mem_wdata_o    (),
  `endif
        .if_id_pc_o          (dbg_if_id_pc_o),
        .if_id_instr_o       (dbg_if_id_instr_o),
        .id_ex_pc_o          (dbg_id_ex_pc_o),
        .id_ex_instr_o       (dbg_id_ex_instr_o),
        .id_ex_rs1_addr_o    (),
        .id_ex_rs2_addr_o    (),
        .id_ex_rs1_rdata_o   (),
        .id_ex_rs2_rdata_o   (),
        .id_ex_imm_o         (),
        .id_ex_rd_addr_o     (),
        .ex_mem_pc_o         (dbg_ex_mem_pc_o),
        .ex_mem_instr_o      (dbg_ex_mem_instr_o),
        .ex_mem_alu_result_o (dbg_ex_mem_alu_result_o),
        .ex_mem_rd_addr_o    (),
        .ex_mem_rd_we_o      (),
        .mem_wb_pc_o         (dbg_mem_wb_pc_o),
        .mem_wb_instr_o      (dbg_mem_wb_instr_o)
    );
    assign tmr_mismatches = '0;
  end
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- decode ----
  // Partial decode, so the bits between the region nibble and the RAM index
  // are ignored (regions alias), as are the byte offsets, which the strobes
  // carry. Named unused_* so lint knows it is deliberate.
  logic unused_addr_bits;
  assign unused_addr_bits = ^{imem_addr[31:RAM_AW+2], imem_addr[1:0],
                              dmem_addr[27:RAM_AW+2], dmem_addr[1:0]};

  logic io_sel, ram_sel, axi_sel;
  assign io_sel  = (dmem_addr[31:28] == REGION_IO);
  assign ram_sel = (dmem_addr[31:28] == REGION_RAM);
  assign axi_sel = (dmem_addr[31:28] == REGION_AXI);

  // ---- AXI region: the core's bridge, the crossbar, the DMA engine ----
  logic        axi_req, bus_err;
  logic [31:0] axi_rdata;
  assign axi_req = axi_sel && (dmem_re || dmem_we);

  logic [31:0] lite_awaddr, lite_araddr, lite_wdata, lite_rdata;
  logic [3:0]  lite_wstrb;
  logic [1:0]  lite_bresp, lite_rresp;
  logic        lite_awvalid, lite_awready, lite_wvalid, lite_wready;
  logic        lite_bvalid, lite_bready, lite_arvalid, lite_arready;
  logic        lite_rvalid, lite_rready;

  core_axil_bridge u_bridge (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .req_i       (axi_req),
      .we_i        (dmem_we),
      .addr_i      (dmem_addr),
      .wdata_i     (dmem_wdata),
      .wstrb_i     (dmem_wstrb),
      .ready_o     (dmem_ready),
      .rdata_o     (axi_rdata),
      .err_o       (bus_err),
      .err_clr_i   (io_we && (dmem_addr[4:2] == IO_BUSERR)),
      .m_awaddr_o  (lite_awaddr),
      .m_awvalid_o (lite_awvalid),
      .m_awready_i (lite_awready),
      .m_wdata_o   (lite_wdata),
      .m_wstrb_o   (lite_wstrb),
      .m_wvalid_o  (lite_wvalid),
      .m_wready_i  (lite_wready),
      .m_bresp_i   (lite_bresp),
      .m_bvalid_i  (lite_bvalid),
      .m_bready_o  (lite_bready),
      .m_araddr_o  (lite_araddr),
      .m_arvalid_o (lite_arvalid),
      .m_arready_i (lite_arready),
      .m_rdata_i   (lite_rdata),
      .m_rresp_i   (lite_rresp),
      .m_rvalid_i  (lite_rvalid),
      .m_rready_o  (lite_rready)
  );

  logic [31:0] dma_araddr, dma_awaddr, dma_rdata, dma_wdata;
  logic [7:0]  dma_arlen, dma_awlen;
  logic [2:0]  dma_arsize, dma_awsize;
  logic [1:0]  dma_arburst, dma_awburst, dma_rresp, dma_bresp;
  logic [3:0]  dma_wstrb;
  logic        dma_arvalid, dma_arready, dma_rlast, dma_rvalid, dma_rready;
  logic        dma_awvalid, dma_awready, dma_wlast, dma_wvalid, dma_wready;
  logic        dma_bvalid, dma_bready, dma_irq;

  // ---- the AXI4 interconnect ----
  // masters: 0 the core's bridge (single beats), 1 the DMA engine
  // slaves:  0 the RAM, through port B (0x0xxx_xxxx, aliasing as above)
  //          1 the DMA's registers (0x2000_0000-0x2000_0FFF), AXI4-Lite
  //            behind axi_to_axil
  //          2 the accelerator's registers (0x2000_1000-0x2000_1FFF), likewise
  //          3 the accelerator's buffers (0x2010_0000, four ACC_BUF slots)
  // anything else in the AXI region answers DECERR, and BUSERR shows it
  localparam logic [127:0] XBAR_BASE = {32'h2010_0000, 32'h2000_1000,
                                        32'h2000_0000, 32'h0000_0000};
  localparam logic [127:0] XBAR_MASK = {~(32'(4 * ACC_BUF) - 32'd1), 32'hFFFF_F000,
                                        32'hFFFF_F000, 32'hF000_0000};

  logic [1:0]        xm_arready, xm_awready, xm_wready, xm_rvalid, xm_rlast, xm_bvalid;
  logic [1:0][31:0]  xm_rdata;
  logic [1:0][1:0]   xm_rresp, xm_bresp;

  logic [31:0] xram_araddr, xram_awaddr, xram_wdata, xram_rdata;
  logic [7:0]  xram_arlen, xram_awlen;
  logic [2:0]  xram_arsize, xram_awsize;
  logic [1:0]  xram_arburst, xram_awburst, xram_rresp, xram_bresp;
  logic [3:0]  xram_wstrb;
  logic        xram_arvalid, xram_arready, xram_rlast, xram_rvalid, xram_rready;
  logic        xram_awvalid, xram_awready, xram_wlast, xram_wvalid, xram_wready;
  logic        xram_bvalid, xram_bready;

  logic [31:0] xreg_araddr, xreg_awaddr, xreg_wdata, xreg_rdata;
  logic [7:0]  xreg_arlen, xreg_awlen;
  logic [2:0]  xreg_arsize, xreg_awsize;
  logic [1:0]  xreg_arburst, xreg_awburst, xreg_rresp, xreg_bresp;
  logic [3:0]  xreg_wstrb;
  logic        xreg_arvalid, xreg_arready, xreg_rlast, xreg_rvalid, xreg_rready;
  logic        xreg_awvalid, xreg_awready, xreg_wlast, xreg_wvalid, xreg_wready;
  logic        xreg_bvalid, xreg_bready;

  logic [31:0] xacc_araddr, xacc_awaddr, xacc_wdata, xacc_rdata;
  logic [7:0]  xacc_arlen, xacc_awlen;
  logic [2:0]  xacc_arsize, xacc_awsize;
  logic [1:0]  xacc_arburst, xacc_awburst, xacc_rresp, xacc_bresp;
  logic [3:0]  xacc_wstrb;
  logic        xacc_arvalid, xacc_arready, xacc_rlast, xacc_rvalid, xacc_rready;
  logic        xacc_awvalid, xacc_awready, xacc_wlast, xacc_wvalid, xacc_wready;
  logic        xacc_bvalid, xacc_bready;

  logic [31:0] xbuf_araddr, xbuf_awaddr, xbuf_wdata, xbuf_rdata;
  logic [7:0]  xbuf_arlen, xbuf_awlen;
  logic [2:0]  xbuf_arsize, xbuf_awsize;
  logic [1:0]  xbuf_arburst, xbuf_awburst, xbuf_rresp, xbuf_bresp;
  logic [3:0]  xbuf_wstrb;
  logic        xbuf_arvalid, xbuf_arready, xbuf_rlast, xbuf_rvalid, xbuf_rready;
  logic        xbuf_awvalid, xbuf_awready, xbuf_wlast, xbuf_wvalid, xbuf_wready;
  logic        xbuf_bvalid, xbuf_bready;

  // its formal-only ports serve tb/formal/axi_xbar_formal.sv, not this top
  /* verilator lint_off PINCONNECTEMPTY */
  axi_xbar #(
      .N      (2),
      .M      (4),
      .S_BASE (XBAR_BASE),
      .S_MASK (XBAR_MASK)
  ) u_xbar (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
`ifdef FORMAL
      .f_rb_o      (),
      .f_wb_o      (),
      .f_wl_o      (),
`endif
      // the bridge is AXI4-Lite: single full-width INCR beats, WLAST high
      .m_araddr_i  ({dma_araddr,  lite_araddr}),
      .m_arlen_i   ({dma_arlen,   8'd0}),
      .m_arsize_i  ({dma_arsize,  3'd2}),
      .m_arburst_i ({dma_arburst, 2'b01}),
      .m_arvalid_i ({dma_arvalid, lite_arvalid}),
      .m_arready_o (xm_arready),
      .m_rdata_o   (xm_rdata),
      .m_rresp_o   (xm_rresp),
      .m_rlast_o   (xm_rlast),
      .m_rvalid_o  (xm_rvalid),
      .m_rready_i  ({dma_rready,  lite_rready}),
      .m_awaddr_i  ({dma_awaddr,  lite_awaddr}),
      .m_awlen_i   ({dma_awlen,   8'd0}),
      .m_awsize_i  ({dma_awsize,  3'd2}),
      .m_awburst_i ({dma_awburst, 2'b01}),
      .m_awvalid_i ({dma_awvalid, lite_awvalid}),
      .m_awready_o (xm_awready),
      .m_wdata_i   ({dma_wdata,   lite_wdata}),
      .m_wstrb_i   ({dma_wstrb,   lite_wstrb}),
      .m_wlast_i   ({dma_wlast,   1'b1}),
      .m_wvalid_i  ({dma_wvalid,  lite_wvalid}),
      .m_wready_o  (xm_wready),
      .m_bresp_o   (xm_bresp),
      .m_bvalid_o  (xm_bvalid),
      .m_bready_i  ({dma_bready,  lite_bready}),
      .s_araddr_o  ({xbuf_araddr, xacc_araddr, xreg_araddr,  xram_araddr}),
      .s_arlen_o   ({xbuf_arlen, xacc_arlen, xreg_arlen,   xram_arlen}),
      .s_arsize_o  ({xbuf_arsize, xacc_arsize, xreg_arsize,  xram_arsize}),
      .s_arburst_o ({xbuf_arburst, xacc_arburst, xreg_arburst, xram_arburst}),
      .s_arvalid_o ({xbuf_arvalid, xacc_arvalid, xreg_arvalid, xram_arvalid}),
      .s_arready_i ({xbuf_arready, xacc_arready, xreg_arready, xram_arready}),
      .s_rdata_i   ({xbuf_rdata, xacc_rdata, xreg_rdata,   xram_rdata}),
      .s_rresp_i   ({xbuf_rresp, xacc_rresp, xreg_rresp,   xram_rresp}),
      .s_rlast_i   ({xbuf_rlast, xacc_rlast, xreg_rlast,   xram_rlast}),
      .s_rvalid_i  ({xbuf_rvalid, xacc_rvalid, xreg_rvalid,  xram_rvalid}),
      .s_rready_o  ({xbuf_rready, xacc_rready, xreg_rready,  xram_rready}),
      .s_awaddr_o  ({xbuf_awaddr, xacc_awaddr, xreg_awaddr,  xram_awaddr}),
      .s_awlen_o   ({xbuf_awlen, xacc_awlen, xreg_awlen,   xram_awlen}),
      .s_awsize_o  ({xbuf_awsize, xacc_awsize, xreg_awsize,  xram_awsize}),
      .s_awburst_o ({xbuf_awburst, xacc_awburst, xreg_awburst, xram_awburst}),
      .s_awvalid_o ({xbuf_awvalid, xacc_awvalid, xreg_awvalid, xram_awvalid}),
      .s_awready_i ({xbuf_awready, xacc_awready, xreg_awready, xram_awready}),
      .s_wdata_o   ({xbuf_wdata, xacc_wdata, xreg_wdata,   xram_wdata}),
      .s_wstrb_o   ({xbuf_wstrb, xacc_wstrb, xreg_wstrb,   xram_wstrb}),
      .s_wlast_o   ({xbuf_wlast, xacc_wlast, xreg_wlast,   xram_wlast}),
      .s_wvalid_o  ({xbuf_wvalid, xacc_wvalid, xreg_wvalid,  xram_wvalid}),
      .s_wready_i  ({xbuf_wready, xacc_wready, xreg_wready,  xram_wready}),
      .s_bresp_i   ({xbuf_bresp, xacc_bresp, xreg_bresp,   xram_bresp}),
      .s_bvalid_i  ({xbuf_bvalid, xacc_bvalid, xreg_bvalid,  xram_bvalid}),
      .s_bready_o  ({xbuf_bready, xacc_bready, xreg_bready,  xram_bready})
  );
  /* verilator lint_on PINCONNECTEMPTY */

  assign lite_arready = xm_arready[0];
  assign lite_awready = xm_awready[0];
  assign lite_wready  = xm_wready[0];
  assign lite_rvalid  = xm_rvalid[0];
  assign lite_rdata   = xm_rdata[0];
  assign lite_rresp   = xm_rresp[0];
  assign lite_bvalid  = xm_bvalid[0];
  assign lite_bresp   = xm_bresp[0];
  assign dma_arready  = xm_arready[1];
  assign dma_awready  = xm_awready[1];
  assign dma_wready   = xm_wready[1];
  assign dma_rvalid   = xm_rvalid[1];
  assign dma_rdata    = xm_rdata[1];
  assign dma_rresp    = xm_rresp[1];
  assign dma_rlast    = xm_rlast[1];
  assign dma_bvalid   = xm_bvalid[1];
  assign dma_bresp    = xm_bresp[1];

  // slave 1: the DMA's AXI4-Lite registers
  logic [31:0] reg_awaddr, reg_araddr, reg_wdata, reg_rdata;
  logic [3:0]  reg_wstrb;
  logic [1:0]  reg_bresp, reg_rresp;
  logic        reg_awvalid, reg_awready, reg_wvalid, reg_wready;
  logic        reg_bvalid, reg_bready, reg_arvalid, reg_arready;
  logic        reg_rvalid, reg_rready;

  axi_to_axil u_reg_conv (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .s_araddr_i  (xreg_araddr),
      .s_arlen_i   (xreg_arlen),
      .s_arsize_i  (xreg_arsize),
      .s_arburst_i (xreg_arburst),
      .s_arvalid_i (xreg_arvalid),
      .s_arready_o (xreg_arready),
      .s_rdata_o   (xreg_rdata),
      .s_rresp_o   (xreg_rresp),
      .s_rlast_o   (xreg_rlast),
      .s_rvalid_o  (xreg_rvalid),
      .s_rready_i  (xreg_rready),
      .s_awaddr_i  (xreg_awaddr),
      .s_awlen_i   (xreg_awlen),
      .s_awsize_i  (xreg_awsize),
      .s_awburst_i (xreg_awburst),
      .s_awvalid_i (xreg_awvalid),
      .s_awready_o (xreg_awready),
      .s_wdata_i   (xreg_wdata),
      .s_wstrb_i   (xreg_wstrb),
      .s_wlast_i   (xreg_wlast),
      .s_wvalid_i  (xreg_wvalid),
      .s_wready_o  (xreg_wready),
      .s_bresp_o   (xreg_bresp),
      .s_bvalid_o  (xreg_bvalid),
      .s_bready_i  (xreg_bready),
      .m_awaddr_o  (reg_awaddr),
      .m_awvalid_o (reg_awvalid),
      .m_awready_i (reg_awready),
      .m_wdata_o   (reg_wdata),
      .m_wstrb_o   (reg_wstrb),
      .m_wvalid_o  (reg_wvalid),
      .m_wready_i  (reg_wready),
      .m_bresp_i   (reg_bresp),
      .m_bvalid_i  (reg_bvalid),
      .m_bready_o  (reg_bready),
      .m_araddr_o  (reg_araddr),
      .m_arvalid_o (reg_arvalid),
      .m_arready_i (reg_arready),
      .m_rdata_i   (reg_rdata),
      .m_rresp_i   (reg_rresp),
      .m_rvalid_i  (reg_rvalid),
      .m_rready_o  (reg_rready)
  );

  dmaeng u_dma (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .s_awaddr_i  (reg_awaddr[DMA_OFF_W-1:0]),
      .s_awvalid_i (reg_awvalid),
      .s_awready_o (reg_awready),
      .s_wdata_i   (reg_wdata),
      .s_wstrb_i   (reg_wstrb),
      .s_wvalid_i  (reg_wvalid),
      .s_wready_o  (reg_wready),
      .s_bresp_o   (reg_bresp),
      .s_bvalid_o  (reg_bvalid),
      .s_bready_i  (reg_bready),
      .s_araddr_i  (reg_araddr[DMA_OFF_W-1:0]),
      .s_arvalid_i (reg_arvalid),
      .s_arready_o (reg_arready),
      .s_rdata_o   (reg_rdata),
      .s_rresp_o   (reg_rresp),
      .s_rvalid_o  (reg_rvalid),
      .s_rready_i  (reg_rready),
      .m_araddr_o  (dma_araddr),
      .m_arlen_o   (dma_arlen),
      .m_arsize_o  (dma_arsize),
      .m_arburst_o (dma_arburst),
      .m_arvalid_o (dma_arvalid),
      .m_arready_i (dma_arready),
      .m_rdata_i   (dma_rdata),
      .m_rresp_i   (dma_rresp),
      .m_rlast_i   (dma_rlast),
      .m_rvalid_i  (dma_rvalid),
      .m_rready_o  (dma_rready),
      .m_awaddr_o  (dma_awaddr),
      .m_awlen_o   (dma_awlen),
      .m_awsize_o  (dma_awsize),
      .m_awburst_o (dma_awburst),
      .m_awvalid_o (dma_awvalid),
      .m_awready_i (dma_awready),
      .m_wdata_o   (dma_wdata),
      .m_wstrb_o   (dma_wstrb),
      .m_wlast_o   (dma_wlast),
      .m_wvalid_o  (dma_wvalid),
      .m_wready_i  (dma_wready),
      .m_bresp_i   (dma_bresp),
      .m_bvalid_i  (dma_bvalid),
      .m_bready_o  (dma_bready),
      .irq_o       (dma_irq)
  );

  // The register window is the address's [11:0] (the crossbar decoded the
  // rest); the bridge's single beats need no RLAST. The interrupt is unused:
  // the core has none.
  logic unused_axi;
  assign unused_axi = ^{reg_awaddr[31:DMA_OFF_W], reg_araddr[31:DMA_OFF_W], dma_irq,
                        xm_rlast[0]};

  // slaves 2 and 3: the GEMM accelerator, registers (AXI4-Lite, behind its
  // own converter) and buffers (AXI4)
  logic [31:0] acc_awaddr, acc_araddr, acc_wdata, acc_rdata;
  logic [3:0]  acc_wstrb;
  logic [1:0]  acc_bresp, acc_rresp;
  logic        acc_awvalid, acc_awready, acc_wvalid, acc_wready;
  logic        acc_bvalid, acc_bready, acc_arvalid, acc_arready;
  logic        acc_rvalid, acc_rready;

  axi_to_axil u_acc_conv (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .s_araddr_i  (xacc_araddr),
      .s_arlen_i   (xacc_arlen),
      .s_arsize_i  (xacc_arsize),
      .s_arburst_i (xacc_arburst),
      .s_arvalid_i (xacc_arvalid),
      .s_arready_o (xacc_arready),
      .s_rdata_o   (xacc_rdata),
      .s_rresp_o   (xacc_rresp),
      .s_rlast_o   (xacc_rlast),
      .s_rvalid_o  (xacc_rvalid),
      .s_rready_i  (xacc_rready),
      .s_awaddr_i  (xacc_awaddr),
      .s_awlen_i   (xacc_awlen),
      .s_awsize_i  (xacc_awsize),
      .s_awburst_i (xacc_awburst),
      .s_awvalid_i (xacc_awvalid),
      .s_awready_o (xacc_awready),
      .s_wdata_i   (xacc_wdata),
      .s_wstrb_i   (xacc_wstrb),
      .s_wlast_i   (xacc_wlast),
      .s_wvalid_i  (xacc_wvalid),
      .s_wready_o  (xacc_wready),
      .s_bresp_o   (xacc_bresp),
      .s_bvalid_o  (xacc_bvalid),
      .s_bready_i  (xacc_bready),
      .m_awaddr_o  (acc_awaddr),
      .m_awvalid_o (acc_awvalid),
      .m_awready_i (acc_awready),
      .m_wdata_o   (acc_wdata),
      .m_wstrb_o   (acc_wstrb),
      .m_wvalid_o  (acc_wvalid),
      .m_wready_i  (acc_wready),
      .m_bresp_i   (acc_bresp),
      .m_bvalid_i  (acc_bvalid),
      .m_bready_o  (acc_bready),
      .m_araddr_o  (acc_araddr),
      .m_arvalid_o (acc_arvalid),
      .m_arready_i (acc_arready),
      .m_rdata_i   (acc_rdata),
      .m_rresp_i   (acc_rresp),
      .m_rvalid_i  (acc_rvalid),
      .m_rready_o  (acc_rready)
  );

  gemm_accel #(
      .ROWS      (16),
      .COLS      (16),
      .BUF_BYTES (ACC_BUF),
      .OFF_W     (ACC_OFF_W)
  ) u_accel (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .s_awaddr_i  (acc_awaddr[ACC_OFF_W-1:0]),
      .s_awvalid_i (acc_awvalid),
      .s_awready_o (acc_awready),
      .s_wdata_i   (acc_wdata),
      .s_wstrb_i   (acc_wstrb),
      .s_wvalid_i  (acc_wvalid),
      .s_wready_o  (acc_wready),
      .s_bresp_o   (acc_bresp),
      .s_bvalid_o  (acc_bvalid),
      .s_bready_i  (acc_bready),
      .s_araddr_i  (acc_araddr[ACC_OFF_W-1:0]),
      .s_arvalid_i (acc_arvalid),
      .s_arready_o (acc_arready),
      .s_rdata_o   (acc_rdata),
      .s_rresp_o   (acc_rresp),
      .s_rvalid_o  (acc_rvalid),
      .s_rready_i  (acc_rready),
      .d_araddr_i  (xbuf_araddr),
      .d_arlen_i   (xbuf_arlen),
      .d_arsize_i  (xbuf_arsize),
      .d_arburst_i (xbuf_arburst),
      .d_arvalid_i (xbuf_arvalid),
      .d_arready_o (xbuf_arready),
      .d_rdata_o   (xbuf_rdata),
      .d_rresp_o   (xbuf_rresp),
      .d_rlast_o   (xbuf_rlast),
      .d_rvalid_o  (xbuf_rvalid),
      .d_rready_i  (xbuf_rready),
      .d_awaddr_i  (xbuf_awaddr),
      .d_awlen_i   (xbuf_awlen),
      .d_awsize_i  (xbuf_awsize),
      .d_awburst_i (xbuf_awburst),
      .d_awvalid_i (xbuf_awvalid),
      .d_awready_o (xbuf_awready),
      .d_wdata_i   (xbuf_wdata),
      .d_wstrb_i   (xbuf_wstrb),
      .d_wlast_i   (xbuf_wlast),
      .d_wvalid_i  (xbuf_wvalid),
      .d_wready_o  (xbuf_wready),
      .d_bresp_o   (xbuf_bresp),
      .d_bvalid_o  (xbuf_bvalid),
      .d_bready_i  (xbuf_bready)
  );

  logic unused_acc;
  assign unused_acc = ^{acc_awaddr[31:ACC_OFF_W], acc_araddr[31:ACC_OFF_W]};

  // the DMA's way into RAM: port B when the core leaves it free
  logic              core_port_busy, dma_ram_en;
  logic [RAM_AW-1:0] dma_ram_addr;
  logic [3:0]        dma_ram_we;
  logic [31:0]       dma_ram_wdata;
  assign core_port_busy = dmem_re || dmem_we;

  // ---- RAM ----
  logic [31:0] ram_rdata;

  ram_dp #(
      .WORDS     (RAM_WORDS),
      .INIT_FILE (INIT_FILE)
  ) u_ram (
      .clk_i     (clk_i),
      .a_addr_i  (imem_addr[RAM_AW+1:2]),
      .a_rdata_o (imem_rdata),
      // The DMA's port only in a cycle it uses it (dma_ram_en already means
      // the core does not): selecting on core_port_busy instead put the
      // TMR core's voted dmem_we on ~50 mux selects and cost the TMR board
      // its 100 MHz (WNS -0.047 ns on the I/O write path; +0.073 this way).
      .b_addr_i  (dma_ram_en ? dma_ram_addr  : dmem_addr[RAM_AW+1:2]),
      .b_we_i    ((dmem_wstrb & {4{dmem_we && ram_sel}}) | dma_ram_we),
      .b_wdata_i (dma_ram_en ? dma_ram_wdata : dmem_wdata),
      .b_rdata_o (ram_rdata)
  );

  axi_ram_port #(
      .WORDS (RAM_WORDS)
  ) u_dma_port (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .s_araddr_i  (xram_araddr),
      .s_arlen_i   (xram_arlen),
      .s_arsize_i  (xram_arsize),
      .s_arburst_i (xram_arburst),
      .s_arvalid_i (xram_arvalid),
      .s_arready_o (xram_arready),
      .s_rdata_o   (xram_rdata),
      .s_rresp_o   (xram_rresp),
      .s_rlast_o   (xram_rlast),
      .s_rvalid_o  (xram_rvalid),
      .s_rready_i  (xram_rready),
      .s_awaddr_i  (xram_awaddr),
      .s_awlen_i   (xram_awlen),
      .s_awsize_i  (xram_awsize),
      .s_awburst_i (xram_awburst),
      .s_awvalid_i (xram_awvalid),
      .s_awready_o (xram_awready),
      .s_wdata_i   (xram_wdata),
      .s_wstrb_i   (xram_wstrb),
      .s_wlast_i   (xram_wlast),
      .s_wvalid_i  (xram_wvalid),
      .s_wready_o  (xram_wready),
      .s_bresp_o   (xram_bresp),
      .s_bvalid_o  (xram_bvalid),
      .s_bready_i  (xram_bready),
      .core_busy_i (core_port_busy),
      .ram_en_o    (dma_ram_en),
      .ram_addr_o  (dma_ram_addr),
      .ram_we_o    (dma_ram_we),
      .ram_wdata_o (dma_ram_wdata),
      .ram_rdata_i (ram_rdata)
  );


  // ---- I/O writes ----
  logic uart_ready;
  assign io_we = dmem_we && io_sel && dmem_wstrb[0];

  always_ff @(posedge clk_i) begin
    if (rst_i)                                   led_o <= '0;
    else if (io_we && (dmem_addr[4:2] == IO_LED)) led_o <= dmem_wdata[3:0];
  end

  uart_tx #(
      .CLK_HZ (CLK_HZ),
      .BAUD   (BAUD)
  ) u_uart_tx (
      .clk_i   (clk_i),
      .rst_i   (rst_i),
      .data_i  (dmem_wdata[7:0]),
      .valid_i (io_we && (dmem_addr[4:2] == IO_UART_TX)),
      .ready_o (uart_ready),
      .tx_o    (uart_tx_o)
  );

  logic [7:0] rx_data;
  logic       rx_valid, rx_overrun, rx_frame_err;

  uart_rx #(
      .CLK_HZ (CLK_HZ),
      .BAUD   (BAUD)
  ) u_uart_rx (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .rx_i        (uart_rx_i),
      .data_o      (rx_data),
      .valid_o     (rx_valid),
      .overrun_o   (rx_overrun),
      .frame_err_o (rx_frame_err),
      .ack_i       (io_we && (dmem_addr[4:2] == IO_UART_RX))
  );

  // ---- cycle counter ----
  logic [31:0] cycle_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) cycle_q <= '0;
    else       cycle_q <= cycle_q + 32'd1;
  end

  // ---- I/O reads: registered, to arrive in WB like a block RAM's data ----
  // The selects follow the access the core takes into MEM, so they move only
  // at an edge where the core advances (dmem_ready): while an AXI access
  // holds it in MEM, EX's address is the next instruction's.
  logic        io_rsel_q, axi_rsel_q;
  logic [31:0] io_rdata_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      io_rsel_q  <= 1'b0;
      axi_rsel_q <= 1'b0;
      io_rdata_q <= '0;
    end else if (dmem_ready) begin
      io_rsel_q  <= io_sel;
      axi_rsel_q <= axi_sel;
      case (dmem_addr[4:2])
        IO_LED:     io_rdata_q <= {28'b0, led_o};
        IO_UART_ST: io_rdata_q <= {28'b0, rx_frame_err, rx_overrun, rx_valid, uart_ready};
        IO_UART_RX: io_rdata_q <= {24'b0, rx_data};
        IO_CYCLE:   io_rdata_q <= cycle_q;
        IO_TMR:     io_rdata_q <= tmr_mismatches;
        IO_BUSERR:  io_rdata_q <= {31'b0, bus_err};
        default:    io_rdata_q <= '0;
      endcase
    end
  end

  assign dmem_rdata = axi_rsel_q ? axi_rdata : io_rsel_q ? io_rdata_q : ram_rdata;

endmodule
