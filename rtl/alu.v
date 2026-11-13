// ALU

/*
Input A:                    | a
--------------------------------------
Input B:                    | b
--------------------------------------
Carry In:                   | cin
--------------------------------------
Enable Passthrough:         | pass
--------------------------------------
Enable Invert Operation:    | invert
--------------------------------------
Enable Signed Comparison:   | sgn
--------------------------------------
Operation Type:             | op
--------------------------------------
Output:                     | out
--------------------------------------
Carry Out:                  | cout
*/

module alu(input [31:0] a, b, input cin, input pass, input invert, input [2:0] op, input gt, lt, eq, output reg [31:0] out, output cout);
    `include "defines.vh"

    wire [31:0] a_cmp, b_cmp, a_shift, a_b_add, a_xor_b, a_or_b, a_and_b;

    reg [31:0] logic_out;

    // Invert inputs if the invert input is enabled
    assign a_cmp = invert ? ~a : a;
    assign b_cmp = invert ? ~b : b;

    // Instantiate shifter, CLA, and comparator
    shifter sh(a, b[4:0], op[0], invert, a_shift);
    ks32 add(a, b_cmp, cin, a_b_add, cout);

    // Compute logical operations
    assign a_xor_b = a ^ b;
    assign a_or_b = a | b;
    assign a_and_b = a & b;

    always @(*) begin
        // Choose the output depending on the selected ALU operation
        case (op)
            `ALU_AND: logic_out = a_and_b;
            `ALU_OR:  logic_out = a_or_b;
            `ALU_XOR: logic_out = a_xor_b;
            `ALU_ADD: logic_out = a_b_add;
            `ALU_SHL: logic_out = a_shift;
            `ALU_SHA: logic_out = a_shift;
            `ALU_CMP: logic_out = {31'b0, invert ? gt : lt};
            3'b111:   logic_out = {31'b0, eq ^ invert};  // DEAD: control never emits this
            default: logic_out = 32'h0;
        endcase

        // Passthrough input A (potentially inverted) if the pass input is enabled
        case (pass)
            1'b0: out = logic_out;
            1'b1: out = a_cmp;
        endcase
    end
endmodule

module ks32(input [31:0] a, b, input cin, output [31:0] sum, output cout);
    wire [31:0] g0, p0;
    assign g0 = a & b;
    assign p0 = a ^ b;

    wire [31:0] g1, g2, g3, g4, g5;
    wire [31:0] p1, p2, p3, p4, p5;

    genvar i;

    generate
        for (i = 0; i < 32; i = i + 1) begin : stage1
            if (i == 0) begin
                assign g1[i] = g0[i];
                assign p1[i] = p0[i];
            end
            else begin
                assign g1[i] = g0[i] | (p0[i] & g0[i-1]);
                assign p1[i] = p0[i] & p0[i-1];
            end
        end
    endgenerate

    generate
        for (i = 0; i < 32; i = i + 1) begin : stage2
            if (i < 2) begin
                assign g2[i] = g1[i];
                assign p2[i] = p1[i];
            end
            else begin
                assign g2[i] = g1[i] | (p1[i] & g1[i-2]);
                assign p2[i] = p1[i] & p1[i-2];
            end
        end
    endgenerate

    generate
        for (i = 0; i < 32; i = i + 1) begin : stage3
            if (i < 4) begin
                assign g3[i] = g2[i];
                assign p3[i] = p2[i];
            end
            else begin
                assign g3[i] = g2[i] | (p2[i] & g2[i-4]);
                assign p3[i] = p2[i] & p2[i-4];
            end
        end
    endgenerate

    generate
        for (i = 0; i < 32; i = i + 1) begin : stage4
            if (i < 8) begin
                assign g4[i] = g3[i];
                assign p4[i] = p3[i];
            end
            else begin
                assign g4[i] = g3[i] | (p3[i] & g3[i-8]);
                assign p4[i] = p3[i] & p3[i-8];
            end
        end
    endgenerate

    generate
        for (i = 0; i < 32; i = i + 1) begin : stage5
            if (i < 16) begin
                assign g5[i] = g4[i];
                assign p5[i] = p4[i];
            end
            else begin
                assign g5[i] = g4[i] | (p4[i] & g4[i-16]);
                assign p5[i] = p4[i] & p4[i-16];
            end
        end
    endgenerate

    wire [32:0] c;
    assign c[0] = cin;

    assign c[1] = g0[0] | (p0[0] & cin);

    generate
        for (i = 2; i < 33; i = i + 1) begin : carry_gen
            assign c[i] = g5[i-1] | (p5[i-1] & cin);
        end
    endgenerate

    generate
        for (i = 0; i < 32; i = i + 1) begin : sum_bits
            assign sum[i] = p0[i] ^ c[i];
        end
    endgenerate

    assign cout = c[32];
endmodule

// 32-bit shifter (shift a leftwards by b bits without rotation, enable dir to shift rightwards)
module shifter(input [31:0] a, input [4:0] b, input arith, input dir, output reg [31:0] shift);
    // Store intermediate shifts
    reg [31:0] shift1, shift2, shift3, shift4;

    always @(*) begin
        // Initialize the output to be the same as the input
        shift = a[31:0];

        // Start shifting from the LSB of (b), and store each intermediate shift
        // For each additional bit of (b), shift the corresponding intermediate by the significance of the bit

        // Left Shift
        if (~dir) begin
            shift1 = b[0] ? {shift[30:0], 1'b0} : shift;
            shift2 = b[1] ? {shift1[29:0], 2'b0} : shift1;
            shift3 = b[2] ? {shift2[27:0], 4'b0} : shift2;
            shift4 = b[3] ? {shift3[23:0], 8'b0} : shift3;
            shift = b[4] ? {shift4[15:0], 16'b0} : shift4;
        end

        // Right Logical Shift
        else if (~arith) begin
            shift1 =  b[0] ? {1'b0, shift[31:1]} : shift;
            shift2 =  b[1] ? {2'b0, shift1[31:2]} : shift1;
            shift3 =  b[2] ? {4'b0, shift2[31:4]} : shift2;
            shift4 =  b[3] ? {8'b0, shift3[31:8]} : shift3;
            shift =  b[4] ? {16'b0, shift4[31:16]} : shift4;
        end

        // Right Arithmetic Shift
        else begin
            shift1 = b[0] ? {{1{a[31]}}, shift[31:1]} : shift;
            shift2 = b[1] ? {{2{a[31]}}, shift1[31:2]} : shift1;
            shift3 = b[2] ? {{4{a[31]}}, shift2[31:4]} : shift2;
            shift4 = b[3] ? {{8{a[31]}}, shift3[31:8]} : shift3;
            shift = b[4] ? {{16{a[31]}}, shift4[31:16]} : shift4;
        end
    end
endmodule

// Compare 32-bit signed values a and b
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