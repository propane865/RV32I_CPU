`timescale 1ns/1ns
// Instruction memory - behavioural model (simulation only)
//
// 8 KiB, word-addressed, combinational read. The testbench loads programs by
// writing IMPL.mem directly.
//
// Read latency is deliberately unlike the data memory's: this is a ROM-like port
// and the macro it stands for (rtl/mem/imem_sram.v) reads asynchronously on its
// dedicated read port, so both models present the word for a PC in the same
// cycle it is valid. If that ever stops being true the fetch stage needs a
// bubble, not this file a flop - the two models are compared same-cycle by
// `make mem-agree`, which is what notices.
    /* verilator lint_off UNUSEDSIGNAL */
    // The instruction memory is 8 KiB and word addressed, so pc[12:2] is all that
    // decodes. The upper bits are ignored rather than checked: there is no bus and
    // no fault response, so an out-of-range fetch wraps.
module imem_behav(input [31:0] pc, output [31:0] instr);
    /* verilator lint_on UNUSEDSIGNAL */
    `include "defines.vh"

    // 2048 words x 32 bits; only pc[12:2] is used, so a fetch outside the 8 KiB
    // wraps rather than faulting (there is no MMU and no bus).
    reg [31:0] mem [0:`IMEM_WORDS-1];

    assign instr = mem[pc[12:2]];

    // synthesis translate_off
    integer i;
    initial begin
        for (i = 0; i < `IMEM_WORDS; i = i + 1) begin
            mem[i] = `RV_NOP;
        end
    end
    // synthesis translate_on
endmodule
