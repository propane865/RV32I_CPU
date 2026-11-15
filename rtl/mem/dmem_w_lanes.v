`timescale 1ns/1ns
// Store-side sub-word access rules for the data memory
//
// The data memory is a 32-bit-wide, single-port storage array, so a byte or
// halfword access is a masked operation on the word that contains it. Both
// implementations (dmem_behav.v and dmem_sram.v) are fed from this module and
// dmem_r_lanes.v, so a byte or halfword access means exactly the same thing in
// simulation and in the macros - there is no second copy of the rules to drift.
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
// What is left of the straddling question, after the exception path answered it.
//
// This file still resolves a straddling access to a truncated one, because that is
// what one port can do. It no longer has to worry about when that happens: a
// halfword access is legal only at an even address and a word only at a
// multiple of four (rtl/control.v rejects the other encodings as illegal,
// rtl/trap_unit.v raises load-address-misaligned or store-address-misaligned for
// the ones that are legal but badly aligned), so the highest legal word store starts
// at the last word of memory and no legal access can reach past it. A straddle is
// now unreachable by definition rather than by luck, and the truncation logic here
// is what makes that definition cheap to hold to.
//
// WHY THIS IS THE STORE SIDE
//
// The write mask has to be valid in the same cycle the array is written, so this
// is decoded from the access as it happens. The load side needs the same two
// fields one cycle later, because the word being read does not exist until then;
// that delay belongs to the caller (rtl/mem/dmem.v), not to the rules, which is
// why dmem_r_lanes.v takes the already-delayed fields.
module dmem_w_lanes(
    input  wire [1:0]  byte_off,   // addr[1:0]
    input  wire [1:0]  width,      // `MEM_B, `MEM_H or `MEM_W
    input  wire [31:0] w_data,     // store value, little endian
    output wire [3:0]  w_strb,     // byte lanes a store writes
    output wire [31:0] w_lanes     // the value each of those lanes receives
);
    `include "defines.vh"

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
endmodule
