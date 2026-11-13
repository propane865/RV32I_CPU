`timescale 1ns/1ns
// Instruction memory - sky130 macro implementation
//
// 4 KiB built from two sky130_sram_2kbyte_1rw1r_32x512_8 macros (2 KiB each),
// selected by the top address bit: words 0-511 in the lower macro, 512-1023 in
// the upper one. The CPU only ever reads instructions, so the RW port of each
// macro is tied off and the read-only port is the fetch port.
//
// Fetch uses the read-only port, which on this macro flavour is asynchronous
// (clk1 is a layout-only pin), so this is a combinational PC -> instruction path
// exactly like rtl/mem/imem_behav.v: same value, same cycle, nothing to reconcile.
// The RW port is tied off, with its chip select held high so it stays inactive.
//
// csb is active low. Both banks used to be driven with the select the wrong way
// round, so every fetch from the lower 2 KiB actually enabled the upper macro;
// nothing in the simulation build could notice, because that build has no macros.

    /* verilator lint_off UNUSEDSIGNAL */
    // Same 4 KiB word-addressed decode as the behavioural model.
module imem_sram(input [31:0] pc, output [31:0] instr);
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

    wire [9:0] word_addr = pc[11:2];
    wire       sel_upper = word_addr[9];   // which macro holds this word
    wire [8:0] sram_addr = word_addr[8:0]; // word address inside a macro

    wire [31:0] instr_lo;
    wire [31:0] instr_hi;

    // Lower 2 KiB: words 0-511
    sky130_sram_2kbyte_1rw1r_32x512_8 sram0 (
        `PWR_CONN
        // Port 0 (RW) - unused, the fetch port is the only user
        .clk0  (1'b0),
        .csb0  (1'b1),
        .web0  (1'b1),
        .wmask0(4'b0000),
        .addr0 (9'b0),
        .din0  (32'b0),
        .dout0 (),
        // Port 1 (R) - instruction fetch
        .clk1  (1'b0),          // layout-only pin, port 1 is asynchronous
        .csb1  (sel_upper),     // active low: deselected when fetching elsewhere
        .addr1 (sram_addr),
        .dout1 (instr_lo)
    );

    // Upper 2 KiB: words 512-1023
    sky130_sram_2kbyte_1rw1r_32x512_8 sram1 (
        `PWR_CONN
        .clk0  (1'b0),
        .csb0  (1'b1),
        .web0  (1'b1),
        .wmask0(4'b0000),
        .addr0 (9'b0),
        .din0  (32'b0),
        .dout0 (),
        .clk1  (1'b0),          // layout-only pin, port 1 is asynchronous
        .csb1  (~sel_upper),    // active low: deselected when fetching elsewhere
        .addr1 (sram_addr),
        .dout1 (instr_hi)
    );

    assign instr = sel_upper ? instr_hi : instr_lo;
endmodule
