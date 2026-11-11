// Dual-port RAM for the board top: one image holding both the program and
// its data, so string constants in .rodata are loadable as well as the code
// fetchable. Port A is instruction fetch (read only), port B the core's data
// port (read, byte-strobed write).
//
// Coded to Vivado's true-dual-port block RAM template: both ports synchronous
// read with one cycle of latency, which is the timing the core's memory ports
// were built for. Port B is read-first: a load and a store to the same word
// in one cycle cannot happen (one data port), so the mode never shows.
//
// INIT_FILE is a $readmemh image, one 32-bit word per line -- `make sw`
// writes sw/prog.hex in that form. The initial block is the one CLAUDE.md 3
// allows in rtl/: block RAM initialisation, which the bitstream carries.
//
// SKY130_SRAM (defined only by the ASIC flow, syn/asic_soc.yaml): the words
// are sky130 OpenRAM macros instead, 1rw + 1r: 2 KiB (512 x 32) macros when
// WORDS is a multiple of 512, else 1 KiB (256 x 32). Port B is the macros'
// rw port 0, port A their read port 1; only the addressed macro is selected
// and its read word returned the next cycle, as above. Differences from the
// FPGA RAM, none of which the SoC relies on: no INIT_FILE (an ASIC needs a
// boot ROM, not built), port B's read word is undefined the cycle after a
// write (write-only, not read-first), and a read on A of the word B writes
// in the same cycle is undefined. Checked against the FPGA RAM by
// `make sram-check`.
module ram_dp #(
    parameter int unsigned WORDS     = 8192,   // 32 KiB
    parameter string       INIT_FILE = ""
) (
    input  logic                     clk_i,

    input  logic [$clog2(WORDS)-1:0] a_addr_i,
    output logic [31:0]              a_rdata_o,

    input  logic [$clog2(WORDS)-1:0] b_addr_i,
    input  logic [3:0]               b_we_i,
    input  logic [31:0]              b_wdata_i,
    output logic [31:0]              b_rdata_o
);

`ifdef SKY130_SRAM
  localparam int unsigned MW   = WORDS % 512 == 0 ? 512 : 256;   // words a macro
  localparam int unsigned NM   = WORDS / MW;                     // macros
  localparam int unsigned AW   = $clog2(WORDS);
  localparam int unsigned MAW  = $clog2(MW);
  localparam int unsigned SELW = NM > 1 ? $clog2(NM) : 1;

  if (WORDS % MW != 0 || NM > 1 && 2 ** $clog2(NM) != NM) begin : g_bad
    $error("ram_dp: SKY130_SRAM needs WORDS a power-of-two multiple of 256");
  end

  logic [SELW-1:0] a_sel, b_sel, a_sel_q, b_sel_q;
  logic [NM-1:0][31:0] a_dout, b_dout;

  if (NM > 1) begin : g_sel
    assign a_sel = a_addr_i[AW-1:MAW];
    assign b_sel = b_addr_i[AW-1:MAW];
  end else begin : g_one
    assign a_sel = '0;
    assign b_sel = '0;
  end

  always_ff @(posedge clk_i) begin
    a_sel_q <= a_sel;
    b_sel_q <= b_sel;
  end

  assign a_rdata_o = a_dout[a_sel_q];
  assign b_rdata_o = b_dout[b_sel_q];

  for (genvar m = 0; m < NM; m++) begin : g_m
    logic a_csb, b_csb;
    assign a_csb = a_sel != SELW'(m);
    assign b_csb = b_sel != SELW'(m);
    if (MW == 512) begin : g_2k
      sky130_sram_2kbyte_1rw1r_32x512_8 u_sram (
          .clk0   (clk_i),
          .csb0   (b_csb),
          .web0   (~|b_we_i),
          .wmask0 (b_we_i),
          .addr0  (b_addr_i[MAW-1:0]),
          .din0   (b_wdata_i),
          .dout0  (b_dout[m]),
          .clk1   (clk_i),
          .csb1   (a_csb),
          .addr1  (a_addr_i[MAW-1:0]),
          .dout1  (a_dout[m])
      );
    end else begin : g_1k
      sky130_sram_1kbyte_1rw1r_32x256_8 u_sram (
          .clk0   (clk_i),
          .csb0   (b_csb),
          .web0   (~|b_we_i),
          .wmask0 (b_we_i),
          .addr0  (b_addr_i[MAW-1:0]),
          .din0   (b_wdata_i),
          .dout0  (b_dout[m]),
          .clk1   (clk_i),
          .csb1   (a_csb),
          .addr1  (a_addr_i[MAW-1:0]),
          .dout1  (a_dout[m])
      );
    end
  end
`else
  logic [31:0] mem [WORDS];

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk_i) begin
    a_rdata_o <= mem[a_addr_i];
  end

  always_ff @(posedge clk_i) begin
    for (int i = 0; i < 4; i++) begin
      if (b_we_i[i]) mem[b_addr_i][8*i +: 8] <= b_wdata_i[8*i +: 8];
    end
    b_rdata_o <= mem[b_addr_i];
  end
`endif

endmodule
