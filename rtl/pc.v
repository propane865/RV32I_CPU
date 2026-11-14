`timescale 1ns/1ns
// Program counter
//
// Holds the address of the instruction being fetched. Reloaded with a redirect
// target when a branch or jump is taken, frozen on a load-use stall, and frozen
// for good once the core has trapped.
//
// THE PRIORITY, AND WHY IT IS IN THIS ORDER
//
//   reset > halt > redirect > stall > count
//
// A redirect has to beat a stall. The load-use stall and the redirect come from
// different stages - the stall from a load in execute 1 with its consumer still
// in decode, the redirect from a branch or jump resolving in execute 2 - so both
// can be asserted in the same cycle, and the redirect is a purely combinational
// pulse: pc_target is the execute 2 stage's output for this cycle only, and by
// the next cycle that instruction has moved to the memory stage and the request
// is simply gone. Letting the stall win therefore does not delay the transfer,
// it drops it, and the core silently continues down the fall-through path as if
// the branch had not been taken. Freezing the fetch is always recoverable;
// losing a redirect is not.
//
// Halt outranks the redirect because the machine is stopped: the redirecting
// instruction that raised a trap has already been squashed, and letting one more
// fetch through a stopped core would put an instruction in flight that nothing
// downstream can retire.
//
// There is deliberately no pc+4 output: the link value a JAL/JALR needs is
// the PC of the *jumping* instruction, which is only known two stages later, so
// it is computed from the pipelined PC where that PC lives. An adder here would
// be dead hardware (and previously was).

module pc(input clk, rst, stall, halt, pc_src, input [31:0] pc_target, output [31:0] pc_out);
    `include "defines.vh"

    // Store the value of the program Counter
    reg [31:0] pc_reg;

    assign pc_out = pc_reg;

    // Update program counter at every clock cycle
    always @(posedge clk) begin
        if (rst) begin
            // Start of execution
            pc_reg <= `RESET_PC;
        end
        // Else, in priority order: stopped, redirected, frozen, or counting on.
        else if (halt) begin
            pc_reg <= pc_reg;
        end
        else if (pc_src) begin
            pc_reg <= pc_target;
        end
        else if (!stall) begin
            pc_reg <= pc_reg + 32'h4;
        end
    end
endmodule
