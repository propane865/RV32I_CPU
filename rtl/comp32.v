`timescale 1ns/1ns
// 32-bit magnitude comparator: gt / lt / eq of a versus b.
//
// Built from a subtraction (a + ~b + 1), so it costs one adder. Signedness is
// an input: the unsigned case reads the carry out of that subtraction, the
// signed case has to correct for the operand signs.
//
// This is the only place in the core that knows how signed comparison works, so
// every consumer - SLT/SLTI/SLTU/SLTIU and the four ordering branches - must be
// told which comparison it wants via `u`. Equality (BEQ/BNE) does not depend on
// it, so a missing assignment only ever breaks the ordering forms.
module comp32(input [31:0] a, b, input u, output reg gt, lt, eq);
    wire [31:0] sub_out;
    wire cout;

    ks32 sub(a, ~b, 1'b1, sub_out, cout);

    wire sgn_a, sgn_b, sgn_s;
    wire eq_sgn, eq_w;

    assign sgn_a = a[31];
    assign sgn_b = b[31];
    assign sgn_s = sub_out[31];
    assign eq_w = ~|sub_out;

    assign eq_sgn = sgn_a ~^ sgn_b;

    always @(*) begin
        eq = eq_w;
        case (u)
            1'b1: begin
                gt = cout & ~eq_w;
                lt = ~cout & ~eq_w;
            end
            1'b0: begin
                case (eq_sgn)
                    1'b0: begin
                        gt = ~sgn_a;
                        lt = sgn_a;
                    end
                    1'b1: begin
                        gt = ~sgn_s & ~eq;
                        lt = sgn_s & ~eq;
                    end
                endcase
            end 
        endcase
    end
endmodule
