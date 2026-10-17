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

endmodule
