`timescale 1ns/1ns
// RV32I core - top level
//
// Six-stage pipelined RV32I CPU. The ports are the interface the testbench and
// any SoC wrapper need: the clock and reset, the current fetch address, and the
// data-memory access as it happens in the MEM stage (exposed so a bus or a
// waveform viewer can observe memory traffic without reaching into the core).
//
// Everything else is inside datapath.v.
//
// The dmem_* ports mirror the data memory rather than the pipeline: dmem_addr,
// dmem_wdata, dmem_w_ena and dmem_width are the access being issued from the
// memory stage this cycle, and dmem_rdata is the read data of the access issued
// the cycle before, because the memory's read port is registered (that is what
// the sky130 macros are). See rtl/mem/dmem.v.

module rv32i_core(input clk, rst, output [31:0] pc_out, dmem_addr, dmem_wdata, dmem_rdata, output [1:0] dmem_width, output dmem_w_ena);
    datapath DP(
        .clk    (clk),
        .rst    (rst),
        .pc_out (pc_out),
        .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_rdata(dmem_rdata),
        .dmem_w_ena(dmem_w_ena),
        .dmem_width(dmem_width)
    );
endmodule
