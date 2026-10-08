// Formal harness: x0 invariance on the register file (CLAUDE.md 5.5).
//
// The first property in the repo, and deliberately a small one: its job is
// to prove the chain -- Yosys reads the RTL, SymbiYosys drives a solver, a
// failure fails `make formal` -- before riscv-formal is in the picture.
//
// Every input of this module is unconstrained: in formal, a top-level input
// is any value the solver likes, chosen afresh each cycle. So the assertion
// below is checked against every sequence of reads and writes, not the ones a
// testbench happened to try. The register array has no reset, so its initial
// contents are unconstrained too -- including whatever x0's storage holds.
//
// Testbench code: not under rtl/'s synthesizable-subset rules, but it must
// still parse in Yosys, which supports immediate assertions in procedural
// blocks rather than the full concurrent SVA language.
module regfile_x0_formal #(
    parameter int unsigned XLEN   = 32,
    parameter int unsigned ADDR_W = 5
) (
    input  logic              clk_i,
    input  logic [ADDR_W-1:0] rs1_addr_i,
    input  logic [ADDR_W-1:0] rs2_addr_i,
    input  logic              rd_we_i,
    input  logic [ADDR_W-1:0] rd_addr_i,
    input  logic [XLEN-1:0]   rd_wdata_i
);

  logic [XLEN-1:0] rs1_rdata, rs2_rdata;

  riscv_regfile #(
      .XLEN   (XLEN),
      .ADDR_W (ADDR_W)
  ) u_dut (
      .clk_i       (clk_i),
      .f_raddr_i   ('0),
      .f_rdata_o   (),
      .rs1_addr_i  (rs1_addr_i),
      .rs1_rdata_o (rs1_rdata),
      .rs2_addr_i  (rs2_addr_i),
      .rs2_rdata_o (rs2_rdata),
      .rd_we_i     (rd_we_i),
      .rd_addr_i   (rd_addr_i),
      .rd_wdata_i  (rd_wdata_i)
  );

  // The property: a read of x0 returns zero, on either port, every cycle.
  always_comb begin
    if (rs1_addr_i == '0) assert (rs1_rdata == '0);
    if (rs2_addr_i == '0) assert (rs2_rdata == '0);
  end

  // Reachability (CLAUDE.md 5.5, 9). An assertion whose condition never
  // arises passes vacuously, so each scenario that could break x0 invariance
  // must be shown to happen. `mode cover` asks the solver for a trace reaching
  // each one; a cover it cannot reach fails the run.
  //
  // x0_dirty_q: some earlier cycle wrote a nonzero value to x0. Registers in
  // a formal harness start unconstrained like any other, so it is initialised
  // explicitly -- testbench code may use `initial`.
  logic x0_dirty_q;
  initial x0_dirty_q = 1'b0;

  always_ff @(posedge clk_i) begin
    if (rd_we_i && (rd_addr_i == '0) && (rd_wdata_i != '0)) x0_dirty_q <= 1'b1;
  end

  always_comb begin
    // A nonzero write to x0 and a read of x0 in the same cycle: the write-first
    // bypass is the path that would leak the value.
    cover (rd_we_i && (rd_addr_i == '0) && (rd_wdata_i != '0) && (rs1_addr_i == '0));
    cover (rd_we_i && (rd_addr_i == '0) && (rd_wdata_i != '0) && (rs2_addr_i == '0));
    // A read of x0 after a nonzero write to it: the storage path.
    cover (x0_dirty_q && (rs1_addr_i == '0));
    cover (x0_dirty_q && (rs2_addr_i == '0));
  end

endmodule
