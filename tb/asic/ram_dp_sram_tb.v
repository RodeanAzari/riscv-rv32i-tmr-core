// ram_dp built with SKY130_SRAM (the ASIC flow's memories, OpenRAM macros)
// against a reference memory with ram_dp's own contract: both ports read the
// addressed word one cycle later, port B writes the bytes b_we selects. Run
// by `make sram-check` (Verilator --timing, the PDK's OpenRAM behavioural
// models; Icarus rejects them, they use `mem` before declaring it).
//
// Random reads on A and reads or byte writes on B every cycle, B's address
// biased to A's macro and word so same-macro and same-word cycles happen.
// Not checked, where the contract leaves them undefined (ram_dp.sv header):
// B's read word the cycle after a write, A's read of the word B writes in
// that cycle, and bytes never written. Every cycle the read words are
// compared; the counts of checked reads per port must be nonzero, and every
// macro must have been read on both ports.
`timescale 1ns / 1ps
module ram_dp_sram_tb;
  parameter integer WORDS = 8192;
  parameter integer CYCLES = 40000;
  localparam integer AW = $clog2(WORDS);
  localparam integer MW = WORDS % 512 == 0 ? 512 : 256;
  localparam integer NM = WORDS / MW;

  reg clk = 0;
  always #10 clk = ~clk;   // 20 ns: the models' read data lands 3 ns after the falling edge

  reg  [AW-1:0] a_addr, b_addr;
  reg  [3:0]    b_we;
  reg  [31:0]   b_wdata;
  wire [31:0]   a_rdata, b_rdata;

  ram_dp #(.WORDS(WORDS)) dut (
      .clk_i(clk), .a_addr_i(a_addr), .a_rdata_o(a_rdata),
      .b_addr_i(b_addr), .b_we_i(b_we), .b_wdata_i(b_wdata), .b_rdata_o(b_rdata)
  );

  reg [31:0] ref_mem [0:WORDS-1];
  reg [3:0]  ref_ok  [0:WORDS-1];   // bytes written at least once

  // what the previous cycle asked for
  reg [31:0] a_exp, b_exp;
  reg [3:0]  a_mask, b_mask;
  reg        a_chk, b_chk;

  integer i, n, errors, a_n, b_n, seed;
  integer a_hit [0:NM-1];
  integer b_hit [0:NM-1];

  function [31:0] bytemask(input [3:0] m);
    bytemask = {{8{m[3]}}, {8{m[2]}}, {8{m[1]}}, {8{m[0]}}};
  endfunction

  initial begin
    errors = 0; a_n = 0; b_n = 0; seed = 1;
    for (i = 0; i < WORDS; i = i + 1) ref_ok[i] = 0;
    for (i = 0; i < NM; i = i + 1) begin a_hit[i] = 0; b_hit[i] = 0; end
    a_chk = 0; b_chk = 0;
    a_addr = 0; b_addr = 0; b_we = 0; b_wdata = 0;

    for (n = 0; n < CYCLES; n = n + 1) begin
      // drive this cycle's requests away from the clock edge
      @(negedge clk);
      a_addr = $random(seed);
      case ($unsigned($random(seed)) % 4)
        0: b_addr = a_addr;                                   // same word
        1: b_addr = (a_addr & ~(MW - 1)) | ($random(seed) & (MW - 1));  // same macro
        default: b_addr = $random(seed);
      endcase
      if (n < WORDS) begin                                    // fill every word first
        b_addr = n; b_we = 4'hF;
      end else
        b_we = ($unsigned($random(seed)) % 2) ? $random(seed) : 4'h0;
      b_wdata = $random(seed);

      // just before the edge: check what the previous cycle's reads returned
      #9;
      if (a_chk && ((a_rdata ^ a_exp) & bytemask(a_mask)) !== 0) begin
        errors = errors + 1;
        if (errors < 10) $display("cycle %0d: A read %h, expected %h (mask %b)", n, a_rdata, a_exp, a_mask);
      end
      if (b_chk && ((b_rdata ^ b_exp) & bytemask(b_mask)) !== 0) begin
        errors = errors + 1;
        if (errors < 10) $display("cycle %0d: B read %h, expected %h (mask %b)", n, b_rdata, b_exp, b_mask);
      end
      a_n = a_n + (a_chk && a_mask != 0);
      b_n = b_n + (b_chk && b_mask != 0);

      // this cycle's expectations, then its write into the reference
      a_exp  = ref_mem[a_addr];
      a_mask = ref_ok[a_addr];
      a_chk  = !(b_we != 0 && b_addr == a_addr);
      b_exp  = ref_mem[b_addr];
      b_mask = ref_ok[b_addr];
      b_chk  = b_we == 0;
      if (a_chk && a_mask != 0) a_hit[a_addr / MW] = a_hit[a_addr / MW] + 1;
      if (b_chk && b_mask != 0) b_hit[b_addr / MW] = b_hit[b_addr / MW] + 1;
      for (i = 0; i < 4; i = i + 1)
        if (b_we[i]) begin
          ref_mem[b_addr][8*i +: 8] = b_wdata[8*i +: 8];
          ref_ok[b_addr][i] = 1'b1;
        end
    end

    for (i = 0; i < NM; i = i + 1)
      if (a_hit[i] == 0 || b_hit[i] == 0) begin
        errors = errors + 1;
        $display("macro %0d never read on both ports (A %0d, B %0d)", i, a_hit[i], b_hit[i]);
      end
    if (errors == 0 && a_n > 0 && b_n > 0)
      $display("sram-check: WORDS=%0d (%0d x %0d-word macros) ok, %0d A reads and %0d B reads checked",
               WORDS, NM, MW, a_n, b_n);
    else
      $display("sram-check: WORDS=%0d FAILED, %0d errors", WORDS, errors);
    $finish;
  end
endmodule
