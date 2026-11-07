// Formal harness for "no X into committed state" (CLAUDE.md 5.5), the
// general case. X1 (in rtl/core/riscv_core.sv) proves nothing commits while
// reset is held; this proves nothing left over from power-up commits after.
//
// X is modelled explicitly. xprop.sby runs Yosys's xprop pass over the
// flattened core, which gives every signal a second bit saying "this bit is
// X" and every port a _d (value) and _x (X mask) half. A flop with no reset
// powers up X. The memories' read data, the clock and the reset are driven
// fully defined: the program and its data are the environment's business.
//
// Two X sources, two claims. The pipeline's flops are reset, so X from them
// is a design bug. The register file is not, deliberately (RV32I leaves
// x1-x31 undefined), so X from it is software reading a register it never
// wrote -- and a branch, an address or a result built on one is X too.
//
//   XP  (prove task, k-induction; XPROP_REGFILE_DEFINED) with the register
//       file powering up arbitrary but defined, nothing committed is ever X
//       after reset: register writes (enable, address, data), stores
//       (enable, strobes, address, written lanes), retirements (valid, pc,
//       instruction) and the halt. Every flop that can reach committed state
//       is reset.
//   XT  (bmc and cover tasks; register file X too) the same, from reset until
//       the first instruction that reads a register not written since that
//       reset. Register-file X reaches committed state only through an
//       instruction that read it. After that the check stops, and the next
//       reset re-arms it. Bounded: the reachable patterns of register-file X
//       in flight are what an inductive version would need invariants for,
//       and the harness sees ports only.
//
// "Read" is decided here from the opcode, not from RVFI's rs fields, which
// are the raw instruction bits (LUI's would name a register). Missing a real
// read would show as a false failure, not a false pass. The X encoding is
// pessimistic (a mux with an X select is X even if both inputs agree), which
// can only add failures, never hide one.
//
// The property lives here rather than in rtl/ because it is stated on the
// X masks, which exist only after xprop rewrites the core's ports.
module xprop_formal #(
    // 1 (the *_m tasks): the core is built with M_EXT; adds an M cover.
    parameter bit M = 1'b0
) (
    input logic        clk_i,
    input logic        rst_i,
    input logic [31:0] imem_rdata_i,
    input logic [31:0] dmem_rdata_i
);

  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;
  localparam logic [6:0] OP_OP     = 7'b0110011;
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;

  // Each commit port: value (_d) and X mask (_x).
  logic [31:0]   dmem_addr_d, dmem_addr_x, dmem_wdata_d, dmem_wdata_x;
  logic [3:0]    dmem_wstrb_d, dmem_wstrb_x;
  logic          dmem_we_d, dmem_we_x;
  logic          wb_we_d, wb_we_x;
  logic [4:0]    wb_addr_d, wb_addr_x;
  logic [31:0]   wb_wdata_d, wb_wdata_x;
  logic          halt_d, halt_x;
  logic          rvfi_valid_d, rvfi_valid_x;
  logic [31:0]   rvfi_insn_d, rvfi_insn_x, rvfi_pc_d, rvfi_pc_x;
  logic [4:0]    rvfi_rd_d;
  logic [31:0]   id_ex_instr_d, ex_mem_instr_d;
  logic [31:0]   id_ex_rs1_rdata_x;
  logic [1023:0] regs_x;

  riscv_core u_core (
      .clk_i_d               (clk_i),          .clk_i_x               (1'b0),
      .rst_i_d               (rst_i),          .rst_i_x               (1'b0),
      .imem_rdata_i_d        (imem_rdata_i),   .imem_rdata_i_x        (32'b0),
      .dmem_rdata_i_d        (dmem_rdata_i),   .dmem_rdata_i_x        (32'b0),
      .dmem_ready_i_d        (1'b1),           .dmem_ready_i_x        (1'b0),
      .f_regs_o_d            (),               .f_regs_o_x            (regs_x),
      .dmem_addr_o_d         (dmem_addr_d),    .dmem_addr_o_x         (dmem_addr_x),
      .dmem_wdata_o_d        (dmem_wdata_d),   .dmem_wdata_o_x        (dmem_wdata_x),
      .dmem_wstrb_o_d        (dmem_wstrb_d),   .dmem_wstrb_o_x        (dmem_wstrb_x),
      .dmem_we_o_d           (dmem_we_d),      .dmem_we_o_x           (dmem_we_x),
      .dmem_re_o_d           (),               .dmem_re_o_x           (),
      .wb_rd_we_o_d          (wb_we_d),        .wb_rd_we_o_x          (wb_we_x),
      .wb_rd_addr_o_d        (wb_addr_d),      .wb_rd_addr_o_x        (wb_addr_x),
      .wb_rd_wdata_o_d       (wb_wdata_d),     .wb_rd_wdata_o_x       (wb_wdata_x),
      .halt_o_d              (halt_d),         .halt_o_x              (halt_x),
      .halt_next_o_d         (),               .halt_next_o_x         (),
      .vote_pc_i_d           ('0),             .vote_pc_i_x           ('0),
      .vote_halt_i_d         ('0),             .vote_halt_i_x         ('0),
      .vote_rd_we_i_d        (1'b0),           .vote_rd_we_i_x        (1'b0),
      .vote_rd_addr_i_d      ('0),             .vote_rd_addr_i_x      ('0),
      .vote_rd_wdata_i_d     ('0),             .vote_rd_wdata_i_x     ('0),
      .rvfi_valid_o_d        (rvfi_valid_d),   .rvfi_valid_o_x        (rvfi_valid_x),
      .rvfi_insn_o_d         (rvfi_insn_d),    .rvfi_insn_o_x         (rvfi_insn_x),
      .rvfi_pc_rdata_o_d     (rvfi_pc_d),      .rvfi_pc_rdata_o_x     (rvfi_pc_x),
      .rvfi_rd_addr_o_d      (rvfi_rd_d),      .rvfi_rd_addr_o_x      (),
      .id_ex_instr_o_d       (id_ex_instr_d),  .id_ex_instr_o_x       (),
      .ex_mem_instr_o_d      (ex_mem_instr_d), .ex_mem_instr_o_x      (),
      .id_ex_rs1_rdata_o_d   (),               .id_ex_rs1_rdata_o_x   (id_ex_rs1_rdata_x)
  );

  // The one assumption, as in core_formal.sv: the first cycle is a reset.
  // (XP's defined register file is not an assumption here: xprop.sby makes
  // those flops $anyinit before encoding, so they power up free, not X.)
  logic f_first = 1'b1;
  always_ff @(posedge clk_i) f_first <= 1'b0;
  always_comb if (f_first) assume (rst_i);

  // Does insn read a register not in def? x0 is always defined.
  function automatic logic reads_undef(input logic [31:0] insn, input logic [31:0] def);
    logic [6:0] op;
    logic       use1, use2;
    op   = insn[6:0];
    use1 = (op == OP_JALR) || (op == OP_BRANCH) || (op == OP_LOAD)
           || (op == OP_STORE) || (op == OP_IMM) || (op == OP_OP);
    use2 = (op == OP_BRANCH) || (op == OP_STORE) || (op == OP_OP);
    reads_undef = (use1 && (insn[19:15] != '0) && !def[insn[19:15]])
                  || (use2 && (insn[24:20] != '0) && !def[insn[24:20]]);
  endfunction

  // Does insn write a register? From the opcode, like reads_undef.
  function automatic logic writes_rd(input logic [31:0] insn);
    logic [6:0] op;
    op = insn[6:0];
    writes_rd = (op == OP_LUI) || (op == OP_AUIPC) || (op == OP_JAL) || (op == OP_JALR)
                || (op == OP_LOAD) || (op == OP_IMM) || (op == OP_OP);
  endfunction

  // f_def: registers written since the last reset. f_tainted: an instruction
  // that read an undefined one has retired, so commits may be X from here.
  // Both read the retirement's value half, which XP keeps defined until then.
  logic [31:0] f_def, f_def_now;
  logic [31:0] f_def_ex;
  logic        f_tainted, f_retire, f_taint_wb, f_taint_ex, f_stop;

  assign f_retire   = rvfi_valid_d && !rst_i;
  assign f_taint_wb = f_retire && reads_undef(rvfi_insn_d, f_def);

  // A store commits in EX, two cycles before it retires, with its sources
  // forwarded from the two instructions ahead of it: the one retiring now
  // and the one in MEM. So its sources count as defined if either of those
  // writes them -- and if the one in MEM itself read an undefined register,
  // its result may be X already and the store may carry it. (EX/MEM's word
  // may be a bubble; counting a bubble's write or read only stops the check
  // early, never hides a failure.)
  assign f_def_now  = f_def | ((f_retire && (rvfi_rd_d != '0)) ? (32'd1 << rvfi_rd_d) : '0);
  assign f_def_ex   = f_def_now | (writes_rd(ex_mem_instr_d) ? (32'd1 << ex_mem_instr_d[11:7]) : '0);
  assign f_taint_ex = (id_ex_instr_d[6:0] == OP_STORE)
                      && (reads_undef(id_ex_instr_d, f_def_ex) || reads_undef(ex_mem_instr_d, f_def_now));

`ifdef XPROP_REGFILE_DEFINED
  assign f_stop = 1'b0;   // XP: nothing can taint
`else
  assign f_stop = f_tainted || f_taint_wb || f_taint_ex;
`endif

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      f_def     <= '0;
      f_tainted <= 1'b0;
    end else begin
      f_def <= f_def_now;
      if (f_taint_wb) f_tainted <= 1'b1;
    end
  end

  logic [31:0] f_lanes;
  assign f_lanes = {{8{dmem_wstrb_d[3]}}, {8{dmem_wstrb_d[2]}},
                    {8{dmem_wstrb_d[1]}}, {8{dmem_wstrb_d[0]}}};

  always_comb begin
    if (!rst_i && !f_stop) begin
      // XP / XT: nothing committed is X.
      assert (!wb_we_x);
      if (wb_we_d) begin
        assert (wb_addr_x == '0);
        if (wb_addr_d != '0) assert (wb_wdata_x == '0);
      end
      assert (!dmem_we_x);
      if (dmem_we_d) begin
        assert (dmem_wstrb_x == '0);
        assert (dmem_addr_x  == '0);
        assert ((dmem_wdata_x & f_lanes) == '0);
      end
      assert (!rvfi_valid_x);
      if (rvfi_valid_d) begin
        assert (rvfi_pc_x   == '0);
        assert (rvfi_insn_x == '0);
      end
      assert (!halt_x);
    end
  end

  // XR, XP's strengthening invariant: no register holds X. Induction needs
  // it for the same reason as R1: a register can go unread for any number of
  // cycles, so no window length rules out a start state where one is X.
  // Under XT it is the bounded counterpart: a register written since reset
  // holds no X.
  for (genvar r = 1; r < 32; r++) begin : g_xr
    always_comb begin
`ifdef XPROP_REGFILE_DEFINED
      assert (regs_x[r*32 +: 32] == '0);
`else
      if (!rst_i && !f_tainted && f_def[r]) assert (regs_x[r*32 +: 32] == '0);
`endif
    end
  end

  // Reachability. Each is outside reset and before any taint, so XP is live
  // when it happens.
  logic f_past_valid = 1'b0;
  always_ff @(posedge clk_i) f_past_valid <= 1'b1;

  always_comb begin
    if (f_past_valid && !rst_i && !f_stop) begin
      // X inside the pipeline -- an operand read from an unwritten register,
      // by an instruction that does not use it or before it retires -- while
      // nothing committed is X.
      cover (id_ex_rs1_rdata_x != '0);
      // A register write of data computed from two defined, nonzero sources.
      cover (f_retire && (rvfi_rd_d != '0) && (rvfi_insn_d[6:0] == OP_OP)
             && (rvfi_insn_d[19:15] != '0) && (rvfi_insn_d[24:20] != '0));
      // A store committed.
      cover (dmem_we_d);
      // An M instruction retiring with a register write, all of it defined
      // (XP/XT hold at it): the unit's unreset datapath was written first.
      if (M) cover (f_retire && (rvfi_rd_d != '0) && (rvfi_insn_d[6:0] == OP_OP)
                    && (rvfi_insn_d[31:25] == 7'b0000001));
    end
    // The check stopping: an instruction reading an undefined register.
    if (f_past_valid && !rst_i) cover (f_taint_wb);
    // The X model is live: before the first edge an unreset view of the
    // pipeline -- here the halt -- powers up X.
    if (f_first) cover (halt_x);
  end

endmodule
