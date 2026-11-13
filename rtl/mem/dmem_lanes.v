`timescale 1ns/1ns
// Sub-word access rules for the data memory - the one definition of them
//
// Both data memory implementations (dmem_behav.v and dmem_sram.v) instantiate
// this, so the behavioural model cannot drift away from what the macros do. It
// is pure combinational logic: it decides which byte lanes a store writes and
// which bytes a load reads, given the addressed 32-bit word.
//
// THE CONTRACT
//
//   A load or store is confined to the 32-bit word that contains its address.
//   addr[1:0] selects byte lanes inside that word and the access never crosses
//   into the neighbouring word. Consequences, all of them deliberate:
//
//     * SB / LB / LBU at any addr[1:0] are exact - one byte never straddles.
//     * LH / SH touch only the bytes of their own word. At addr[1:0] == 3 only
//       the top byte is in range, and it is the halfword's LOW byte - the value
//       travels with the address, so a truncated halfword store keeps w_data[7:0].
//     * LW / SW ignore addr[1:0] entirely: an unaligned word access is performed
//       on the word containing it.
//
//   This is pinned by Test 10 in tb/core_tb.v.
//
// WHY THIS AND NOT FULLY CORRECT BYTE-ADDRESSED BEHAVIOUR
//
// RV32I permits unaligned accesses, so a strictly conforming memory would let
// an access straddle a word. A single-port SRAM cannot: it reads or writes one
// word per cycle, so a straddling store would need two write cycles (a
// read-modify-write or a store buffer), which this core has no mechanism to
// issue. Encoding the macro's limitation once, here, means both models agree
// bit for bit and the behavioural simulation is testing the hardware that will
// actually be built - rather than simulating a memory the ASIC cannot be.
//
// This core is therefore NOT fully RV32I-conformant for unaligned accesses:
// they neither wrap nor trap, they are silently truncated to the addressed word.
// Any program that relies on a straddling access is out of contract, and the
// only honest fixes are to align accesses or add a trap. It is not detected
// here: there is no exception mechanism in this core at all.
//
// NOT COVERED BY THIS MODULE - read latency
//
// Agreement here is about *values*, not *timing*. The behavioural model reads
// combinationally, so load data is valid during the MEM stage; the macros
// register dout0, so load data arrives one cycle later, in WB. The sky130
// read port cannot be made combinational, so the ASIC build needs a core-level
// change (capture load data from the memory port at WB instead of registering it
// in MEM/WB) before the two builds are interchangeable. That is deliberately out
// of scope here; see the note in rtl/mem/dmem.v.
module dmem_lanes(
    input  wire [1:0]  byte_off,   // addr[1:0]
    input  wire [1:0]  width,      // `MEM_B, `MEM_H or `MEM_W
    input  wire        is_signed,  // funct3[2], sign-extends loads
    input  wire [31:0] w_data,     // store value, little endian
    input  wire [31:0] raw,        // the addressed word, as just read
    output wire [3:0]  w_strb,     // byte lanes a store writes
    output wire [31:0] w_lanes,    // the value each of those lanes receives
    output reg  [31:0] r_data      // the accessed field, sign or zero extended
);
    `include "defines.vh"

    // ---- store side -------------------------------------------------------
    //
    // The masked-lane trick: let the strobe pick which lanes land, so a byte or
    // halfword store needs no read-modify-write. But the value has to be positioned
    // to match the strobe - lane k must receive the value byte whose address is
    // word_base + k, which means shifting the value up by byte_off. Replicating it
    // unchanged across all four lanes, which is the obvious version, is wrong for
    // an unaligned halfword: it puts w_data[15:8] in the top lane when the byte at
    // that address is the halfword's low byte.
    //
    // A byte store replicates, because every lane would receive the same byte
    // anyway. A word store needs no shift: its strobe is all four lanes and the
    // address is already word aligned by definition of the contract above.
    assign w_strb =
        (width == `MEM_B) ? (4'b0001 << byte_off) :
        (width == `MEM_H) ? (4'b0011 << byte_off) :
        (width == `MEM_W) ? 4'b1111 : 4'b0000;

    wire [31:0] halfword_up = {16'h0000, w_data[15:0]} << {byte_off, 3'b000};

    assign w_lanes =
        (width == `MEM_B) ? {4{w_data[7:0]}} :
        (width == `MEM_H) ? halfword_up      :
                            w_data;

    // ---- load side --------------------------------------------------------
    //
    // The 16 bits starting at byte_off, brought down to bit 0 for extension.
    // A mux over the offset rather than a variable shift, because it states what
    // an out-of-contract access actually reads instead of leaving it to how a
    // shifter drops bits: at offset 3 a halfword reads the one byte in range and
    // zero fills the other. A word read bypasses this and takes raw whole.
    reg [15:0] field;
    always @(*) begin
        case (byte_off)
            2'd0:    field = raw[15:0];
            2'd1:    field = raw[23:8];
            2'd2:    field = raw[31:16];
            2'd3:    field = {8'h00, raw[31:24]};
            default: field = 16'h0000;   // unreachable, byte_off is 2 bits
        endcase
    end

    // The top bit of the selected field decides the fill, per LB/LBU, LH/LHU.
    always @(*) begin
        case (width)
            `MEM_B: r_data = is_signed ? {{24{field[7]}},  field[7:0]}
                                       : {24'h0,           field[7:0]};
            `MEM_H: r_data = is_signed ? {{16{field[15]}}, field[15:0]}
                                       : {16'h0,           field[15:0]};
            `MEM_W: r_data = raw;
            default: r_data = 32'h0;   // width 2'b11 is never generated
        endcase
    end
endmodule
