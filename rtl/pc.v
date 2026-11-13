`timescale 1ns/1ns
// Program counter
//
// Holds the address of the instruction being fetched. Reloaded with a redirect
// target when a branch or jump is taken, frozen on a load-use stall, otherwise
// advances by four.

module pc(input clk, rst, stall, pc_src, input [31:0] pc_target, output [31:0] pc_out);
    // Store the value of the program Counter
    reg [31:0] pc_reg;

    assign pc_out = pc_reg;
    // There is deliberately no pc+4 output: the link value a JAL/JALR needs is
    // the PC of the *jumping* instruction, which is only known two stages later,
    // so branch_unit computes pc+4 from the pipelined PC. An adder here would be
    // dead hardware (and previously was).

    // Update program counter at every clock cycle
    always @(posedge clk) begin
        // If reset signal is enabled, then set to zero
        if (rst) begin
            pc_reg <= 32'b0;
        end
        // Else, set program counter to target value, or its current value plus 4 (depending on pc_src)
        else if (!stall) begin
            pc_reg <= pc_src ? pc_target : pc_reg + 32'h4;
        end
    end
endmodule
