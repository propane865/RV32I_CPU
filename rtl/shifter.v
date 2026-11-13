`timescale 1ns/1ns
// 32-bit barrel shifter.
//
// Five stages of the same 2:1 mux, one per shift-amount bit, so the worst-case
// path is one mux regardless of the shift distance.
//   dir   = 0 shifts left,  dir = 1 shifts right
//   arith = 1 fills the vacated MSBs with the sign bit (arithmetic right)
//   arith = 0 fills with zeros            (logical right)
// Left shifts ignore arith, since nothing is shifted in at the bottom.
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
