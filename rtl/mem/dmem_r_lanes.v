`timescale 1ns/1ns
// Load-side sub-word access rules for the data memory
//
// The other half of the rules defined in dmem_w_lanes.v: given the word the
// storage read, pick out the accessed field and extend it. The two halves are
// separate modules because they are evaluated one cycle apart - the write mask
// must be ready in the cycle the array is written, while the word being read only
// appears the cycle after the address was presented, so the fields describing that
// access have to be delayed by the same cycle to still describe it. rtl/mem/dmem.v
// does the delaying; this module is pure combinational rule, exactly like the
// store side, so neither memory implementation contains its own copy of what a
// halfword is.
//
// The access-width contract, including what an unaligned access reads, is written
// out in dmem_w_lanes.v.
module dmem_r_lanes(
    input  wire [1:0]  byte_off,   // addr[1:0] of the access raw belongs to
    input  wire [1:0]  width,      // and its width, delayed with it
    input  wire        is_signed,  // funct3[2], sign-extends loads
    input  wire [31:0] raw,        // the addressed word, as the storage read it
    output reg  [31:0] r_data      // the accessed field, sign or zero extended
);
    `include "defines.vh"

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
