`timescale 1ns/1ns
// Data memory - implementation selection. See rtl/mem/imem.v for why an ifdef
// switch and mutually exclusive filelists rather than one module.
//
// The two implementations share their sub-word access rules via dmem_lanes.v, so
// every load and store produces the same VALUE in either build - including
// unaligned ones, whose definition is pinned by Test 10 in tb/core_tb.v.
//
// They do NOT yet agree on TIMING, and that difference is real:
//
//   * dmem_behav reads combinationally - the address is presented in MEM and the
//     data is there in MEM, which is what the pipeline relies on today, since
//     MEM/WB registers r_data on the same edge.
//   * dmem_sram's dout0 is registered by the macro - the data appears during WB,
//     one cycle after MEM/WB has already captured it.
//
// So a program that loads anything runs correctly on the behavioural model and
// incorrectly on the macros, today, with no error. The macro read port cannot be
// made combinational, so the fix belongs in the core: take load data out of
// MEM/WB and drive the writeback mux straight from the memory read port instead,
// which is exactly one cycle behind the address, for both implementations. That
// also deletes two 32-bit pipeline registers. It is a datapath change, not a
// memory change, so it is deliberately not smuggled into this file's rework -
// and until it lands, the ASIC build is NOT functionally verified.
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
