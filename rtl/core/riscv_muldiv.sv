// M extension unit: MUL MULH MULHSU MULHU DIV DIVU REM REMU, multi-cycle, in EX.
//
// The core stalls IF/ID/EX while an M instruction waits here and sends a bubble
// into MEM; the result then leaves EX like an ALU result, so forwarding is
// unchanged (decision in docs/PROGRESS.md). Like the ALU, the operation is the
// ISA's own funct3.
//
// Handshake with the core:
//   valid_i  an M instruction is in EX and a_i/b_i are its operands. Sampled
//            only when idle: the operands are captured then, so what the
//            forwarding paths do while the instruction waits does not matter.
//   done_o   result_o holds the answer. It stays up, result held, until
//            ack_i: the instruction leaves EX. (A MEM_WAIT hold can keep it
//            there past the cycle the answer arrives.)
//   The core must hold valid_i from the start until ack_i; ack_i only with
//   done_o. Nothing can squash an instruction in EX (a branch resolves there,
//   so only younger instructions are squashed), so there is no kill input.
//
// Timing, in cycles the instruction spends in EX, counting the first:
//   MUL*   3  capture -> four partial products registered -> summed, done.
//   DIV*   XLEN + 2 (34)  capture |a|,|b| -> XLEN restoring steps -> signs
//          applied, done. Fixed: no early out, so the cycle count of a program
//          does not depend on its data.
//
// Multiply: operands sign- or zero-extended to XLEN+1 bits by the op, then
// split into a low half (unsigned) and a high half (signed, HALF+1 bits). The
// four products of halves are (HALF+1) x (HALF+1) signed -- 17 x 17 at XLEN 32,
// one DSP48E1 (25 x 18) each -- registered, then shifted into place and summed
// in fabric. On an ASIC the same register splits the multiply path in two.
//
// Divide: on |a| and |b|, so the restoring steps are unsigned. Signs are put
// back on the last cycle: the quotient negative when the operand signs differ,
// the remainder with the dividend's sign. The spec's two non-trapping corner
// cases need almost nothing:
//   x / 0         restoring division with a zero divisor gives quotient all
//                 ones and remainder |a|, which is the spec's DIVU/REMU answer;
//                 signed REM gets a's sign back, giving a, as the spec wants.
//                 Only the signed quotient must not be negated: -1, not 1.
//   INT_MIN / -1  |a| = 2^(XLEN-1) unsigned, |b| = 1: quotient 2^(XLEN-1),
//                 which negated is itself, and remainder 0. The spec's answer.
module riscv_muldiv #(
    parameter int unsigned XLEN = 32
) (
    input  logic            clk_i,
    input  logic            rst_i,
    input  logic            valid_i,
    input  logic            ack_i,
    input  logic [XLEN-1:0] a_i,
    input  logic [XLEN-1:0] b_i,
    input  logic [2:0]      funct3_i,
    output logic            done_o,
    output logic [XLEN-1:0] result_o
);

  localparam int unsigned HALF  = XLEN / 2;
  localparam int unsigned CNT_W = $clog2(XLEN + 1);
  localparam logic [CNT_W-1:0] STEPS = XLEN[CNT_W-1:0];
  localparam int unsigned PP_W  = 2*HALF + 2;           // a partial product
  localparam int unsigned EXT_W = 2*XLEN - PP_W;        // its sign extension

  // M funct3 encodings (opcode OP, funct7 0000001); MULHU (011) is the rest
  localparam logic [2:0] F3_MUL    = 3'b000;
  localparam logic [2:0] F3_MULH   = 3'b001;
  localparam logic [2:0] F3_MULHSU = 3'b010;
  // funct3[2] = divide; funct3[1] = remainder; funct3[0] = unsigned.

  typedef enum logic [1:0] {IDLE, MUL, DIV, DONE} state_t;
  state_t state_q, state_d;

  logic [2:0]  f3_q;           // op, captured with the operands
  logic [CNT_W-1:0] cnt_q;     // divide steps left

  // --- Multiply ------------------------------------------------------------
  // a_signed: MULH and MULHSU; b_signed: MULH only. MUL's low word is the same
  // either way, so it takes the unsigned path.
  logic a_signed, b_signed;
  assign a_signed = (funct3_i == F3_MULH) || (funct3_i == F3_MULHSU);
  assign b_signed = (funct3_i == F3_MULH);

  // Extended operands, XLEN+1 bits: low HALF bits and a signed high part.
  logic        [HALF-1:0] a_lo_q, b_lo_q;
  logic signed [HALF:0]   a_hi_q, b_hi_q;
  // Partial products, each (HALF+1) x (HALF+1) signed = 2*HALF+2 bits.
  logic signed [PP_W-1:0] p_ll_q, p_lh_q, p_hl_q, p_hh_q;

  // --- Divide --------------------------------------------------------------
  // rem_q:quo_q is the classic shift register: the dividend enters in quo_q
  // and shifts left into rem_q a bit per step while quotient bits fill quo_q
  // from the right.
  logic [XLEN-1:0] rem_q, quo_q, dvsr_q;
  logic            neg_quo_q, neg_rem_q;
  logic [XLEN-1:0] abs_a, abs_b;
  logic            a_neg, b_neg;

  assign a_neg = !funct3_i[0] && a_i[XLEN-1];
  assign b_neg = !funct3_i[0] && b_i[XLEN-1];
  assign abs_a = a_neg ? (~a_i + 1'b1) : a_i;
  assign abs_b = b_neg ? (~b_i + 1'b1) : b_i;

  // One restoring step: shift in the dividend's next bit, subtract if it fits.
  logic [XLEN:0]   rem_shift, trial;
  assign rem_shift = {rem_q, quo_q[XLEN-1]};
  assign trial     = rem_shift - {1'b0, dvsr_q};

  // --- Control -------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    case (state_q)
      IDLE: if (valid_i) state_d = funct3_i[2] ? DIV : MUL;
      MUL:  state_d = DONE;
      DIV:  if (cnt_q == 1) state_d = DONE;
      DONE: if (ack_i) state_d = IDLE;
      default: state_d = IDLE;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) state_q <= IDLE;
    else       state_q <= state_d;
  end

  // Datapath registers: no reset. Each is written before DONE reads it, and
  // DSP48 operand and product registers have no synchronous reset to spare.
  always_ff @(posedge clk_i) begin
    case (state_q)
      IDLE: if (valid_i) begin
        f3_q      <= funct3_i;
        a_lo_q    <= a_i[HALF-1:0];
        b_lo_q    <= b_i[HALF-1:0];
        a_hi_q    <= {a_signed && a_i[XLEN-1], a_i[XLEN-1:HALF]};
        b_hi_q    <= {b_signed && b_i[XLEN-1], b_i[XLEN-1:HALF]};
        rem_q     <= '0;
        quo_q     <= abs_a;
        dvsr_q    <= abs_b;
        // A zero divisor keeps the all-ones quotient positive (see header).
        neg_quo_q <= (a_neg != b_neg) && (b_i != '0);
        neg_rem_q <= a_neg;
        cnt_q     <= STEPS;
      end
      MUL: begin
        p_ll_q <= $signed({1'b0, a_lo_q}) * $signed({1'b0, b_lo_q});
        p_lh_q <= $signed({1'b0, a_lo_q}) * b_hi_q;
        p_hl_q <= a_hi_q * $signed({1'b0, b_lo_q});
        p_hh_q <= a_hi_q * b_hi_q;
      end
      DIV: begin
        if (!trial[XLEN]) begin                 // fits: keep the difference
          rem_q <= trial[XLEN-1:0];
          quo_q <= {quo_q[XLEN-2:0], 1'b1};
        end else begin
          rem_q <= rem_shift[XLEN-1:0];
          quo_q <= {quo_q[XLEN-2:0], 1'b0};
        end
        cnt_q <= cnt_q - 1'b1;
      end
      default: ;
    endcase
  end

  // --- Result --------------------------------------------------------------
  // The ISA wants the low or the high XLEN of the product's low 2*XLEN bits,
  // so the sum is taken modulo 2^(2*XLEN): each partial product sign-extended
  // to that width (a concatenation, not a size cast: Yosys) and shifted into
  // place, carries out of the top discarded.
  logic [2*XLEN-1:0] w_ll, w_lh, w_hl, w_hh, product;
  assign w_ll    = {{EXT_W{p_ll_q[PP_W-1]}}, p_ll_q};
  assign w_lh    = {{EXT_W{p_lh_q[PP_W-1]}}, p_lh_q};
  assign w_hl    = {{EXT_W{p_hl_q[PP_W-1]}}, p_hl_q};
  assign w_hh    = {{EXT_W{p_hh_q[PP_W-1]}}, p_hh_q};
  assign product = w_ll + (w_lh << HALF) + (w_hl << HALF) + (w_hh << (2*HALF));

  logic [XLEN-1:0] quo_res, rem_res;
  assign quo_res = neg_quo_q ? (~quo_q + 1'b1) : quo_q;
  assign rem_res = neg_rem_q ? (~rem_q + 1'b1) : rem_q;

  always_comb begin
    if (f3_q[2])                result_o = f3_q[1] ? rem_res : quo_res;
    else if (f3_q == F3_MUL)    result_o = product[XLEN-1:0];
    else                        result_o = product[2*XLEN-1:XLEN];
  end

  assign done_o = (state_q == DONE);

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Properties (tb/formal/muldiv.sby). The unit samples valid_i only when idle
  // and ack_i only when done, so it needs no assumption about its inputs: the
  // harness leaves every one free, every cycle, reset included after the first.
  //
  // f_* is a formal-only shadow of the operation in flight: the operands as
  // they were on the capture cycle, and the cycles spent since.
  //
  // f_past_valid: an edge has passed, so the state is reset's or the unit's.
  // Formal starts from arbitrary state and nothing is claimed about it, so
  // every property is gated on it; it needs an initial value, waived as in
  // riscv_core.
  /* verilator lint_off PROCASSINIT */
  logic             f_past_valid = 1'b0;
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge clk_i) f_past_valid <= 1'b1;
  logic [2:0]       f_f3_q;
  logic [CNT_W:0]   f_cyc_q;      // MUL/DIV cycles since capture

  always_ff @(posedge clk_i) begin
    if (state_q == IDLE && valid_i) begin
      f_f3_q  <= funct3_i;
      f_cyc_q <= '0;
    end else if (state_q == MUL || state_q == DIV) begin
      f_cyc_q <= f_cyc_q + 1'b1;
    end
  end

  // MUL/DIV-state cycles before DONE. In EX: capture + these + DONE.
  localparam logic [CNT_W:0] F_MUL_CYC = 1;
  localparam logic [CNT_W:0] F_DIV_CYC = {1'b0, STEPS};

  // Latency: DONE comes exactly when the header says -- capture cycle, then
  // one MUL or XLEN DIV cycles -- so the instruction spends 3 or XLEN + 2
  // cycles in EX, whatever the operands.
  always_comb if (f_past_valid) begin
    if (state_q != IDLE) assert (f3_q == f_f3_q);
    if (state_q == MUL) assert (!f3_q[2] && f_cyc_q == '0);
    if (state_q == DIV) begin
      assert (f3_q[2]);
      assert (cnt_q != '0 && cnt_q <= STEPS);
      assert (f_cyc_q == {1'b0, STEPS - cnt_q});
    end
    if (state_q == DONE) begin
      assert (f_cyc_q == (f3_q[2] ? F_DIV_CYC : F_MUL_CYC));
      if (f3_q[2]) assert (cnt_q == '0);
    end
  end

  // Handshake: a result stays, unchanged, until ack_i; after ack_i the unit
  // is idle; it leaves idle only on valid_i.
  logic            f_past_rst, f_past_done, f_past_ack, f_past_idle, f_past_vin;
  logic [XLEN-1:0] f_past_result;
  always_ff @(posedge clk_i) begin
    f_past_rst    <= rst_i;
    f_past_done   <= done_o;
    f_past_ack    <= ack_i;
    f_past_idle   <= (state_q == IDLE);
    f_past_vin    <= valid_i;
    f_past_result <= result_o;
  end
  always_comb if (f_past_valid && !f_past_rst) begin
    if (f_past_done && !f_past_ack) assert (done_o && result_o == f_past_result);
    if (f_past_done && f_past_ack)  assert (state_q == IDLE);
    if (f_past_idle && !f_past_vin) assert (state_q == IDLE);
  end

`ifdef MULDIV_ARITH
  // ---------------------------------------------------------------------------
  // Arithmetic: the result is the ISA's, by k-induction. Run at a reduced XLEN
  // (muldiv.sby says why); kept out of the plain FORMAL build, which the core
  // and its proofs will compile, because a full-width divide in an assertion
  // is no cheaper for a solver than one in the design.

  // The operands, as captured with funct3 (f_f3_q, above).
  logic [XLEN-1:0]  f_a_q, f_b_q;
  always_ff @(posedge clk_i) begin
    if (state_q == IDLE && valid_i) begin
      f_a_q <= a_i;
      f_b_q <= b_i;
    end
  end

  // The spec, written independently of the datapath above: plain *, /, %
  // and the two corner cases from the ISA manual's table.
  logic [2*XLEN-1:0] f_uu, f_ss, f_su;    // products: unsigned, signed, signed x unsigned
  logic [XLEN-1:0]   f_spec;
  logic              f_ovf;
  assign f_uu  = {{XLEN{1'b0}}, f_a_q} * {{XLEN{1'b0}}, f_b_q};
  assign f_ss  = {{XLEN{f_a_q[XLEN-1]}}, f_a_q} * {{XLEN{f_b_q[XLEN-1]}}, f_b_q};
  assign f_su  = {{XLEN{f_a_q[XLEN-1]}}, f_a_q} * {{XLEN{1'b0}}, f_b_q};
  assign f_ovf = (f_a_q == {1'b1, {(XLEN-1){1'b0}}}) && (f_b_q == '1);
  // The signed products' low words are MUL's, already taken from f_uu.
  logic unused_f_lo;
  assign unused_f_lo = ^{f_ss[XLEN-1:0], f_su[XLEN-1:0]};

  always_comb begin
    case (f_f3_q)
      3'b000:  f_spec = f_uu[XLEN-1:0];
      3'b001:  f_spec = f_ss[2*XLEN-1:XLEN];
      3'b010:  f_spec = f_su[2*XLEN-1:XLEN];
      3'b011:  f_spec = f_uu[2*XLEN-1:XLEN];
      3'b100:  f_spec = (f_b_q == '0) ? '1 : f_ovf ? f_a_q
                      : $unsigned($signed(f_a_q) / $signed(f_b_q));
      3'b101:  f_spec = (f_b_q == '0) ? '1 : f_a_q / f_b_q;
      3'b110:  f_spec = (f_b_q == '0) ? f_a_q : f_ovf ? '0
                      : $unsigned($signed(f_a_q) % $signed(f_b_q));
      default: f_spec = (f_b_q == '0) ? f_a_q : f_a_q % f_b_q;
    endcase
  end

  // Inductive invariants: what the datapath registers hold, in terms of the
  // shadow, at each step. Without them an induction window could start from
  // registers that disagree with the shadow and reach DONE with nonsense.
  logic              f_a_sgn, f_b_sgn;     // operand signed under this op
  logic [XLEN-1:0]   f_abs_a, f_abs_b, f_prefix, f_qmask, f_qdone;
  logic [2*XLEN-1:0] f_qd;
  assign f_a_sgn  = f_f3_q[2] ? !f_f3_q[0] : (f_f3_q == 3'b001 || f_f3_q == 3'b010);
  assign f_b_sgn  = f_f3_q[2] ? !f_f3_q[0] : (f_f3_q == 3'b001);
  assign f_abs_a  = (f_a_sgn && f_a_q[XLEN-1]) ? -f_a_q : f_a_q;
  assign f_abs_b  = (f_b_sgn && f_b_q[XLEN-1]) ? -f_b_q : f_b_q;
  // After j = XLEN - cnt steps: the dividend's top j bits have been divided.
  assign f_prefix = f_abs_a >> cnt_q;
  assign f_qmask  = ~({XLEN{1'b1}} << (STEPS - cnt_q));
  assign f_qdone  = quo_q & f_qmask;
  assign f_qd     = {{XLEN{1'b0}}, f_qdone} * {{XLEN{1'b0}}, f_abs_b};

  always_comb if (f_past_valid) begin
    if (state_q == MUL || (state_q == DONE && !f3_q[2])) begin
      assert (a_lo_q == f_a_q[HALF-1:0] && b_lo_q == f_b_q[HALF-1:0]);
      assert (a_hi_q == {f_a_sgn && f_a_q[XLEN-1], f_a_q[XLEN-1:HALF]});
      assert (b_hi_q == {f_b_sgn && f_b_q[XLEN-1], f_b_q[XLEN-1:HALF]});
    end
    if (state_q == DONE && !f3_q[2]) begin
      assert (p_ll_q == $signed({1'b0, a_lo_q}) * $signed({1'b0, b_lo_q}));
      assert (p_lh_q == $signed({1'b0, a_lo_q}) * b_hi_q);
      assert (p_hl_q == a_hi_q * $signed({1'b0, b_lo_q}));
      assert (p_hh_q == a_hi_q * b_hi_q);
    end
    if (state_q == DIV || (state_q == DONE && f3_q[2])) begin
      assert (dvsr_q == f_abs_b);
      assert (neg_rem_q == (f_a_sgn && f_a_q[XLEN-1]));
      assert (neg_quo_q == ((f_a_sgn && f_a_q[XLEN-1]) != (f_b_sgn && f_b_q[XLEN-1])
                            && f_b_q != '0));
      // The dividend bits not yet shifted in sit at the top of quo_q.
      assert ((quo_q >> (STEPS - cnt_q)) == (f_abs_a & ~({XLEN{1'b1}} << cnt_q)));
      if (f_abs_b != '0) begin
        assert (rem_q < f_abs_b);
        assert ({{XLEN{1'b0}}, rem_q} + f_qd == {{XLEN{1'b0}}, f_prefix});
      end else begin
        assert (rem_q == f_prefix && f_qdone == f_qmask);
      end
    end
    if (done_o) assert (result_o == f_spec);
  end
`endif

`ifdef MULDIV_ARITH
  // Reachability: every op completes, the corner cases arise, a result is
  // held through a delayed ack, and a new op starts the cycle after an ack.
  // For the unit's own run (muldiv.sby) only: inside the core a divide
  // outlasts the core's cover depth, and the core has covers of its own.
  logic f_done_held_q, f_acked_q;
  always_ff @(posedge clk_i) begin
    f_done_held_q <= done_o && !ack_i && !rst_i;
    f_acked_q     <= done_o && ack_i && !rst_i;
  end
  always_comb if (f_past_valid) begin
    cover (done_o && f_f3_q == 3'b000);  cover (done_o && f_f3_q == 3'b001);
    cover (done_o && f_f3_q == 3'b010);  cover (done_o && f_f3_q == 3'b011);
    cover (done_o && f_f3_q == 3'b100);  cover (done_o && f_f3_q == 3'b101);
    cover (done_o && f_f3_q == 3'b110);  cover (done_o && f_f3_q == 3'b111);
    cover (done_o && f3_q[2] && f_b_q == '0 && f_a_q[XLEN-1]);         // x / 0, a < 0
    cover (done_o && f3_q[2] && !f3_q[0] && f_a_q == {1'b1, {(XLEN-1){1'b0}}}
           && f_b_q == '1);                                            // INT_MIN / -1
    cover (done_o && f_done_held_q);
    cover (f_acked_q && state_q == IDLE && valid_i);
  end
`endif
`endif

endmodule
