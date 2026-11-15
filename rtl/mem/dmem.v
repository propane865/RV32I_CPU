`timescale 1ns/1ns
// Data memory - the core's view of the data store
//
// This wrapper, not the models below it, owns the two things the pipeline needs
// to be told: what a sub-word access means, and when read data is valid. The
// implementations are masked storage and nothing else, which is what makes them
// interchangeable - they have identical ports and identical timing, so
// `make mem-agree` can compare them cycle for cycle instead of having to be told
// that one of them is a cycle late.
//
// READ LATENCY: ONE CYCLE, IN BOTH BUILDS
//
// The sky130 macro registers its read data (`dout0` is a flop in the macro
// model), so the value of a read appears during the cycle AFTER the address was
// presented. That is a property of the silicon, not of the model: the macro has
// no combinational read port. So the core must be built to expect one cycle, and
// the behavioural model has to match it, or simulation is verifying a memory the
// chip does not have - which is worse than not simulating it, because a load that
// works in simulation and not in the macros is a bug with no test.
//
// The consequence for the pipeline is that a load's value exists only during its
// writeback stage. It reaches the register file from here rather than from the
// MEM/WB staging register (which is why that register carries no load-data
// field), and any instruction that consumes a load has to wait until the load is
// in writeback to be given it - see rtl/hazard_unit.v.
//
// So the fields that say *what* was read have to travel one cycle behind the
// access that produced them, which is what the register slice below is. It is
// unconditional: one read is issued to the array every cycle, exactly as the
// macro sees one read every cycle, so the word that comes out always belongs to
// the address that went in the cycle before.
//
// IMPLEMENTATION SELECTION
//
// dmem_behav and dmem_sram cannot both be elaborated under one name, so
// `USE_SRAM_MEMS` picks, and filelists/sim.f and filelists/asic.f are the two
// mutually exclusive source lists that keep the choice consistent. Building with
// both present is a duplicate-module error, which is the fail-safe direction.
//
// The instance is named IMPL because the testbench reaches the storage array
// through it (DUT.DP.DMEM.IMPL.mem) to preload and check bytes.
module dmem(input clk, w_ena, is_signed, input [1:0] width, input [31:0] addr, w_data, output [31:0] r_data);
    `include "defines.vh"

    // ---- store side: the live access ------------------------------------------
    //
    // The write mask has to be valid in the same cycle the array is written, so
    // it is decoded from the access as it happens, not from a delayed copy.
    wire [3:0]  w_strb;
    wire [31:0] w_lanes;

    dmem_w_lanes W_LANES (
        .byte_off (addr[1:0]),
        .width    (width),
        .w_data   (w_data),
        .w_strb   (w_strb),
        .w_lanes  (w_lanes)
    );

    // ---- load side: the access that produced the word now being read ----------
    reg [1:0] byte_off_q;
    reg [1:0] width_q;
    reg       is_signed_q;

    always @(posedge clk) begin
        byte_off_q  <= addr[1:0];
        width_q     <= width;
        is_signed_q <= is_signed;
    end

    // ---- storage --------------------------------------------------------------
    wire [31:0] rdata;

`ifdef USE_SRAM_MEMS
    dmem_sram IMPL(
        .clk    (clk),
        .w_ena  (w_ena),
        .w_strb (w_strb),
        .w_lanes(w_lanes),
        .addr   (addr),
        .rdata  (rdata)
    );
`else
    dmem_behav IMPL(
        .clk    (clk),
        .w_ena  (w_ena),
        .w_strb (w_strb),
        .w_lanes(w_lanes),
        .addr   (addr),
        .rdata  (rdata)
    );
`endif

    dmem_r_lanes R_LANES (
        .byte_off (byte_off_q),
        .width    (width_q),
        .is_signed(is_signed_q),
        .raw      (rdata),
        .r_data   (r_data)
    );
endmodule
