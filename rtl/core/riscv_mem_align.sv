// Byte-lane alignment for loads and stores.
//
// The data memory is 32 bits wide and word-addressed: it always moves a whole
// word, and the low two address bits pick which byte lanes within it matter.
//
//   Store side (used in MEM): place rs2's low byte/half in the addressed lane
//   and raise the matching byte strobes.
//   Load side (used in WB):   pick the addressed lane out of the returned word,
//   then sign- or zero-extend it to 32 bits.
//
// The two halves sit in different pipeline stages but live in one module on
// purpose: they must agree on the lane convention (byte 0 is bits [7:0] --
// little-endian, as RISC-V requires), and keeping both sides in one file means
// there is only one place for that convention to be wrong.
//
// Misaligned accesses are ASSUMED NOT TO HAPPEN (decided 2026-10-07, see
// docs/PROGRESS.md). Address bits below the access size are ignored: LW/SW
// ignore addr[1:0], LH/LHU/SH ignore addr[0]. So a misaligned access touches
// the naturally aligned word or halfword containing it -- deterministic, never
// split across two words. Phase B has to tell riscv-formal about this
// assumption; check what its RISCV_FORMAL_ALIGNED_MEM option expects of a
// misaligned access (it may expect rvfi_trap) before relying on it -- otherwise
// constrain the harness to aligned addresses.
//
// No XLEN parameter: four byte lanes and two address bits are RV32-specific,
// and a parameter here would advertise a generality the logic does not have.
//
// funct3 encodes both width and signedness:
//
//   funct3[1:0]  00 byte   01 half   10 word
//   funct3[2]    1 = zero-extend (LBU, LHU)
//
// Stores have no signed/unsigned variant, so the store side takes only the
// two size bits.
//
// The reserved encodings (011, 110, 111) fall through to word. RV32I has no
// trap to raise for them (§5.1), and decoding them inert would cost logic to
// police instructions a compiler never emits.
module riscv_mem_align (
    // Store side -- MEM stage
    input  logic [1:0]  st_size_i,
    input  logic [1:0]  st_addr_lo_i,
    input  logic [31:0] st_data_i,
    output logic [31:0] st_wdata_o,
    output logic [3:0]  st_wstrb_o,

    // Load side -- WB stage
    input  logic [2:0]  ld_funct3_i,
    input  logic [1:0]  ld_addr_lo_i,
    input  logic [31:0] ld_rdata_i,
    output logic [31:0] ld_data_o
);

  localparam logic [1:0] SIZE_B = 2'b00;
  localparam logic [1:0] SIZE_H = 2'b01;

  // ------------------------------------------------------------- store -----
  // The data is replicated into every lane rather than shifted into one. The
  // strobes decide which lanes the memory actually writes, so the copies in the
  // other lanes are never stored -- and replication is free wiring, where a
  // shifter is a mux per bit.
  always_comb begin
    case (st_size_i)
      SIZE_B: begin
        st_wdata_o = {4{st_data_i[7:0]}};
        st_wstrb_o = 4'b0001 << st_addr_lo_i;
      end
      SIZE_H: begin
        st_wdata_o = {2{st_data_i[15:0]}};
        st_wstrb_o = st_addr_lo_i[1] ? 4'b1100 : 4'b0011;
      end
      default: begin
        st_wdata_o = st_data_i;
        st_wstrb_o = 4'b1111;
      end
    endcase
  end

  // -------------------------------------------------------------- load -----
  logic [7:0]  ld_byte;
  logic [15:0] ld_half;
  logic        ld_signed;

  always_comb begin
    case (ld_addr_lo_i)
      2'd0:    ld_byte = ld_rdata_i[7:0];
      2'd1:    ld_byte = ld_rdata_i[15:8];
      2'd2:    ld_byte = ld_rdata_i[23:16];
      default: ld_byte = ld_rdata_i[31:24];
    endcase
  end

  assign ld_half   = ld_addr_lo_i[1] ? ld_rdata_i[31:16] : ld_rdata_i[15:0];
  assign ld_signed = !ld_funct3_i[2];

  // LB and LBU (likewise LH and LHU) select the same lane and differ ONLY in
  // the fill bits. While the loaded value is positive the two are
  // indistinguishable, so a swapped or missing sign extension passes every test
  // that never loads a byte with bit 7 set.
  always_comb begin
    case (ld_funct3_i[1:0])
      SIZE_B:  ld_data_o = {{24{ld_signed && ld_byte[7]}},  ld_byte};
      SIZE_H:  ld_data_o = {{16{ld_signed && ld_half[15]}}, ld_half};
      default: ld_data_o = ld_rdata_i;
    endcase
  end

endmodule
