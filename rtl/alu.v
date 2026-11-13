`timescale 1ns/1ns
// ALU
//
// Interface note. This ALU previously took `cin`, `invert` and `pass` alongside
// `op`, and a single `invert` bit meant three unrelated things depending on the
// operation: bitwise-NOT of input B for SUB, shift *direction* for the shifts
// (so SRL was encoded as "shift left, inverted"), and result polarity for the
// comparison. It was passed to the shifter positionally, so nothing at the
// instantiation said which meaning was in play.
//
// Now `op` alone determines everything: SUB, the two right shifts and the
// arithmetic shift are their own operation codes, and the ALU derives the
// b-invert, the carry-in and the shifter's direction/signedness internally.
// The op encoding lives in defines.vh and is four bits wide.
//
// Comparison signedness is deliberately not an ALU input: comp32 does the
// signed/unsigned decision one stage earlier and hands the ALU a plain "a < b".
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,      // shift amount is taken from b[4:0]
    input  wire [3:0]  op,
    input  wire        lt,     // a < b from the comparator, signedness applied
    output reg  [31:0] out
);
    `include "defines.vh"

    wire is_sub = (op == `ALU_SUB);

    // SUB is executed as a + ~b + 1.
    wire [31:0] b_alu = is_sub ? ~b : b;
    wire        cin   = is_sub;

    wire [31:0] sum;
    wire [31:0] shifted;

    shifter SHIFTER (
        .a     (a),
        .b     (b[4:0]),
        .arith (op == `ALU_SHA),                        // sign-fill, or zero-fill
        .dir   ((op == `ALU_SHR) || (op == `ALU_SHA)),  // 0 = left, 1 = right
        .shift (shifted)
    );

    // The carry out is not consumed by any operation, so it is left unconnected.
    ks32 ADDER (
        .a    (a),
        .b    (b_alu),
        .cin  (cin),
        .sum  (sum),
        .cout ()
    );

    always @(*) begin
        case (op)
            `ALU_AND:  out = a & b;
            `ALU_OR:   out = a | b;
            `ALU_XOR:  out = a ^ b;
            `ALU_ADD:  out = sum;
            `ALU_SUB:  out = sum;
            `ALU_SHL:  out = shifted;
            `ALU_SHR:  out = shifted;
            `ALU_SHA:  out = shifted;
            `ALU_CMP:  out = {31'h0, lt};
            `ALU_PASS: out = a;        // LUI: the immediate is already shifted
            // Encodings 10..15 are never emitted by control.v.
            default:   out = 32'h0;
        endcase
    end
endmodule
