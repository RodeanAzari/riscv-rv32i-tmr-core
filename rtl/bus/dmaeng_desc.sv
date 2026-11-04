// DMA engine descriptor sequencer (Phase G, buildplan 6.3): walks the ring
// from HEAD to TAIL, one descriptor at a time, in the order of DMA-Engine's
// QEMU device (qemu-device/dmaeng.c, step(); sw/model/dmaeng_model.py):
//
//   1. ring base not 4 KiB aligned, or RING_SIZE not a power of two in
//      [RING_SIZE_MIN, RING_SIZE_MAX]                  -> BAD_DESC
//   2. the descriptor reaches past 2^32 (RING_BASE_HI != 0) -> DMA_FAIL;
//      fetch it; a bus error                           -> DMA_FAIL
//   3. OWN clear                                       -> BAD_DESC
//      (1-3 write nothing to the ring and leave HEAD)
//   4. rsvd != 0 -> BAD_DESC; len 0 or > MAX_XFER -> BAD_LEN; src or dst
//      reaching past 2^32 -> DMA_FAIL; else copy, a bus error -> DMA_FAIL
//   5. write status, then flags with OWN cleared (DMA-Engine rule 5); a bus
//      error on either -> DMA_FAIL with HEAD left
//   6. HEAD advances; then the code from 4 stops the engine, or, with
//      DESC_IRQ, IRQ_STATUS.COMPLETION is set
//
// Addresses on this SoC are 32 bits (buildplan 6.3), so 2 and 4 catch what
// the model fails as out of range before any bus access. Every bus access
// goes through the transport (dmaeng_axi.sv) as a command; nothing here
// knows the bus. Waits for each write's response, so status is in memory
// before flags, and the copy before status.
//
// soft_rst_i (CTRL.RESET): a command in flight finishes, then the sequencer
// goes idle without reporting; the registers are already reset.

module dmaeng_desc
  import dmaeng_pkg::*;
#(
  parameter  int ADDR_W = 32,
  localparam int REG_W  = 32,
  localparam int LEN_W  = $clog2(MAX_XFER_DEFAULT + 1),
  localparam int CODE_W = $bits(ERR_OK)
) (
  input  logic              clk_i,
  input  logic              rst_i,

  // registers (dmaeng_regs)
  input  logic              run_i,
  input  logic              soft_rst_i,
  input  logic [REG_W-1:0]  ring_base_lo_i,
  input  logic [REG_W-1:0]  ring_base_hi_i,
  input  logic [REG_W-1:0]  ring_size_i,
  input  logic [REG_W-1:0]  head_i,
  output logic              head_adv_o,
  output logic              done_irq_o,
  output logic              err_o,
  output logic [CODE_W-1:0] err_code_o,

  // transport (dmaeng_axi)
  output logic              cmd_valid_o,
  input  logic              cmd_ready_i,
  output logic [1:0]        cmd_op_o,
  output logic [ADDR_W-1:0] cmd_src_o,
  output logic [ADDR_W-1:0] cmd_dst_o,
  output logic [LEN_W-1:0]  cmd_len_o,
  output logic [REG_W-1:0]  cmd_wdata_o,
  output logic              abort_o,
  input  logic              rd_valid_i,
  input  logic [REG_W-1:0]  rd_data_i,
  input  logic              done_i,
  input  logic              done_err_i
);

  localparam logic [1:0] OP_READ  = 2'd0;
  localparam logic [1:0] OP_WRITE = 2'd1;
  localparam logic [1:0] OP_COPY  = 2'd2;

  // Descriptor layout, in words (spec/dmaeng.yaml `descriptor`; the package
  // does not carry the offsets, the C header does, and the testbench builds
  // descriptors from the header).
  localparam int DESC_WORDS = DESC_SIZE / 4;
  localparam int W_SRC_LO = 0, W_SRC_HI = 1, W_DST_LO = 2, W_DST_HI = 3;
  localparam int W_LEN = 4, W_FLAGS = 5, W_STATUS = 6, W_RSVD = 7;
  localparam int WORD_IDX_W = $clog2(DESC_WORDS);
  localparam int RING_ALIGN_W = $clog2(RING_ALIGN);
  localparam int DESC_SHIFT = $clog2(DESC_SIZE);

  typedef enum logic [2:0] {
    S_IDLE, S_CHECK, S_FETCH, S_DECODE, S_COPY, S_STATUS, S_FLAGS, S_REPORT
  } state_t;
  state_t state_q;

  logic                  issued_q;     // this state's command was taken
  logic                  abort_q;
  logic [REG_W-1:0]      desc_q [DESC_WORDS];
  logic [WORD_IDX_W-1:0] word_q;
  logic [ADDR_W-1:0]     desc_addr_q;
  logic [CODE_W-1:0]     code_q;       // the descriptor's status
  logic                  stop_q;       // report an error without HEAD (1-3, 5)

  // --- checks ------------------------------------------------------------------
  // 1. the ring
  logic ring_bad;
  assign ring_bad = ring_base_lo_i[RING_ALIGN_W-1:0] != '0 ||
                    (ring_size_i & (ring_size_i - 1'b1)) != '0 ||
                    ring_size_i < RING_SIZE_MIN || ring_size_i > RING_SIZE_MAX;

  // 2. the descriptor's address; an access [a, a + n) fails past 2^32
  logic [REG_W:0] desc_end;
  assign desc_end = {1'b0, ring_base_lo_i} + {1'b0, head_i << DESC_SHIFT} +
                    (REG_W + 1)'(DESC_SIZE);
  logic desc_unmapped;
  assign desc_unmapped = ring_base_hi_i != '0 ||
                         (desc_end[REG_W] && desc_end[REG_W-1:0] != '0);

  // 4. the descriptor
  logic [REG_W-1:0] d_len, d_flags;
  assign d_len   = desc_q[W_LEN];
  assign d_flags = desc_q[W_FLAGS];
  logic [REG_W:0] src_end, dst_end;
  assign src_end = {1'b0, desc_q[W_SRC_LO]} + {1'b0, d_len};
  assign dst_end = {1'b0, desc_q[W_DST_LO]} + {1'b0, d_len};
  logic out_of_range;
  assign out_of_range = desc_q[W_SRC_HI] != '0 || desc_q[W_DST_HI] != '0 ||
                        (src_end[REG_W] && src_end[REG_W-1:0] != '0) ||
                        (dst_end[REG_W] && dst_end[REG_W-1:0] != '0);
  logic [CODE_W-1:0] desc_code;
  always_comb begin
    if (desc_q[W_RSVD] != '0)                      desc_code = ERR_BAD_DESC;
    else if (d_len == '0 || d_len > MAX_XFER_DEFAULT) desc_code = ERR_BAD_LEN;
    else if (out_of_range)                          desc_code = ERR_DMA_FAIL;
    else                                            desc_code = ERR_OK;
  end

  // --- transport commands --------------------------------------------------------
  logic in_cmd_state;
  assign in_cmd_state = state_q == S_FETCH || state_q == S_COPY ||
                        state_q == S_STATUS || state_q == S_FLAGS;
  assign cmd_valid_o = in_cmd_state && !issued_q && !abort_q;
  assign abort_o     = abort_q;

  always_comb begin
    cmd_op_o    = OP_READ;
    cmd_src_o   = desc_addr_q;
    cmd_dst_o   = desc_q[W_DST_LO];
    cmd_len_o   = LEN_W'(DESC_SIZE);
    cmd_wdata_o = '0;
    unique case (state_q)
      S_COPY: begin
        cmd_op_o  = OP_COPY;
        cmd_src_o = desc_q[W_SRC_LO];
        cmd_len_o = LEN_W'(d_len);
      end
      S_STATUS: begin
        cmd_op_o    = OP_WRITE;
        cmd_src_o   = desc_addr_q + ADDR_W'(W_STATUS * 4);
        cmd_wdata_o = REG_W'(code_q);
      end
      S_FLAGS: begin
        cmd_op_o    = OP_WRITE;
        cmd_src_o   = desc_addr_q + ADDR_W'(W_FLAGS * 4);
        cmd_wdata_o = d_flags & ~(REG_W'(1) << DESC_OWN_BIT);
      end
      default: ;
    endcase
  end

  // --- reports to the registers --------------------------------------------------
  logic reporting;
  assign reporting  = state_q == S_REPORT && !abort_q && !soft_rst_i;
  assign head_adv_o = reporting && !stop_q;
  assign err_o      = reporting && (stop_q || code_q != ERR_OK);
  assign err_code_o = code_q;
  assign done_irq_o = reporting && !stop_q && code_q == ERR_OK &&
                      d_flags[DESC_IRQ_BIT];

  // --- sequencer -----------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rd_valid_i) begin
      desc_q[word_q] <= rd_data_i;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q     <= S_IDLE;
      issued_q    <= 1'b0;
      abort_q     <= 1'b0;
      word_q      <= '0;
      desc_addr_q <= '0;
      code_q      <= ERR_OK;
      stop_q      <= 1'b0;
    end else begin
      if (soft_rst_i) abort_q <= 1'b1;
      if (rd_valid_i) word_q <= word_q + 1'b1;
      if (cmd_valid_o && cmd_ready_i) issued_q <= 1'b1;

      if (abort_q && (!issued_q || done_i)) begin
        // nothing of ours on the bus: drop the descriptor, report nothing
        state_q  <= S_IDLE;
        issued_q <= 1'b0;
        abort_q  <= 1'b0;
      end else begin
        unique case (state_q)
          S_IDLE: if (run_i && !soft_rst_i) begin
            stop_q  <= 1'b0;
            code_q  <= ERR_OK;
            state_q <= S_CHECK;
          end
          S_CHECK: begin
            desc_addr_q <= ring_base_lo_i + (head_i << DESC_SHIFT);
            word_q      <= '0;
            if (ring_bad) begin
              code_q <= ERR_BAD_DESC;
              stop_q <= 1'b1;
              state_q <= S_REPORT;
            end else if (desc_unmapped) begin
              code_q <= ERR_DMA_FAIL;
              stop_q <= 1'b1;
              state_q <= S_REPORT;
            end else begin
              state_q <= S_FETCH;
            end
          end
          S_FETCH: if (done_i) begin
            issued_q <= 1'b0;
            if (done_err_i) begin
              code_q <= ERR_DMA_FAIL;
              stop_q <= 1'b1;
              state_q <= S_REPORT;
            end else begin
              state_q <= S_DECODE;
            end
          end
          S_DECODE: begin
            if (!d_flags[DESC_OWN_BIT]) begin
              code_q <= ERR_BAD_DESC;
              stop_q <= 1'b1;
              state_q <= S_REPORT;
            end else begin
              code_q  <= desc_code;
              state_q <= desc_code == ERR_OK ? S_COPY : S_STATUS;
            end
          end
          S_COPY: if (done_i) begin
            issued_q <= 1'b0;
            if (done_err_i) code_q <= ERR_DMA_FAIL;
            state_q <= S_STATUS;
          end
          S_STATUS: if (done_i) begin
            issued_q <= 1'b0;
            if (done_err_i) begin
              code_q <= ERR_DMA_FAIL;
              stop_q <= 1'b1;
              state_q <= S_REPORT;
            end else begin
              state_q <= S_FLAGS;
            end
          end
          S_FLAGS: if (done_i) begin
            issued_q <= 1'b0;
            if (done_err_i) begin
              code_q <= ERR_DMA_FAIL;
              stop_q <= 1'b1;
            end
            state_q <= S_REPORT;
          end
          S_REPORT: state_q <= S_IDLE;
          default:  state_q <= S_IDLE;
        endcase
      end
    end
  end

endmodule
