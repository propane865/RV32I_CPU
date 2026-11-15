`timescale 1ns/1ns
// RV32I core - top level
//
// Six-stage pipelined RV32I CPU. The ports are the interface the testbench and
// any SoC wrapper need: the clock and reset, the current fetch address, and the
// data-memory access as it happens in the MEM stage (exposed so a bus or a
// waveform viewer can observe memory traffic without reaching into the core).
//
// The exception interface is the third piece of the outside world: this core
// detects the six exceptions it can actually detect, reports them on those three
// outputs, and stops. There is no handler, no vector and no return, so a trap is
// terminal - which is what lets a test harness use ECALL as a pass/fail signal and
// call it an architectural mechanism rather than a testbench convention.

// Everything else is inside datapath.v.
//
// The dmem_* ports mirror the data memory rather than the pipeline: dmem_addr,
// dmem_wdata, dmem_w_ena and dmem_width are the access being issued from the
// memory stage this cycle, and dmem_rdata is the read data of the access issued
// the cycle before, because the memory's read port is registered (that is what
// the sky130 macros are). See rtl/mem/dmem.v.

// Included before the module header rather than inside it: the exception width is
// used in the port list, and a `define is only in effect from the line it appears
// on, so a macro a port list depends on cannot be defined by the module body.
`include "defines.vh"

module rv32i_core(
    input  clk, rst,
    output [31:0] pc_out, dmem_addr, dmem_wdata, dmem_rdata,
    output [1:0]  dmem_width,
    output        dmem_w_ena,
    // Exception interface. `trap` goes high when an instruction raises an exception
    // and stays high until reset, because this core has no handler to return to - no
    // CSRs, no mcause, no mret - so the machine stops on the instruction that
    // trapped and the report is what an external agent reads. `trap_cause` is the
    // architectural cause number (see `TRAP_* in defines.vh), so a later CSR version
    // can write it into mcause unchanged. `trap_pc` is the address of the trapping
    // instruction itself.
    output        trap,
    output [`TRAP_CAUSE_W-1:0] trap_cause,
    output [31:0] trap_pc
    `ifdef USE_POWER_PINS
    // The chip's supply nets, and the only place the flow's power grid attaches.
    // They exist solely to give the SRAM macros' power pins a named net to hang
    // off: a net the elaborator folds into a constant would be resolved to some
    // unrelated wire by Odb.SetPowerConnections. Nothing here drives or reads
    // them, so the simulation builds - which do not define USE_POWER_PINS - have
    // no such ports at all, and a testbench that does build with them leaves
    // them unconnected without consequence.
    `PWR_PORTS
    `endif
);
    `include "defines.vh"

    datapath DP(
        `ifdef USE_POWER_PINS
        .VPWR   (VPWR),
        .VGND   (VGND),
        `endif
        .clk    (clk),
        .rst    (rst),
        .pc_out (pc_out),
        .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_rdata(dmem_rdata),
        .dmem_w_ena(dmem_w_ena),
        .dmem_width(dmem_width),
        .trap   (trap),
        .trap_cause(trap_cause),
        .trap_pc(trap_pc)
    );
endmodule
