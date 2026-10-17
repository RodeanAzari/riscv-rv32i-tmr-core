// First-light SoC: the core, one dual-port RAM, four LEDs, a UART
// transmitter and a cycle counter. Board-independent -- clock and reset arrive ready to use --
// so cocotb can run it whole with the real program; arty_a7_top.sv adds the
// clocking and the pins.
//
// Memory map (decoded on address bits [31:28] and [4:2] only, so each region
// aliases through its window):
//
//   0x0000_0000  RAM, RAM_WORDS x 32 bits, code and data (ram_dp.sv)
//   0x1000_0000  LED      W: bits [3:0] drive the LEDs    R: their value
//   0x1000_0004  UART TX  W: bits [7:0] are sent           R: 0
//   0x1000_0008  UART ST  R: bit 0 = ready for a byte      W: ignored
//   0x1000_0010  CYCLE    R: cycles since reset, mod 2^32     W: ignored
//
// The cycle counter is how software times itself (the core has no CSRs, so
// rdcycle is an illegal instruction). 32 bits wrap after 85 s at 50 MHz;
// the difference of two reads is exact for any interval shorter than that.
//
// A byte written to UART TX while it is not ready is dropped: software polls
// UART ST first. Byte stores (sb) work on every register: the core puts a
// byte in every lane and raises its strobe, and the registers read lane 0.
//
// The core's data port is BRAM-timed: the address is taken at the end of MEM
// and the load data is expected during WB. The I/O read path matches it with
// one register, so a load from I/O lands exactly like a load from RAM.
module soc #(
    parameter int unsigned CLK_HZ    = 50_000_000,
    parameter int unsigned BAUD      = 115_200,
    parameter int unsigned RAM_WORDS = 8192,
    parameter string       INIT_FILE = ""
) (
    input  logic       clk_i,
    input  logic       rst_i,
    output logic [3:0] led_o,
    output logic       uart_tx_o,

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
  localparam logic [2:0] IO_CYCLE   = 3'd4;

  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_we;

  // The core's remaining debug outputs (operand values, RVFI) are left open
  // on purpose: not needed by this top. Waived here only.
  /* verilator lint_off PINCONNECTEMPTY */
  riscv_core u_core (
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
      .dmem_rdata_i        (dmem_rdata),
      .wb_rd_we_o          (dbg_wb_rd_we_o),
      .wb_rd_addr_o        (dbg_wb_rd_addr_o),
      .wb_rd_wdata_o       (dbg_wb_rd_wdata_o),
      .halt_o              (dbg_halt_o),
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
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- decode ----
  // Partial decode, so the bits between the region nibble and the RAM index
  // are ignored (regions alias), as are the byte offsets, which the strobes
  // carry. Named unused_* so lint knows it is deliberate.
  logic unused_addr_bits;
  assign unused_addr_bits = ^{imem_addr[31:RAM_AW+2], imem_addr[1:0],
                              dmem_addr[27:RAM_AW+2], dmem_addr[1:0]};

  logic io_sel, ram_sel;
  assign io_sel  = (dmem_addr[31:28] == REGION_IO);
  assign ram_sel = (dmem_addr[31:28] == REGION_RAM);

  // ---- RAM ----
  logic [31:0] ram_rdata;

  ram_dp #(
      .WORDS     (RAM_WORDS),
      .INIT_FILE (INIT_FILE)
  ) u_ram (
      .clk_i     (clk_i),
      .a_addr_i  (imem_addr[RAM_AW+1:2]),
      .a_rdata_o (imem_rdata),
      .b_addr_i  (dmem_addr[RAM_AW+1:2]),
      .b_we_i    (dmem_wstrb & {4{dmem_we && ram_sel}}),
      .b_wdata_i (dmem_wdata),
      .b_rdata_o (ram_rdata)
  );

  // ---- I/O writes ----
  logic io_we, uart_ready;
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

  // ---- cycle counter ----
  logic [31:0] cycle_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) cycle_q <= '0;
    else       cycle_q <= cycle_q + 32'd1;
  end

  // ---- I/O reads: registered, to arrive in WB like a block RAM's data ----
  logic        io_rsel_q;
  logic [31:0] io_rdata_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      io_rsel_q  <= 1'b0;
      io_rdata_q <= '0;
    end else begin
      io_rsel_q <= io_sel;
      case (dmem_addr[4:2])
        IO_LED:     io_rdata_q <= {28'b0, led_o};
        IO_UART_ST: io_rdata_q <= {31'b0, uart_ready};
        IO_CYCLE:   io_rdata_q <= cycle_q;
        default:    io_rdata_q <= '0;
      endcase
    end
  end

  assign dmem_rdata = io_rsel_q ? io_rdata_q : ram_rdata;

endmodule
