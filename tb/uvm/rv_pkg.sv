// UVM environment for riscv_core (Phase C, buildplan.md 5.6).
//
// One sequence item is one PROGRAM: the driver loads it into the testbench
// memory and into the C golden model, resets the core, and waits for the
// halt every program ends in. A reactive memory serves both ports with
// block-RAM timing. The monitor turns RVFI into one transaction per
// retirement; the scoreboard steps the model once per retirement and
// compares; the coverage collector closes against docs/coverage-plan.md.
`timescale 1ns / 1ps

package rv_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---------------------------------------------------------------- model --
  import "DPI-C" function void rvm_reset(int unsigned pc);
  import "DPI-C" function void rvm_mem_clear();
  import "DPI-C" function void rvm_mem_write(int unsigned addr, int unsigned word);
  import "DPI-C" function int rvm_step(
      output int unsigned insn, output int unsigned pc_rdata, output int unsigned pc_wdata,
      output int unsigned rs1_addr, output int unsigned rs1_rdata, output int unsigned rs1_defined,
      output int unsigned rs2_addr, output int unsigned rs2_rdata, output int unsigned rs2_defined,
      output int unsigned rd_addr, output int unsigned rd_wdata,
      output int unsigned mem_addr, output int unsigned mem_rmask, output int unsigned mem_wmask,
      output int unsigned mem_rdata, output int unsigned mem_wdata,
      output int unsigned trap, output int unsigned halt);

  localparam int RV_OK = 0, RV_HALTED = 1;

  // ------------------------------------------------------------ encodings --
  localparam bit [6:0] OP_LUI = 7'h37, OP_AUIPC = 7'h17, OP_JAL = 7'h6F, OP_JALR = 7'h67,
                       OP_BRANCH = 7'h63, OP_LOAD = 7'h03, OP_STORE = 7'h23,
                       OP_IMM = 7'h13, OP_OP = 7'h33, OP_FENCE = 7'h0F, OP_SYSTEM = 7'h73;
  localparam bit [31:0] ECALL = 32'h0000_0073, EBREAK = 32'h0010_0073, FENCE = 32'h0FF0_000F;

  // Memory layout. Code from 0; data in [DATA_LO, DATA_HI), reached only
  // through the base registers, which point into its middle so every
  // 12-bit offset stays inside it.
  localparam int unsigned DATA_LO = 32'h6000, DATA_HI = 32'hA000;
  localparam int unsigned BASE_LO = 32'h7000, BASE_HI = 32'h9000;

  // Register roles in generated programs.
  localparam int GEN_REGS  = 26;          // x1..x26: anything goes
  localparam int BASE0     = 27;          // x27..x30: data pointers, set once
  localparam int NBASE     = 4;
  localparam int LOOP_REG  = 31;          // loop counters

  function automatic bit [31:0] enc_r(bit [6:0] f7, bit [4:0] rs2, rs1, bit [2:0] f3, bit [4:0] rd, bit [6:0] op);
    return {f7, rs2, rs1, f3, rd, op};
  endfunction
  function automatic bit [31:0] enc_i(int imm, bit [4:0] rs1, bit [2:0] f3, bit [4:0] rd, bit [6:0] op);
    bit [11:0] i = imm[11:0];
    return {i, rs1, f3, rd, op};
  endfunction
  function automatic bit [31:0] enc_s(int imm, bit [4:0] rs2, rs1, bit [2:0] f3);
    bit [11:0] i = imm[11:0];
    return {i[11:5], rs2, rs1, f3, i[4:0], OP_STORE};
  endfunction
  function automatic bit [31:0] enc_b(int off, bit [4:0] rs2, rs1, bit [2:0] f3);
    bit [12:0] i = off[12:0];
    return {i[12], i[10:5], rs2, rs1, f3, i[4:1], i[11], OP_BRANCH};
  endfunction
  function automatic bit [31:0] enc_u(bit [19:0] imm, bit [4:0] rd, bit [6:0] op);
    return {imm, rd, op};
  endfunction
  function automatic bit [31:0] enc_j(int off, bit [4:0] rd);
    bit [20:0] i = off[20:0];
    return {i[20], i[10:1], i[11], i[19:12], rd, OP_JAL};
  endfunction

  // Instruction index for coverage group 1 (docs/coverage-plan.md), -1 if
  // not one of the 40.
  function automatic int mnemonic(bit [31:0] in);
    bit [6:0] op = in[6:0];
    bit [2:0] f3 = in[14:12];
    bit [6:0] f7 = in[31:25];
    case (op)
      OP_LUI:    return 0;
      OP_AUIPC:  return 1;
      OP_JAL:    return 2;
      OP_JALR:   return (f3 == 0) ? 3 : -1;
      OP_BRANCH: case (f3) 0: return 4; 1: return 5; 4: return 6; 5: return 7;
                           6: return 8; 7: return 9; default: return -1; endcase
      OP_LOAD:   case (f3) 0: return 10; 1: return 11; 2: return 12; 4: return 13;
                           5: return 14; default: return -1; endcase
      OP_STORE:  case (f3) 0: return 15; 1: return 16; 2: return 17; default: return -1; endcase
      OP_IMM:    case (f3) 0: return 18; 2: return 19; 3: return 20; 4: return 21;
                           6: return 22; 7: return 23; 1: return 24;
                           default: return (f7 == 7'h20) ? 26 : 25; endcase
      OP_OP:     case (f3) 0: return (f7 == 7'h20) ? 28 : 27; 1: return 29; 2: return 30;
                           3: return 31; 4: return 32; 5: return (f7 == 7'h20) ? 34 : 33;
                           6: return 35; default: return 36; endcase
      OP_FENCE:  return (f3 == 0) ? 37 : -1;
      OP_SYSTEM: return (in == ECALL) ? 38 : (in == EBREAK) ? 39 : -1;
      default:   return -1;
    endcase
  endfunction

  function automatic bit reads_rs1(bit [31:0] in);
    bit [6:0] op = in[6:0];
    return op inside {OP_JALR, OP_BRANCH, OP_LOAD, OP_STORE, OP_IMM, OP_OP};
  endfunction
  function automatic bit reads_rs2(bit [31:0] in);
    bit [6:0] op = in[6:0];
    return op inside {OP_BRANCH, OP_STORE, OP_OP};
  endfunction
  function automatic int imm_i(bit [31:0] in);  return $signed(in[31:20]); endfunction
  function automatic int imm_s(bit [31:0] in);  return $signed({in[31:25], in[11:7]}); endfunction
  function automatic int imm_b(bit [31:0] in);
    return $signed({in[31], in[7], in[30:25], in[11:8], 1'b0});
  endfunction

  // -------------------------------------------------------------- memory --
  // One byte-addressed image behind both ports (code and data), shared by the
  // driver, which loads it, and the responder, which serves the core.
  class rv_mem extends uvm_object;
    `uvm_object_utils(rv_mem)
    bit [31:0] words[int unsigned];
    function new(string name = "rv_mem"); super.new(name); endfunction
    function bit [31:0] read(bit [31:0] addr);
      int unsigned w = addr >> 2;
      return words.exists(w) ? words[w] : 32'h0;
    endfunction
    function void write(bit [31:0] addr, bit [31:0] data, bit [3:0] strb);
      bit [31:0] old = read(addr);
      for (int i = 0; i < 4; i++) if (strb[i]) old[8*i +: 8] = data[8*i +: 8];
      words[addr >> 2] = old;
    endfunction
  endclass

  // ------------------------------------------------------- transactions --
  class rv_program extends uvm_sequence_item;
    `uvm_object_utils(rv_program)
    string     label;
    bit [31:0] code[$];                 // from address 0
    bit [31:0] data[int unsigned];      // byte address -> word, in the data region
    function new(string name = "rv_program"); super.new(name); endfunction
  endclass

  class rv_retire extends uvm_sequence_item;
    `uvm_object_utils(rv_retire)
    bit [63:0] order;
    bit [31:0] insn, pc_rdata, pc_wdata, rs1_rdata, rs2_rdata, rd_wdata;
    bit [31:0] mem_addr, mem_rdata, mem_wdata;
    bit [4:0]  rs1_addr, rs2_addr, rd_addr;
    bit [3:0]  mem_rmask, mem_wmask;
    bit        trap, halt, intr;
    function new(string name = "rv_retire"); super.new(name); endfunction
  endclass

  // ----------------------------------------------------------- generator --
  // Constrained-random choice of one operation; the program builder turns it
  // into instructions. Constraints carry the corner values the coverage plan
  // asks for, weighted in, rather than hoping a uniform draw finds them.
  //
  // Randomized in stages -- the kind first, then a small class for that
  // kind's fields -- not as one class whose every constraint is conditional
  // on the kind. XSim 2025.2 solves the single class badly: over 2000 draws
  // it never picked K_I and gave each f3 field two or three values, while
  // the same constraints in isolation come out as weighted. Measured with a
  // histogram of the draws; the staged classes are measured the same way.
  typedef enum {K_R, K_I, K_SHIFT, K_LUI, K_AUIPC, K_LOAD, K_STORE,
                K_BRANCH, K_JAL, K_JALR, K_LOOP, K_FENCE} kind_e;

  // A dist next to a condition on a non-random member is ignored by XSim (the
  // draws come out uniform), so each variant is its own class.
  class rv_kind_r;
    rand kind_e kind;
    constraint c {
      kind dist {K_R := 18, K_I := 16, K_SHIFT := 6, K_LUI := 3, K_AUIPC := 3,
                 K_LOAD := 14, K_STORE := 10, K_BRANCH := 12, K_JAL := 3,
                 K_JALR := 3, K_LOOP := 3, K_FENCE := 1};
    }
  endclass
  class rv_body_kind_r;      // straight-line only: loop bodies, JALR filler
    rand kind_e kind;
    constraint c {
      kind dist {K_R := 18, K_I := 16, K_SHIFT := 6, K_LUI := 3, K_LOAD := 14, K_STORE := 10};
    }
  endclass

  class rv_regs_r;
    rand bit [4:0] rd, rs1, rs2;
    rand bit       dep1, dep2, same;    // read a recent result; rs1 == rs2
    rand int       base;                // which data pointer
    constraint c {
      rd  dist {0 := 1, [1:GEN_REGS] :/ 24};
      rs1 inside {[0:GEN_REGS]};
      rs2 inside {[0:GEN_REGS]};
      dep1 dist {1 := 1, 0 := 1};
      dep2 dist {1 := 1, 0 := 2};
      same dist {1 := 1, 0 := 9};
      base inside {[0:NBASE-1]};
    }
  endclass

  class rv_r_r;     rand bit [2:0] f3; rand bit alt;
    constraint c { alt -> f3 inside {0, 5}; alt dist {1 := 1, 0 := 3}; }
  endclass
  class rv_i_r;     rand bit [2:0] f3; rand int imm;
    constraint c { f3 inside {0, 2, 3, 4, 6, 7};
                   imm dist {0 := 2, 1 := 2, -1 := 2, 2047 := 2, -2048 := 2, [-2048:2047] :/ 6}; }
  endclass
  class rv_shift_r; rand bit [2:0] f3; rand bit alt; rand int imm;
    constraint c { f3 inside {1, 5}; alt -> f3 == 5;
                   imm dist {0 := 2, 1 := 2, 31 := 2, [0:31] :/ 4}; }
  endclass
  class rv_upper_r; rand bit [19:0] uimm;
    constraint c { uimm dist {20'h0 := 2, 20'h80000 := 2, 20'hFFFFF := 2, [0:20'hFFFFF] :/ 4}; }
  endclass
  // Loads and stores stay aligned here (an unaligned one traps and ends the
  // program); the trap tails reach the misaligned bins. The offset is a
  // weighted corner (0, -1, 2047, -2048) or a random value, then aligned
  // to the width procedurally: a dist beside implications on the same
  // variable is another thing XSim drops.
  class rv_load_r;  rand bit [2:0] f3; constraint c { f3 inside {0, 1, 2, 4, 5}; } endclass
  class rv_store_r; rand bit [2:0] f3; constraint c { f3 inside {0, 1, 2}; } endclass
  class rv_offset_r;
    rand int corner; rand int r;
    constraint c { corner dist {0 := 2, 1 := 2, 2 := 2, 3 := 2, 4 := 8}; r inside {[-2048:2047]}; }
    function int offset(int size);
      int v;
      case (corner) 0: v = 0; 1: v = -1; 2: v = 2047; 3: v = -2048; default: v = r; endcase
      if (v % size != 0) v = r - (r % size);    // a corner the width cannot use
      return v;
    endfunction
  endclass
  class rv_ctrl_r;
    rand bit [2:0] f3; rand int skip, loop_n, loop_body;
    constraint c { f3 inside {0, 1, 4, 5, 6, 7}; skip inside {[1:6]};
                   loop_n inside {[1:3]}; loop_body inside {[1:3]}; }
  endclass

  class rv_op;
    kind_e     kind;
    bit [4:0]  rd, rs1, rs2;
    bit [2:0]  f3;
    bit        alt;
    int        imm;
    bit [19:0] uimm;
    int        skip, loop_n, loop_body;
    int        base;

    // recent: registers written by the last few operations, for dependent
    // reads. The picks from it are procedural: a constraint over a dynamic
    // queue (`rs1 inside {recent}`) sends XSim's elaborator into a loop it
    // never leaves.
    static function rv_op draw(bit body_only, const ref int unsigned recent[$]);
      rv_op o = new();
      rv_regs_r r = new();
      if (body_only) begin
        rv_body_kind_r k = new(); if (!k.randomize()) `uvm_fatal("GEN", "randomize failed")
        o.kind = k.kind;
      end else begin
        rv_kind_r k = new(); if (!k.randomize()) `uvm_fatal("GEN", "randomize failed")
        o.kind = k.kind;
      end
      if (!r.randomize()) `uvm_fatal("GEN", "randomize failed")
      o.rd = r.rd; o.rs1 = r.rs1; o.rs2 = r.rs2; o.base = r.base;
      if (r.dep1 && recent.size() > 0) o.rs1 = recent[$urandom_range(recent.size() - 1)];
      if (r.dep2 && recent.size() > 0) o.rs2 = recent[$urandom_range(recent.size() - 1)];
      if (r.same) o.rs2 = o.rs1;
      case (o.kind)
        K_R: begin
          rv_r_r x = new(); if (!x.randomize()) `uvm_fatal("GEN", "randomize failed")
          o.f3 = x.f3; o.alt = x.alt;
        end
        K_I: begin
          rv_i_r x = new(); if (!x.randomize()) `uvm_fatal("GEN", "randomize failed")
          o.f3 = x.f3; o.imm = x.imm;
        end
        K_SHIFT: begin
          rv_shift_r x = new(); if (!x.randomize()) `uvm_fatal("GEN", "randomize failed")
          o.f3 = x.f3; o.alt = x.alt; o.imm = x.imm;
        end
        K_LUI, K_AUIPC: begin
          rv_upper_r x = new(); if (!x.randomize()) `uvm_fatal("GEN", "randomize failed")
          o.uimm = x.uimm;
        end
        K_LOAD, K_STORE: begin
          rv_offset_r x = new();
          if (o.kind == K_LOAD) begin
            rv_load_r l = new(); if (!l.randomize()) `uvm_fatal("GEN", "randomize failed")
            o.f3 = l.f3;
          end else begin
            rv_store_r st = new(); if (!st.randomize()) `uvm_fatal("GEN", "randomize failed")
            o.f3 = st.f3;
          end
          if (!x.randomize()) `uvm_fatal("GEN", "randomize failed")
          o.imm = x.offset(1 << o.f3[1:0]);
        end
        default: begin
          rv_ctrl_r x = new(); if (!x.randomize()) `uvm_fatal("GEN", "randomize failed")
          o.f3 = x.f3; o.skip = x.skip; o.loop_n = x.loop_n; o.loop_body = x.loop_body;
        end
      endcase
      return o;
    endfunction
  endclass

  // Builds whole programs. Two passes: choose the operations, then resolve
  // every forward branch or jump to a target that is safe to land on -- not
  // inside a loop (a skipped counter set-up would loop ~2^32 times) and not on
  // the JALR of an AUIPC/JALR pair (its base would be stale).
  class rv_program_builder;
    typedef struct {
      bit [31:0] word;
      bit        fixup;     // forward branch / JAL: offset filled in pass 2
      int        skip;
      bit        safe;      // a forward branch may land here
    } slot_t;

    slot_t s[$];
    int unsigned recent[$];

    function void emit(bit [31:0] w, bit safe = 1);
      slot_t t;
      t.word = w; t.fixup = 0; t.skip = 0; t.safe = safe;
      s.push_back(t);
    endfunction

    function void note_write(int rd);
      if (rd == 0 || rd > GEN_REGS) return;
      recent.push_front(rd);
      if (recent.size() > 4) void'(recent.pop_back());
    endfunction

    // li rd, value as LUI + ADDI.
    function void li(int rd, bit [31:0] v);
      bit [31:0] hi = v + 32'h800;
      emit(enc_u(hi[31:12], rd, OP_LUI));
      emit(enc_i($signed(v[11:0]), rd, 0, rd, OP_IMM));
    endfunction

    function void prologue();
      for (int r = 1; r <= GEN_REGS; r++) li(r, $urandom());
      for (int b = 0; b < NBASE; b++)
        li(BASE0 + b, $urandom_range(BASE_HI - 4, BASE_LO) & ~32'h3);
      emit(enc_i(0, 0, 0, LOOP_REG, OP_IMM));
    endfunction

    function bit [31:0] simple(rv_op o);
      case (o.kind)
        K_R:     return enc_r(o.alt ? 7'h20 : 7'h00, o.rs2, o.rs1, o.f3, o.rd, OP_OP);
        K_I:     return enc_i(o.imm, o.rs1, o.f3, o.rd, OP_IMM);
        K_SHIFT: return enc_i({o.alt ? 7'h20 : 7'h00, o.imm[4:0]}, o.rs1, o.f3, o.rd, OP_IMM);
        K_LUI:   return enc_u(o.uimm, o.rd, OP_LUI);
        K_AUIPC: return enc_u(o.uimm, o.rd, OP_AUIPC);
        K_LOAD:  return enc_i(o.imm, BASE0 + o.base, o.f3, o.rd, OP_LOAD);
        K_STORE: return enc_s(o.imm, o.rs2, BASE0 + o.base, o.f3);
        default: return FENCE;
      endcase
    endfunction

    function rv_op draw(bit body_only = 0);
      return rv_op::draw(body_only, recent);
    endfunction

    function void body(int len);
      while (s.size() < len) begin
        rv_op o = draw();
        case (o.kind)
          K_BRANCH: begin
            slot_t t;
            t.word = enc_b(0, o.rs2, o.rs1, o.f3); t.fixup = 1; t.skip = o.skip; t.safe = 1;
            s.push_back(t);
          end
          K_JAL: begin
            slot_t t;
            t.word = enc_j(0, o.rd); t.fixup = 1; t.skip = o.skip; t.safe = 1;
            s.push_back(t);
            note_write(o.rd);
          end
          K_JALR: begin
            // auipc rt, 0 ; jalr rd, imm(rt): lands `skip` past the jalr.
            // An odd imm checks that JALR clears bit 0.
            int rt = $urandom_range(GEN_REGS, 1);
            int imm = 8 + 4 * (o.skip - 1) + ($urandom_range(3) == 0);
            emit(enc_u(0, rt, OP_AUIPC));
            emit(enc_i(imm, rt, 0, o.rd, OP_JALR), 0);
            for (int k = 0; k < o.skip - 1; k++) emit(simple(draw(1)));
            note_write(o.rd);
          end
          K_LOOP: begin
            // addi x31, x0, n ; body ; addi x31, x31, -1 ; bne x31, x0, back
            int start;
            emit(enc_i(o.loop_n, 0, 0, LOOP_REG, OP_IMM));
            start = s.size();
            for (int k = 0; k < o.loop_body; k++) begin
              rv_op b = draw(1);
              emit(simple(b), 0);
              if (b.kind != K_STORE) note_write(b.rd);
            end
            emit(enc_i(-1, LOOP_REG, 0, LOOP_REG, OP_IMM), 0);
            emit(enc_b(4 * (start - s.size()), 0, LOOP_REG, 1), 0);
          end
          default: begin
            emit(simple(o));
            if (!(o.kind inside {K_STORE, K_FENCE})) note_write(o.rd);
          end
        endcase
      end
    endfunction

    // Every program ends in a trap, which halts the core. Usually ECALL or
    // EBREAK; otherwise one of the plan's trap and misaligned-access bins.
    function void tail();
      int b = BASE0 + $urandom_range(NBASE - 1);
      int sel = $urandom_range(15);
      case (sel)
        0, 1, 2, 3: emit(ECALL);
        4, 5, 6:    emit(EBREAK);
        7:  emit(enc_i(2 * $urandom_range(1) + 1, b, $urandom_range(1) ? 1 : 5, 1, OP_LOAD)); // LH/LHU +1/+3
        8:  emit(enc_i($urandom_range(3, 1), b, 2, 1, OP_LOAD));                               // LW +1..3
        9:  emit(enc_s(2 * $urandom_range(1) + 1, 1, b, 1));                                   // SH +1/+3
        10: emit(enc_s($urandom_range(3, 1), 1, b, 2));                                        // SW +1..3
        11: emit(enc_b(6, 0, 0, 0));                                                           // beq taken to +6
        12: emit(enc_j(6, 1));                                                                 // jal to +6
        default: begin                                                                        // jalr to +10
          int rt = $urandom_range(GEN_REGS, 1);
          emit(enc_u(0, rt, OP_AUIPC));
          emit(enc_i(10, rt, 0, 1, OP_JALR), 0);
        end
      endcase
    endfunction

    function rv_program build(int len, string label);
      rv_program p = new(label);
      int tail_at;
      s.delete(); recent.delete();
      prologue();
      body(s.size() + len);
      tail_at = s.size();
      tail();
      // pass 2: forward targets, never past the tail's first word (which is
      // always safe; the tail's own JALR is not)
      foreach (s[i]) if (s[i].fixup) begin
        int t = i + s[i].skip;
        if (t > tail_at) t = tail_at;
        while (t < tail_at && !s[t].safe) t++;
        if (s[i].word[6:0] == OP_BRANCH)
          s[i].word = enc_b(4 * (t - i), s[i].word[24:20], s[i].word[19:15], s[i].word[14:12]);
        else
          s[i].word = enc_j(4 * (t - i), s[i].word[11:7]);
      end
      foreach (s[i]) p.code.push_back(s[i].word);
      p.label = label;
      for (int unsigned a = DATA_LO; a < DATA_HI; a += 4) p.data[a] = $urandom();
      return p;
    endfunction
  endclass

  // ------------------------------------------------------------ sequences --
  class rv_random_seq extends uvm_sequence #(rv_program);
    `uvm_object_utils(rv_random_seq)
    int n = 100;
    function new(string name = "rv_random_seq"); super.new(name); endfunction
    task body();
      rv_program_builder b = new();
      for (int i = 0; i < n; i++) begin
        rv_program p = b.build($urandom_range(160, 40), $sformatf("random #%0d", i));
        start_item(p);
        finish_item(p);
      end
    endtask
  endclass

  typedef class rv_scoreboard;
  typedef class rv_coverage;

  // ---------------------------------------------------------------- agent --
  class rv_mem_responder extends uvm_component;
    `uvm_component_utils(rv_mem_responder)
    virtual core_if vif;
    rv_mem mem;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    // Block-RAM timing on both ports: the address is taken at the clock
    // edge and its word is returned through the following cycle. The data
    // port reads first, then writes, like the block RAM on the board.
    task run_phase(uvm_phase phase);
      forever begin
        @(posedge vif.clk);
        begin
          bit [31:0] ia = vif.imem_addr, da = vif.dmem_addr;
          bit [31:0] ir = mem.read(ia), dr = mem.read(da);
          if (vif.dmem_we) mem.write(da, vif.dmem_wdata, vif.dmem_wstrb);
          vif.imem_rdata <= ir;
          vif.dmem_rdata <= dr;
        end
      end
    endtask
  endclass

  class rv_driver extends uvm_driver #(rv_program);
    `uvm_component_utils(rv_driver)
    virtual core_if vif;
    rv_mem mem;
    rv_scoreboard sb;      // told where each program starts and ends
    rv_coverage   cov;
    int max_cycles = 20000;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
      vif.rst <= 1'b1;
      forever begin
        rv_program p;
        int cycles;
        seq_item_port.get_next_item(p);
        // load the same image into the core's memory and the model's
        mem.words.delete();
        rvm_mem_clear();
        foreach (p.code[i]) begin
          mem.words[i] = p.code[i];
          rvm_mem_write(4 * i, p.code[i]);
        end
        foreach (p.data[a]) begin
          mem.words[a >> 2] = p.data[a];
          rvm_mem_write(a, p.data[a]);
        end
        rvm_reset(0);
        sb.start_program(p.label);
        cov.start_program();
        vif.rst <= 1'b1;
        repeat (4) @(posedge vif.clk);
        vif.rst <= 1'b0;
        cycles = 0;
        while (!vif.halt && cycles < max_cycles) begin
          @(posedge vif.clk);
          cycles++;
        end
        if (!vif.halt)
          `uvm_error("DRV", $sformatf("%s: no halt in %0d cycles", p.label, max_cycles))
        repeat (8) @(posedge vif.clk);   // anything retiring after the halt shows here
        sb.end_program();
        vif.rst <= 1'b1;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class rv_monitor extends uvm_monitor;
    `uvm_component_utils(rv_monitor)
    virtual core_if vif;
    uvm_analysis_port #(rv_retire) ap;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction
    task run_phase(uvm_phase phase);
      forever begin
        @(posedge vif.clk);
        if (vif.rvfi_valid && !vif.rst) begin
          rv_retire t = new();
          t.order = vif.rvfi_order;       t.insn = vif.rvfi_insn;
          t.pc_rdata = vif.rvfi_pc_rdata; t.pc_wdata = vif.rvfi_pc_wdata;
          t.rs1_addr = vif.rvfi_rs1_addr; t.rs1_rdata = vif.rvfi_rs1_rdata;
          t.rs2_addr = vif.rvfi_rs2_addr; t.rs2_rdata = vif.rvfi_rs2_rdata;
          t.rd_addr = vif.rvfi_rd_addr;   t.rd_wdata = vif.rvfi_rd_wdata;
          t.mem_addr = vif.rvfi_mem_addr; t.mem_rmask = vif.rvfi_mem_rmask;
          t.mem_wmask = vif.rvfi_mem_wmask;
          t.mem_rdata = vif.rvfi_mem_rdata; t.mem_wdata = vif.rvfi_mem_wdata;
          t.trap = vif.rvfi_trap; t.halt = vif.rvfi_halt; t.intr = vif.rvfi_intr;
          ap.write(t);
        end
      end
    endtask
  endclass

  class rv_agent extends uvm_agent;
    `uvm_component_utils(rv_agent)
    rv_driver                    drv;
    uvm_sequencer #(rv_program)  sqr;
    rv_mem_responder             resp;
    rv_monitor                   mon;
    rv_mem                       mem;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      virtual core_if vif;
      if (!uvm_config_db#(virtual core_if)::get(this, "", "vif", vif))
        `uvm_fatal("AGT", "no vif")
      mem  = rv_mem::type_id::create("mem");
      drv  = rv_driver::type_id::create("drv", this);
      sqr  = uvm_sequencer#(rv_program)::type_id::create("sqr", this);
      resp = rv_mem_responder::type_id::create("resp", this);
      mon  = rv_monitor::type_id::create("mon", this);
      drv.vif = vif; resp.vif = vif; mon.vif = vif;
      drv.mem = mem; resp.mem = mem;
    endfunction
    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ----------------------------------------------------------- scoreboard --
  class rv_scoreboard extends uvm_subscriber #(rv_retire);
    `uvm_component_utils(rv_scoreboard)
    string label;
    bit    model_halted;
    int    retired, checked_programs, total_retired, rs_checked;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void start_program(string l);
      label = l; model_halted = 0; retired = 0;
    endfunction

    function void end_program();
      if (!model_halted)
        `uvm_error("SB", $sformatf("%s: core halted, model did not (after %0d)", label, retired))
      checked_programs++;
    endfunction

    function void write(rv_retire t);
      int unsigned insn, pc_rdata, pc_wdata, rs1_addr, rs1_rdata, rs1_def, rs2_addr, rs2_rdata,
                   rs2_def, rd_addr, rd_wdata, mem_addr, mem_rmask, mem_wmask, mem_rdata,
                   mem_wdata, trap, halt;
      int s;
      string where;
      bit [31:0] lanes;
      if (model_halted) begin
        `uvm_error("SB", $sformatf("%s: retirement after the halt: pc %h insn %h",
                                   label, t.pc_rdata, t.insn))
        return;
      end
      s = rvm_step(insn, pc_rdata, pc_wdata, rs1_addr, rs1_rdata, rs1_def, rs2_addr,
                   rs2_rdata, rs2_def, rd_addr, rd_wdata, mem_addr, mem_rmask, mem_wmask,
                   mem_rdata, mem_wdata, trap, halt);
      where = $sformatf("%s: retirement #%0d pc %h insn %h", label, retired, pc_rdata, insn);
      if (s != RV_OK && s != RV_HALTED)
        `uvm_fatal("SB", $sformatf("%s: model status %0d (unsupported or bad address)", where, s))
      if (t.order != retired)
        `uvm_error("SB", $sformatf("%s: order %0d", where, t.order))
      if (t.trap != trap || t.halt != halt || t.intr)
        `uvm_error("SB", $sformatf("%s: trap/halt/intr core %0d%0d%0d model %0d%0d0",
                                   where, t.trap, t.halt, t.intr, trap, halt))
      if (t.insn != insn)           `uvm_error("SB", $sformatf("%s: insn core %h", where, t.insn))
      if (t.pc_rdata != pc_rdata)   `uvm_error("SB", $sformatf("%s: pc core %h", where, t.pc_rdata))
      if (!trap && t.pc_wdata != pc_wdata)
        `uvm_error("SB", $sformatf("%s: next pc core %h model %h", where, t.pc_wdata, pc_wdata))
      if (t.rs1_addr != rs1_addr || t.rs2_addr != rs2_addr)
        `uvm_error("SB", $sformatf("%s: rs addresses", where))
      if (rs1_def && t.rs1_rdata != rs1_rdata)
        `uvm_error("SB", $sformatf("%s: rs1 value core %h model %h", where, t.rs1_rdata, rs1_rdata))
      if (rs2_def && t.rs2_rdata != rs2_rdata)
        `uvm_error("SB", $sformatf("%s: rs2 value core %h model %h", where, t.rs2_rdata, rs2_rdata))
      rs_checked += rs1_def + rs2_def;
      if (t.rd_addr != rd_addr || t.rd_wdata != rd_wdata)
        `uvm_error("SB", $sformatf("%s: write core x%0d=%h model x%0d=%h",
                                   where, t.rd_addr, t.rd_wdata, rd_addr, rd_wdata))
      if (t.mem_rmask != mem_rmask || t.mem_wmask != mem_wmask)
        `uvm_error("SB", $sformatf("%s: masks core r%h w%h model r%h w%h",
                                   where, t.mem_rmask, t.mem_wmask, mem_rmask, mem_wmask))
      if ((mem_rmask || mem_wmask) && t.mem_addr != mem_addr)
        `uvm_error("SB", $sformatf("%s: mem addr core %h model %h", where, t.mem_addr, mem_addr))
      for (int i = 0; i < 4; i++) lanes[8*i +: 8] = {8{mem_rmask[i] | mem_wmask[i]}};
      if ((t.mem_rdata & lanes & {32{|mem_rmask}}) != (mem_rdata & lanes & {32{|mem_rmask}}))
        `uvm_error("SB", $sformatf("%s: load data core %h model %h", where, t.mem_rdata, mem_rdata))
      if ((t.mem_wdata & lanes & {32{|mem_wmask}}) != (mem_wdata & lanes & {32{|mem_wmask}}))
        `uvm_error("SB", $sformatf("%s: store data core %h model %h", where, t.mem_wdata, mem_wdata))
      retired++;
      total_retired++;
      if (s == RV_HALTED) model_halted = 1;
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("SB", $sformatf("%0d programs, %0d retirements compared with the model, %0d register reads checked",
                                checked_programs, total_retired, rs_checked), UVM_NONE)
    endfunction
  endclass

  // ------------------------------------------------------------- coverage --
  // One covergroup per group of docs/coverage-plan.md, each a single
  // coverpoint over that group's bins numbered 0..N-1, so a group's coverage
  // is exactly bins hit / bins. The collector also counts hits itself, under
  // the plan's names, to list what is missing -- and checks that its count
  // and the covergroups' agree.
  localparam int NGROUPS = 8;
  localparam int GROUP_BINS[NGROUPS] = '{40, 30, 9, 17, 59, 11, 32, 7};

  covergroup cg_g1 with function sample(int b); coverpoint b { bins b[] = {[0:39]}; } endgroup
  covergroup cg_g2 with function sample(int b); coverpoint b { bins b[] = {[0:29]}; } endgroup
  covergroup cg_g3 with function sample(int b); coverpoint b { bins b[] = {[0:8]};  } endgroup
  covergroup cg_g4 with function sample(int b); coverpoint b { bins b[] = {[0:16]}; } endgroup
  covergroup cg_g5 with function sample(int b); coverpoint b { bins b[] = {[0:58]}; } endgroup
  covergroup cg_g6 with function sample(int b); coverpoint b { bins b[] = {[0:10]}; } endgroup
  covergroup cg_g7 with function sample(int b); coverpoint b { bins b[] = {[0:31]}; } endgroup
  covergroup cg_g8 with function sample(int b); coverpoint b { bins b[] = {[0:6]};  } endgroup

  class rv_coverage extends uvm_subscriber #(rv_retire);
    `uvm_component_utils(rv_coverage)
    virtual core_if vif;
    rv_mem mem;
    cg_g1 g1; cg_g2 g2; cg_g3 g3; cg_g4 g4; cg_g5 g5; cg_g6 g6; cg_g7 g7; cg_g8 g8;
    int    hits[NGROUPS][];
    string names[NGROUPS][];
    rv_retire hist[$];                  // previous retirements, newest first

    function new(string name, uvm_component parent);
      super.new(name, parent);
      g1 = new(); g2 = new(); g3 = new(); g4 = new();
      g5 = new(); g6 = new(); g7 = new(); g8 = new();
      foreach (GROUP_BINS[g]) begin
        hits[g] = new[GROUP_BINS[g]];
        names[g] = new[GROUP_BINS[g]];
      end
      name_bins();
    endfunction

    function void hit(int g, int b);
      if (b < 0 || b >= GROUP_BINS[g]) `uvm_fatal("COV", $sformatf("group %0d bin %0d", g + 1, b))
      hits[g][b]++;
      case (g)
        0: g1.sample(b); 1: g2.sample(b); 2: g3.sample(b); 3: g4.sample(b);
        4: g5.sample(b); 5: g6.sample(b); 6: g7.sample(b); default: g8.sample(b);
      endcase
    endfunction

    function void name_bins();
      string ins[40] = '{"LUI", "AUIPC", "JAL", "JALR", "BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU",
                         "LB", "LH", "LW", "LBU", "LHU", "SB", "SH", "SW",
                         "ADDI", "SLTI", "SLTIU", "XORI", "ORI", "ANDI", "SLLI", "SRLI", "SRAI",
                         "ADD", "SUB", "SLL", "SLT", "SLTU", "XOR", "SRL", "SRA", "OR", "AND",
                         "FENCE", "ECALL", "EBREAK"};
      string src[4] = '{"EX/MEM", "MEM/WB", "WB->ID", "regfile"};
      string imms[5] = '{"0", "1", "-1", "2047", "-2048"};
      string corner4[4] = '{"0", "-1", "2047", "-2048"};
      foreach (ins[i]) names[0][i] = ins[i];
      for (int i = 0; i < 4; i++) begin
        names[1][i] = {"rs1 from ", src[i]};
        names[1][4 + i] = {"rs2 from ", src[i]};
        for (int j = 0; j < 4; j++) names[1][8 + 4 * i + j] = {"rs1 ", src[i], " x rs2 ", src[j]};
      end
      names[1][24] = "rs1=rs2 both from EX/MEM"; names[1][25] = "rs1=rs2 both from MEM/WB";
      names[1][26] = "rs1: EX/MEM and MEM/WB both write it"; names[1][27] = "rs2: same";
      names[1][28] = "rs1: load result from MEM/WB"; names[1][29] = "rs2: load result from MEM/WB";
      names[2][0] = "stall on rs1 only"; names[2][1] = "stall on rs2 only"; names[2][2] = "stall on both";
      names[2][3] = "stall after LB"; names[2][4] = "stall after LH"; names[2][5] = "stall after LW";
      names[2][6] = "stall after LBU"; names[2][7] = "stall after LHU";
      names[2][8] = "stalled instruction is a taken branch/jump";
      for (int i = 0; i < 6; i++) begin
        names[3][2 * i] = {ins[4 + i], " not taken"};
        names[3][2 * i + 1] = {ins[4 + i], " taken"};
      end
      names[3][12] = "JAL"; names[3][13] = "JALR";
      names[3][14] = "taken branch forward"; names[3][15] = "taken branch backward";
      names[3][16] = "taken branch followed by a branch (squashed)";
      for (int i = 0; i < 6; i++) for (int j = 0; j < 5; j++)
        names[4][5 * i + j] = {ins[18 + i], " imm ", imms[j]};
      for (int i = 0; i < 3; i++) begin
        names[4][30 + 3 * i] = {ins[24 + i], " shamt 0"};
        names[4][31 + 3 * i] = {ins[24 + i], " shamt 1"};
        names[4][32 + 3 * i] = {ins[24 + i], " shamt 31"};
      end
      for (int j = 0; j < 4; j++) begin
        names[4][39 + j] = {"load offset ", corner4[j]};
        names[4][43 + j] = {"store offset ", corner4[j]};
      end
      names[4][47] = "LUI 0";   names[4][48] = "LUI 0x80000";   names[4][49] = "LUI 0xFFFFF";
      names[4][50] = "AUIPC 0"; names[4][51] = "AUIPC 0x80000"; names[4][52] = "AUIPC 0xFFFFF";
      names[4][53] = "LB sign 0"; names[4][54] = "LB sign 1";
      names[4][55] = "LH sign 0"; names[4][56] = "LH sign 1";
      names[4][57] = "LBU top bit set"; names[4][58] = "LHU top bit set";
      for (int d = 0; d < 4; d++) begin
        names[5][d] = $sformatf("rs1 RAW at distance %s", d == 3 ? ">=4" : $sformatf("%0d", d + 1));
        names[5][4 + d] = $sformatf("rs2 RAW at distance %s", d == 3 ? ">=4" : $sformatf("%0d", d + 1));
      end
      names[5][8] = "WAW back to back"; names[5][9] = "chain of three";
      names[5][10] = "store data from the previous load";
      for (int k = 0; k < 4; k++) begin
        names[6][k] = $sformatf("LB @%0d", k); names[6][4 + k] = $sformatf("LBU @%0d", k);
        names[6][24 + k] = $sformatf("SB @%0d", k);
      end
      names[6][8] = "LH @0"; names[6][9] = "LH @2"; names[6][10] = "LHU @0"; names[6][11] = "LHU @2";
      names[6][12] = "LH @1 (trap)"; names[6][13] = "LH @3 (trap)";
      names[6][14] = "LHU @1 (trap)"; names[6][15] = "LHU @3 (trap)";
      names[6][16] = "LW @0"; names[6][17] = "LW @1 (trap)"; names[6][18] = "LW @2 (trap)"; names[6][19] = "LW @3 (trap)";
      names[6][20] = "SH @0"; names[6][21] = "SH @2"; names[6][22] = "SH @1 (trap)"; names[6][23] = "SH @3 (trap)";
      names[6][28] = "SW @0"; names[6][29] = "SW @1 (trap)"; names[6][30] = "SW @2 (trap)"; names[6][31] = "SW @3 (trap)";
      names[7][0] = "ECALL"; names[7][1] = "EBREAK"; names[7][2] = "misaligned load";
      names[7][3] = "misaligned store"; names[7][4] = "branch to misaligned target";
      names[7][5] = "JAL to misaligned target"; names[7][6] = "JALR to misaligned target";
    endfunction

    // --- white-box groups 2 and 3, sampled every cycle ---
    task run_phase(uvm_phase phase);
      bit stall_q, stall_qq;
      forever begin
        @(posedge vif.clk);
        if (vif.rst) begin
          stall_q = 0; stall_qq = 0;
          continue;
        end
        // Group 2: the instruction in EX. Nothing squashes an instruction
        // once it is in EX (a redirect flushes only the younger stages, and
        // no test resets mid-program), so each valid EX cycle is one
        // instruction that retires.
        if (vif.id_ex_valid) sample_forwarding();
        // Group 3: the stall cycle. The load is in EX and its consumer in ID;
        // a stall never coincides with a redirect (property S1), so the
        // consumer is not squashed and will retire.
        if (vif.stall) sample_stall();
        // The consumer reaches EX two cycles after the stall.
        if (stall_qq && vif.id_ex_valid && vif.redirect) hit(2, 8);
        stall_qq = stall_q;
        stall_q = vif.stall;
      end
    endtask

    function int src(bit ex_mem, bit mem_wb, bit bypass);
      return ex_mem ? 0 : mem_wb ? 1 : bypass ? 2 : 3;
    endfunction

    function void sample_forwarding();
      bit [31:0] in = vif.id_ex_instr;
      bit [4:0]  r1 = in[19:15], r2 = in[24:20];
      bit u1 = reads_rs1(in) && r1 != 0, u2 = reads_rs2(in) && r2 != 0;
      int s1 = src(vif.fwd_rs1_ex_mem, vif.fwd_rs1_mem_wb, vif.bypass_rs1);
      int s2 = src(vif.fwd_rs2_ex_mem, vif.fwd_rs2_mem_wb, vif.bypass_rs2);
      bit wb_load = vif.mem_wb_instr[6:0] == OP_LOAD;
      if (u1) hit(1, s1);
      if (u2) hit(1, 4 + s2);
      if (u1 && u2) hit(1, 8 + 4 * s1 + s2);
      if (u1 && u2 && r1 == r2 && s1 == s2 && s1 < 2) hit(1, 24 + s1);
      if (u1 && vif.ex_mem_rd_we && vif.ex_mem_rd_addr == r1 && vif.wb_rd_we && vif.wb_rd_addr == r1)
        hit(1, 26);
      if (u2 && vif.ex_mem_rd_we && vif.ex_mem_rd_addr == r2 && vif.wb_rd_we && vif.wb_rd_addr == r2)
        hit(1, 27);
      if (u1 && s1 == 1 && wb_load) hit(1, 28);
      if (u2 && s2 == 1 && wb_load) hit(1, 29);
    endfunction

    function void sample_stall();
      bit [31:0] ld = vif.id_ex_instr, c = vif.if_id_instr;
      bit [4:0]  rd = ld[11:7];
      bit m1 = reads_rs1(c) && c[19:15] == rd, m2 = reads_rs2(c) && c[24:20] == rd;
      if (m1 && !m2) hit(2, 0);
      if (m2 && !m1) hit(2, 1);
      if (m1 && m2)  hit(2, 2);
      case (ld[14:12])
        0: hit(2, 3); 1: hit(2, 4); 2: hit(2, 5); 4: hit(2, 6); 5: hit(2, 7);
        default: ;
      endcase
    endfunction

    // --- black-box groups, one sample per retirement ---
    function void write(rv_retire t);
      bit [31:0] in = t.insn;
      bit [6:0]  op = in[6:0];
      bit [2:0]  f3 = in[14:12];
      int        m = mnemonic(in);
      if (m >= 0) hit(0, m);

      // group 8: traps
      if (t.trap) begin
        if (in == ECALL) hit(7, 0);
        else if (in == EBREAK) hit(7, 1);
        else if (op == OP_LOAD) hit(7, 2);
        else if (op == OP_STORE) hit(7, 3);
        else if (op == OP_BRANCH) hit(7, 4);
        else if (op == OP_JAL) hit(7, 5);
        else if (op == OP_JALR) hit(7, 6);
      end

      // group 4: control flow (trapping transfers excluded: they never land)
      if (op == OP_BRANCH && !t.trap && f3 != 2 && f3 != 3) begin
        int idx = (f3 >= 4) ? f3 - 2 : f3;     // BEQ BNE BLT BGE BLTU BGEU -> 0..5
        bit taken = t.pc_wdata != t.pc_rdata + 4;
        hit(3, 2 * idx + taken);
        if (taken) begin
          bit [31:0] nx = mem.read(t.pc_rdata + 4);
          hit(3, imm_b(in) > 0 ? 14 : 15);
          if (nx[6:0] == OP_BRANCH) hit(3, 16);
        end
      end
      if (op == OP_JAL && !t.trap) hit(3, 12);
      if (op == OP_JALR && !t.trap) hit(3, 13);

      // group 5: immediates
      if (op == OP_IMM) begin
        int ii = imm_i(in);
        if (f3 == 1 || f3 == 5) begin
          int k = (f3 == 1) ? 0 : (in[30] ? 2 : 1);
          int sh = in[24:20];
          if (sh == 0) hit(4, 30 + 3 * k);
          if (sh == 1) hit(4, 31 + 3 * k);
          if (sh == 31) hit(4, 32 + 3 * k);
        end else begin
          int k = (m - 18);                        // ADDI..ANDI -> 0..5
          int c = (ii == 0) ? 0 : (ii == 1) ? 1 : (ii == -1) ? 2 : (ii == 2047) ? 3 : (ii == -2048) ? 4 : -1;
          if (c >= 0) hit(4, 5 * k + c);
        end
      end
      if (op == OP_LOAD || op == OP_STORE) begin
        int off = (op == OP_LOAD) ? imm_i(in) : imm_s(in);
        int c = (off == 0) ? 0 : (off == -1) ? 1 : (off == 2047) ? 2 : (off == -2048) ? 3 : -1;
        if (c >= 0) hit(4, (op == OP_LOAD ? 39 : 43) + c);
      end
      if (op == OP_LUI || op == OP_AUIPC) begin
        int base = (op == OP_LUI) ? 47 : 50;
        if (in[31:12] == 20'h0) hit(4, base);
        if (in[31:12] == 20'h80000) hit(4, base + 1);
        if (in[31:12] == 20'hFFFFF) hit(4, base + 2);
      end
      if (op == OP_LOAD && !t.trap) begin
        bit [31:0] a = t.rs1_rdata + imm_i(in);
        bit [31:0] w = t.mem_rdata >> (8 * a[1:0]);
        case (f3)
          0: hit(4, w[7] ? 54 : 53);
          1: hit(4, w[15] ? 56 : 55);
          4: if (w[7]) hit(4, 57);
          5: if (w[15]) hit(4, 58);
          default: ;
        endcase
      end

      // group 7: alignment, from the effective address (traps included)
      if (op == OP_LOAD || op == OP_STORE) begin
        bit [31:0] a = t.rs1_rdata + ((op == OP_LOAD) ? imm_i(in) : imm_s(in));
        int k = a[1:0];
        if (op == OP_LOAD) case (f3)
          0: hit(6, k);
          4: hit(6, 4 + k);
          1: hit(6, (k == 0) ? 8 : (k == 2) ? 9 : (k == 1) ? 12 : 13);
          5: hit(6, (k == 0) ? 10 : (k == 2) ? 11 : (k == 1) ? 14 : 15);
          2: hit(6, 16 + k);
          default: ;
        endcase
        else case (f3)
          0: hit(6, 24 + k);
          1: hit(6, (k == 0) ? 20 : (k == 2) ? 21 : (k == 1) ? 22 : 23);
          2: hit(6, 28 + k);
          default: ;
        endcase
      end

      // group 6: dependencies, in retirement order
      if (!t.trap) begin
        bit [4:0] r1 = in[19:15], r2 = in[24:20];
        if (reads_rs1(in) && r1 != 0) begin
          int d = distance(r1);
          if (d > 0) hit(5, (d >= 4) ? 3 : d - 1);
        end
        if (reads_rs2(in) && r2 != 0) begin
          int d = distance(r2);
          if (d > 0) hit(5, 4 + ((d >= 4) ? 3 : d - 1));
        end
        if (hist.size() > 0) begin
          rv_retire p = hist[0];
          if (t.rd_addr != 0 && p.rd_addr == t.rd_addr) hit(5, 8);
          if (hist.size() > 1 && p.rd_addr != 0 && reads_rs1(in) && r1 == p.rd_addr
              && hist[1].rd_addr != 0 && reads_rs1(p.insn) && p.insn[19:15] == hist[1].rd_addr)
            hit(5, 9);
          if (op == OP_STORE && p.insn[6:0] == OP_LOAD && p.rd_addr != 0 && r2 == p.rd_addr)
            hit(5, 10);
        end
      end
      hist.push_front(t);
      if (hist.size() > 8) void'(hist.pop_back());
    endfunction

    // Retirements back to the most recent writer of r; 0 if none in the
    // history window.
    function int distance(bit [4:0] r);
      foreach (hist[i]) if (hist[i].rd_addr == r) return i + 1;
      return 0;
    endfunction

    function void start_program();
      hist.delete();
    endfunction

    // Bins hit / bins defined, from the collector's own counts and from the
    // covergroups; the two must agree.
    function real total(output real from_cg, output int hit_bins, output int all_bins);
      real cg[NGROUPS];
      cg[0] = g1.get_coverage(); cg[1] = g2.get_coverage(); cg[2] = g3.get_coverage();
      cg[3] = g4.get_coverage(); cg[4] = g5.get_coverage(); cg[5] = g6.get_coverage();
      cg[6] = g7.get_coverage(); cg[7] = g8.get_coverage();
      hit_bins = 0; all_bins = 0; from_cg = 0;
      foreach (GROUP_BINS[g]) begin
        for (int b = 0; b < GROUP_BINS[g]; b++) if (hits[g][b] > 0) hit_bins++;
        all_bins += GROUP_BINS[g];
        from_cg += cg[g] * GROUP_BINS[g] / 100.0;
      end
      from_cg = 100.0 * from_cg / all_bins;
      return 100.0 * hit_bins / all_bins;
    endfunction

    function void report_phase(uvm_phase phase);
      real own, cg;
      int h, n;
      string missing = "";
      own = total(cg, h, n);
      foreach (GROUP_BINS[g]) begin
        int gh = 0;
        for (int b = 0; b < GROUP_BINS[g]; b++) if (hits[g][b] > 0) gh++;
        `uvm_info("COV", $sformatf("group %0d: %0d / %0d", g + 1, gh, GROUP_BINS[g]), UVM_NONE)
        for (int b = 0; b < GROUP_BINS[g]; b++) if (hits[g][b] == 0)
          missing = {missing, $sformatf("\n  group %0d: %s", g + 1, names[g][b])};
      end
      `uvm_info("COV", $sformatf("functional coverage %0d / %0d bins = %0.2f%% (covergroups: %0.2f%%)",
                                 h, n, own, cg), UVM_NONE)
      if (missing != "") `uvm_info("COV", {"unhit:", missing}, UVM_NONE)
      if ((own > cg ? own - cg : cg - own) > 0.01)
        `uvm_error("COV", "own count and covergroups disagree")
    endfunction
  endclass

  // ------------------------------------------------------------------ env --
  class rv_env extends uvm_env;
    `uvm_component_utils(rv_env)
    rv_agent      agt;
    rv_scoreboard sb;
    rv_coverage   cov;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      agt = rv_agent::type_id::create("agt", this);
      sb  = rv_scoreboard::type_id::create("sb", this);
      cov = rv_coverage::type_id::create("cov", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      agt.mon.ap.connect(sb.analysis_export);
      agt.mon.ap.connect(cov.analysis_export);
      cov.vif = agt.drv.vif;
      cov.mem = agt.mem;
      agt.drv.sb = sb;
      agt.drv.cov = cov;
    endfunction
  endclass

  // ---------------------------------------------------------------- tests --
  class rv_regress_test extends uvm_test;
    `uvm_component_utils(rv_regress_test)
    rv_env env;
    int    programs = 300;
    real   cov_min = 95.0;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = rv_env::type_id::create("env", this);
      void'($value$plusargs("PROGRAMS=%d", programs));
      void'($value$plusargs("COV_MIN=%f", cov_min));
    endfunction
    task run_phase(uvm_phase phase);
      rv_random_seq seq = rv_random_seq::type_id::create("seq");
      phase.raise_objection(this);
      seq.n = programs;
      seq.start(env.agt.sqr);
      phase.drop_objection(this);
    endtask
    function void check_phase(uvm_phase phase);
      real own, cg;
      int h, n;
      own = env.cov.total(cg, h, n);
      if (own < cov_min)
        `uvm_error("COV", $sformatf("coverage %0.2f%% is below the %0.1f%% target", own, cov_min))
    endfunction
  endclass

endpackage
