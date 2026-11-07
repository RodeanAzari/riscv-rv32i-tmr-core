// Formal stand-in for riscv_muldiv in the core's own proofs (core.sby, *_m
// tasks). Same ports and handshake; any result; done 3 to 5 cycles into EX,
// at the solver's choice, held until ack.
//
// Why not the real unit there:
//  - Values: the core's properties are about control -- stalls, bubbles,
//    forwarding, retirement order -- and hold for any M result. The real
//    datapath only adds multipliers to the solver's work (yices ran the base
//    case for 50 minutes without finishing). The unit's arithmetic is proven
//    on its own (muldiv.sby).
//  - Latency: a 34-cycle stall is longer than the induction window, which
//    then starts from pipelines no run produces. M2 (proven with this stub)
//    says each stall cycle holds pc, IF/ID and ID/EX and bubbles EX/MEM, so
//    from the third stall cycle on nothing in the core changes until done: a
//    long stall is a short one followed by cycles that change nothing -- the
//    argument prove_wait makes for holds with H1. The real unit's latency and
//    handshake are proven in muldiv.sby; riscv-formal runs the core with the
//    real unit (checks_m.cfg).
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

  (* anyseq *) logic            finish;
  (* anyseq *) logic [XLEN-1:0] value;

  typedef enum logic [1:0] {IDLE, BUSY, DONE} state_t;
  state_t     state_q;
  logic [1:0] n_q;              // BUSY cycles so far
  logic [XLEN-1:0] result_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= IDLE;
    end else begin
      case (state_q)
        IDLE: if (valid_i) begin state_q <= BUSY; n_q <= 2'd0; end
        BUSY: begin
          n_q <= n_q + 2'd1;
          // 1 to 3 BUSY cycles: 3 to 5 cycles in EX, capture and done included.
          if (finish || n_q == 2'd2) begin
            state_q  <= DONE;
            result_q <= value;
          end
        end
        DONE: if (ack_i) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end

  assign done_o   = (state_q == DONE);
  assign result_o = result_q;

endmodule
