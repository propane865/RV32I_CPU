// Instruction memory - behavioural model (simulation only)
//
// 4 KiB, word-addressed, combinational read. The testbench loads programs by
// writing IMPL.mem directly.
module imem_behav(input [31:0] pc, output [31:0] instr);
    `include "defines.vh"

    // 1024 words x 32 bits; only pc[11:2] is used, so a fetch outside the 4 KiB
    // wraps rather than faulting (there is no MMU and no bus).
    reg [31:0] mem [0:1023];

    assign instr = mem[pc[11:2]];

    // synthesis translate_off
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) begin
            mem[i] = `RV_NOP;
        end
    end
    // synthesis translate_on
endmodule
