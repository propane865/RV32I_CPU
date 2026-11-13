`timescale 1ns/1ns
// Register file - 32 x 32-bit, two read ports, one write port
//
// x0 is not stored: it is not allocated in the array, reads as zero and discards
// writes, so the zero guarantee cannot be broken by a stray write enable.
//
// The read ports forward a write that is happening on the same clock edge. That
// is what lets a value written in writeback be used by an instruction in decode
// in the same cycle, which the forwarding paths alone do not cover.

module regfile(input clk, w_ena, input [4:0] rs1, rs2, rd, input [31:0] w_data, output [31:0] r_data1, r_data2);
    // 32 General-Purpose Registers, 32-bit (Register x0 is the zero register)
    reg [31:0] regs [1:31];

    // If the register being read is x0, return zero, else return value of the register
    assign r_data1 = (rs1 == 5'b0) ? 32'b0 : (w_ena && rd == rs1 && rd != 5'b0) ? w_data : regs[rs1];
    assign r_data2 = (rs2 == 5'b0) ? 32'b0 : (w_ena && rd == rs2 && rd != 5'b0) ? w_data : regs[rs2];
    // Write to the register address at the next clock (unless the destination register is x0)
    always @(posedge clk) begin
        if (w_ena && rd != 5'b0) begin
            regs[rd] <= w_data;
        end
    end

    integer i;
    initial begin
        for (i = 1; i < 32; i = i + 1)
            regs[i] = 32'b0;
    end
endmodule
