`timescale 1ns/1ns
// Data memory - sky130 macro implementation
//
// 4 KiB built from two sky130_sram_2kbyte_1rw1r_32x512_8 macros (2 KiB each),
// banked on the top address bit. Accesses use each macro's RW port; the read-only
// port is tied off. csb is active low, so a bank's chip select is the *inverted*
// bank select - getting that backwards sends every lower-half access to the upper
// macro, which is what this wrapper used to do. tb/mem_agree_tb.v (make mem-agree)
// is what now catches it, since the simulation build contains no macros.
//
// Sub-word accesses use the macro's byte write mask, and the rules for which
// lanes a store writes and which bytes a load reads come from dmem_lanes.v -
// the same module the behavioural model instantiates. So the two implementations
// now agree on the value of every load and store, including unaligned ones,
// because there is only one place that defines them.
//
// CAUTION: they still disagree on *when* load data appears. dout0 is registered,
// so here load data is valid one cycle later than the combinational read port of
// rtl/mem/dmem_behav.v provides, and the core captures it in MEM/WB. See the note
// in rtl/mem/dmem.v and the end of the contract in dmem_lanes.v.

    /* verilator lint_off UNUSEDSIGNAL */
    // Same 4 KiB decode as the behavioural model.
module dmem_sram(input clk, w_ena, is_signed, input [1:0] width, input [31:0] addr, w_data, output [31:0] r_data);
    /* verilator lint_on UNUSEDSIGNAL */
    `include "defines.vh"

`ifdef USE_POWER_PINS
    // The PDK macro carries power pins that only exist in the post-layout
    // netlist. They are declared here rather than being passed up through
    // imem/datapath/rv32i_core, because in the OpenLane flow the power grid is
    // attached to the chip top, not threaded through every functional module.
    // Declaring them as supply nets keeps the build elaborable and makes the
    // intent explicit; previously these names were never declared at all, so
    // each USE_POWER_PINS build silently invented two implicit 1-bit wires.
    supply1 vccd1;
    supply0 vssd1;
`endif

    wire [9:0] word_addr = addr[11:2];
    wire       sel_upper = word_addr[9];
    wire [8:0] sram_addr = word_addr[8:0];
    wire [1:0] byte_off  = addr[1:0];

    wire [3:0]  w_strb;
    wire [31:0] w_lanes;

    wire [31:0] rdata_lo;
    wire [31:0] rdata_hi;

    // Lower 2 KiB: words 0-511
    sky130_sram_2kbyte_1rw1r_32x512_8 sram0 (
        `PWR_CONN
        // Port 0 (RW) - load/store port
        .clk0  (clk),
        .csb0  (sel_upper),      // active low: bank 0 is off for upper-half accesses
        .web0  (~w_ena),
        .wmask0(w_strb),
        .addr0 (sram_addr),
        .din0  (w_lanes),
        .dout0 (rdata_lo),
        // Port 1 (R) - unused here
        .clk1  (1'b0),
        .csb1  (1'b1),
        .addr1 (9'b0),
        .dout1 ()
    );

    // Upper 2 KiB: words 512-1023
    sky130_sram_2kbyte_1rw1r_32x512_8 sram1 (
        `PWR_CONN
        .clk0  (clk),
        .csb0  (~sel_upper),     // active low: bank 1 is off for lower-half accesses
        .web0  (~w_ena),
        .wmask0(w_strb),
        .addr0 (sram_addr),
        .din0  (w_lanes),
        .dout0 (rdata_hi),
        .clk1  (1'b0),
        .csb1  (1'b1),
        .addr1 (9'b0),
        .dout1 ()
    );

    // Each macro registers its own dout0, and a deselected macro keeps the value
    // it last read. So the two banks have to be combined with the bank select as
    // it was when the read was clocked, not with the current address: a load from
    // the lower 2 KiB followed by an access in the upper 2 KiB would otherwise mux
    // out the upper bank's stale output and hand the pipeline the wrong word.
    reg sel_q;
    always @(posedge clk) sel_q <= sel_upper;

    wire [31:0] raw = sel_q ? rdata_hi : rdata_lo;

    dmem_lanes lanes (
        .byte_off (byte_off),
        .width    (width),
        .is_signed(is_signed),
        .w_data   (w_data),
        .raw      (raw),
        .w_strb   (w_strb),
        .w_lanes  (w_lanes),
        .r_data   (r_data)
    );
endmodule
