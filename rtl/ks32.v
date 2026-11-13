// 32-bit Kogge-Stone (carry-look-ahead) adder: sum = a + b + cin, plus carry out.
//
// Five log-depth combine stages, so the carry settles in O(log n) rather than
// the O(n) of a ripple chain. Deliberately instantiated rather than writing
// '+': the ASIC build is timing-driven and this sits on the ALU, the branch
// redirect path and the comparator.
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
