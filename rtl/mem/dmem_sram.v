`timescale 1ns/1ns
// Data memory - sky130 macro implementation
//
// 8 KiB built from four sky130_sram_2kbyte_1rw1r_32x512_8 macros (2 KiB each),
// banked on the top two bits of the word address. Accesses use each macro's RW
// port; the read-only port is tied off.
//
// csb is active low, so a bank's chip select is the *inverted* bank select -
// getting that backwards sends every access in one bank to another, and nothing
// in the simulation build can notice, because that build contains no macros.
// tb/mem_agree_tb.v (make mem-agree) is what catches it.
//
// This is storage and bank decoding only. The write mask and the byte lanes it
// writes are computed by dmem_w_lanes.v one level up, shared with the
// behavioural model, so a byte or halfword store means the same thing here as it
// does there.
//
// Read data is registered, by the macro itself: dout0 is a flop, so the word for
// an address presented in one cycle is valid in the next. The behavioural model
// registers its read for exactly that reason, and dmem.v presents the resulting
// one-cycle contract to the pipeline. Nothing here is a cycle early or late
// relative to the model the ASIC is built from - that agreement is what
// `make mem-agree` checks, cycle for cycle.
    /* verilator lint_off UNUSEDSIGNAL */
    // Same 8 KiB decode as the behavioural model: addr[12:0] selects, the rest is
    // ignored rather than checked (there is no fault response to issue).
module dmem_sram(input clk, w_ena, input [3:0] w_strb, input [31:0] w_lanes,
                 input [31:0] addr, output [31:0] rdata);
    /* verilator lint_on UNUSEDSIGNAL */
    `include "defines.vh"

`ifdef USE_POWER_PINS
    // The PDK macro carries power pins that only exist in the post-layout
    // netlist. They are declared here rather than being passed up through
    // dmem/datapath/rv32i_core, because in the OpenLane flow the power grid is
    // attached to the chip top, not threaded through every functional module.
    // Declaring them as supply nets keeps the build elaborable and makes the
    // intent explicit; previously these names were never declared at all, so
    // each USE_POWER_PINS build silently invented two implicit 1-bit wires.
    supply1 vccd1;
    supply0 vssd1;
`endif

    wire [10:0] word_addr = addr[12:2];
    wire [1:0]  bank      = word_addr[10:9]; // which macro holds this word
    wire [8:0]  sram_addr = word_addr[8:0];  // word address inside a macro

    wire [31:0] rdata0, rdata1, rdata2, rdata3;

    // 2 KiB each: bank 0 = words 0-511, bank 1 = 512-1023, bank 2 = 1024-1535,
    // bank 3 = 1536-2047. The RW port is the load/store port; the read-only port
    // is unused here, with its chip select held high so it stays inactive.
    sky130_sram_2kbyte_1rw1r_32x512_8 sram0 (
        `PWR_CONN
        .clk0  (clk),
        .csb0  (bank != 2'd0),
        .web0  (~w_ena),
        .wmask0(w_strb),
        .addr0 (sram_addr),
        .din0  (w_lanes),
        .dout0 (rdata0),
        .clk1  (1'b0),
        .csb1  (1'b1),
        .addr1 (9'b0),
        .dout1 ()
    );

    sky130_sram_2kbyte_1rw1r_32x512_8 sram1 (
        `PWR_CONN
        .clk0  (clk),
        .csb0  (bank != 2'd1),
        .web0  (~w_ena),
        .wmask0(w_strb),
        .addr0 (sram_addr),
        .din0  (w_lanes),
        .dout0 (rdata1),
        .clk1  (1'b0),
        .csb1  (1'b1),
        .addr1 (9'b0),
        .dout1 ()
    );

    sky130_sram_2kbyte_1rw1r_32x512_8 sram2 (
        `PWR_CONN
        .clk0  (clk),
        .csb0  (bank != 2'd2),
        .web0  (~w_ena),
        .wmask0(w_strb),
        .addr0 (sram_addr),
        .din0  (w_lanes),
        .dout0 (rdata2),
        .clk1  (1'b0),
        .csb1  (1'b1),
        .addr1 (9'b0),
        .dout1 ()
    );

    sky130_sram_2kbyte_1rw1r_32x512_8 sram3 (
        `PWR_CONN
        .clk0  (clk),
        .csb0  (bank != 2'd3),
        .web0  (~w_ena),
        .wmask0(w_strb),
        .addr0 (sram_addr),
        .din0  (w_lanes),
        .dout0 (rdata3),
        .clk1  (1'b0),
        .csb1  (1'b1),
        .addr1 (9'b0),
        .dout1 ()
    );

    // Each macro registers its own dout0, and a deselected macro keeps the value
    // it last read. So the banks have to be combined with the bank select as it
    // was when the read was clocked, not with the current address: a load from
    // bank 0 followed by an access in bank 3 would otherwise mux out bank 3's
    // stale output and hand the pipeline the wrong word.
    reg [1:0] bank_q;
    always @(posedge clk) bank_q <= bank;

    assign rdata = (bank_q == 2'd0) ? rdata0 :
                   (bank_q == 2'd1) ? rdata1 :
                   (bank_q == 2'd2) ? rdata2 : rdata3;
endmodule
