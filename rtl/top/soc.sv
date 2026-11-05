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
//                            map, rtl/bus/dmaeng.sv). Loads and stores here
//                            hold the core until the bus answers
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
  // anything else in the AXI region answers DECERR, and BUSERR shows it
  localparam logic [63:0] XBAR_BASE = {32'h2000_0000, 32'h0000_0000};
  localparam logic [63:0] XBAR_MASK = {32'hFFFF_F000, 32'hF000_0000};

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

  // its formal-only ports serve tb/formal/axi_xbar_formal.sv, not this top
  /* verilator lint_off PINCONNECTEMPTY */
  axi_xbar #(
      .N      (2),
      .M      (2),
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
      .s_araddr_o  ({xreg_araddr,  xram_araddr}),
      .s_arlen_o   ({xreg_arlen,   xram_arlen}),
      .s_arsize_o  ({xreg_arsize,  xram_arsize}),
      .s_arburst_o ({xreg_arburst, xram_arburst}),
      .s_arvalid_o ({xreg_arvalid, xram_arvalid}),
      .s_arready_i ({xreg_arready, xram_arready}),
      .s_rdata_i   ({xreg_rdata,   xram_rdata}),
      .s_rresp_i   ({xreg_rresp,   xram_rresp}),
      .s_rlast_i   ({xreg_rlast,   xram_rlast}),
      .s_rvalid_i  ({xreg_rvalid,  xram_rvalid}),
      .s_rready_o  ({xreg_rready,  xram_rready}),
      .s_awaddr_o  ({xreg_awaddr,  xram_awaddr}),
      .s_awlen_o   ({xreg_awlen,   xram_awlen}),
      .s_awsize_o  ({xreg_awsize,  xram_awsize}),
      .s_awburst_o ({xreg_awburst, xram_awburst}),
      .s_awvalid_o ({xreg_awvalid, xram_awvalid}),
      .s_awready_i ({xreg_awready, xram_awready}),
      .s_wdata_o   ({xreg_wdata,   xram_wdata}),
      .s_wstrb_o   ({xreg_wstrb,   xram_wstrb}),
      .s_wlast_o   ({xreg_wlast,   xram_wlast}),
      .s_wvalid_o  ({xreg_wvalid,  xram_wvalid}),
      .s_wready_i  ({xreg_wready,  xram_wready}),
      .s_bresp_i   ({xreg_bresp,   xram_bresp}),
      .s_bvalid_i  ({xreg_bvalid,  xram_bvalid}),
      .s_bready_o  ({xreg_bready,  xram_bready})
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
