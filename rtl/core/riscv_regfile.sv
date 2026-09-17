// RV32I architectural register file: 32 registers, two read ports, one write
// port.
//
// Two behaviours are guaranteed here rather than left to the surrounding
// pipeline, because both are formal properties in CLAUDE.md §5.5:
//
//   x0 invariance    -- x0 reads as zero always, whatever is written to it.
//   WB->ID forwarding -- a read of the register being written this cycle
//                        returns the new value, not the old one (§5.3,
//                        "write-first behaviour").
//
// No reset on the storage array, deliberately. RV32I leaves x1-x31 undefined
// at reset -- software initialises what it uses -- and resetting 31 x 32 bits
// would cost 992 flops and force the array into fabric registers. Without a
// reset Vivado can infer distributed RAM (LUTRAM) instead, which is the whole
// reason the register file is cheap on an FPGA. The synthesis trend table in
// docs/PROGRESS.md records which of the two actually happened; the primitive
// names in docs/reports/utilization_ooc.rpt are the evidence.
//
// The simulation cost of having no reset is X on the read ports until a
// register has been written. That is handled in the testbench (Verilator also
// zeroes state by default), not by adding hardware -- see the X-propagation
// entry in CLAUDE.md §9.
module riscv_regfile #(
    parameter int unsigned XLEN   = 32,
    parameter int unsigned ADDR_W = 5
) (
    input  logic              clk_i,

    // Read ports (combinational)
    input  logic [ADDR_W-1:0] rs1_addr_i,
    output logic [XLEN-1:0]   rs1_rdata_o,
    input  logic [ADDR_W-1:0] rs2_addr_i,
    output logic [XLEN-1:0]   rs2_rdata_o,

    // Write port (synchronous)
    input  logic              rd_we_i,
    input  logic [ADDR_W-1:0] rd_addr_i,
    input  logic [XLEN-1:0]   rd_wdata_i
);

  localparam int unsigned NUM_REGS = 2 ** ADDR_W;

  logic [XLEN-1:0] mem [NUM_REGS];

  // Suppress writes to x0 at the source. The read ports force zero anyway, but
  // gating here means the write-first bypass below cannot forward a value that
  // was never architecturally stored.
  logic we;
  assign we = rd_we_i && (rd_addr_i != '0);

  always_ff @(posedge clk_i) begin
    if (we) mem[rd_addr_i] <= rd_wdata_i;
  end

  // Read ports. Order matters: the x0 test is outermost so it also defeats the
  // bypass, and the bypass is ahead of the array so a same-cycle write wins.
  always_comb begin
    if (rs1_addr_i == '0)                    rs1_rdata_o = '0;
    else if (we && (rs1_addr_i == rd_addr_i)) rs1_rdata_o = rd_wdata_i;
    else                                      rs1_rdata_o = mem[rs1_addr_i];
  end

  always_comb begin
    if (rs2_addr_i == '0)                    rs2_rdata_o = '0;
    else if (we && (rs2_addr_i == rd_addr_i)) rs2_rdata_o = rd_wdata_i;
    else                                      rs2_rdata_o = mem[rs2_addr_i];
  end

endmodule
