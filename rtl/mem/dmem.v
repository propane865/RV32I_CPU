`timescale 1ns/1ns
// Data memory - implementation selection. See rtl/mem/imem.v for why an ifdef
// switch and mutually exclusive filelists rather than one module.
//
// NOT EQUIVALENT to the macro version yet: the behavioural model ignores
// addr[1:0] for sub-word accesses while the SRAM version uses it as a byte-lane
// offset, so unaligned SB/SH/LB/LH behave differently in simulation and silicon.
// Recorded as a known defect rather than silently unified, because deciding
// which behaviour is correct is a design decision.
module dmem(input clk, w_ena, is_signed, input [1:0] width, input [31:0] addr, w_data, output [31:0] r_data);
`ifdef USE_SRAM_MEMS
    dmem_sram IMPL(
        .clk      (clk),
        .w_ena    (w_ena),
        .is_signed(is_signed),
        .width    (width),
        .addr     (addr),
        .w_data   (w_data),
        .r_data   (r_data)
    );
`else
    dmem_behav IMPL(
        .clk      (clk),
        .w_ena    (w_ena),
        .is_signed(is_signed),
        .width    (width),
        .addr     (addr),
        .w_data   (w_data),
        .r_data   (r_data)
    );
`endif
endmodule
