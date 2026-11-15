`timescale 1ns/1ns
// Instruction memory - sky130 macro implementation
//
// 8 KiB built from four sky130_sram_2kbyte_1rw1r_32x512_8 macros (2 KiB each),
// banked on the top two bits of the word address. The CPU only ever reads
// instructions, so the RW port of each macro is tied off and the read-only port
// is the fetch port.
//
// Fetch uses the read-only port, which on this macro flavour is asynchronous
// (clk1 is a layout-only pin), so this is a combinational PC -> instruction path
// exactly like rtl/mem/imem_behav.v: same value, same cycle, nothing to
// reconcile. The RW port is tied off, with its chip select held high so it stays
// inactive.
//
// csb is active low, so a bank's select is the *inverted* bank select. Both banks
// used to be driven the wrong way round, so every fetch from the lower 2 KiB
// actually enabled the upper macro; nothing in the simulation build could notice,
// because that build has no macros, which is why tb/mem_agree_tb.v exists.
//
// A deselected macro's dout1 is X, not stale data, so the mux below must select
// from the live bank - the one that is actually enabled this cycle - and never
// from a delayed copy of it.

`include "defines.vh"

    /* verilator lint_off UNUSEDSIGNAL */
    // Same 8 KiB word-addressed decode as the behavioural model.
module imem_sram(input [31:0] pc, output [31:0] instr
    `ifdef USE_POWER_PINS
                 `PWR_PORTS
    `endif
                 );
    /* verilator lint_on UNUSEDSIGNAL */
    `include "defines.vh"

    // The macro's power pins arrive as ports, threaded up through imem/datapath
    // to the chip top, because that is the net the flow's power grid is built on
    // (see `PWR_PORTS in defines.vh for why they cannot be local supply nets).

    wire [10:0] word_addr = pc[12:2];
    wire [1:0]  bank      = word_addr[10:9];  // which macro holds this word
    wire [8:0]  sram_addr = word_addr[8:0];   // word address inside a macro

    wire [31:0] instr0, instr1, instr2, instr3;

    // 2 KiB each: bank 0 = words 0-511, bank 1 = 512-1023, bank 2 = 1024-1535,
    // bank 3 = 1536-2047.
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
        .csb1  (bank != 2'd0),  // active low: deselected when fetching elsewhere
        .addr1 (sram_addr),
        .dout1 (instr0)
    );

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
        .csb1  (bank != 2'd1),
        .addr1 (sram_addr),
        .dout1 (instr1)
    );

    sky130_sram_2kbyte_1rw1r_32x512_8 sram2 (
        `PWR_CONN
        .clk0  (1'b0),
        .csb0  (1'b1),
        .web0  (1'b1),
        .wmask0(4'b0000),
        .addr0 (9'b0),
        .din0  (32'b0),
        .dout0 (),
        .clk1  (1'b0),
        .csb1  (bank != 2'd2),
        .addr1 (sram_addr),
        .dout1 (instr2)
    );

    sky130_sram_2kbyte_1rw1r_32x512_8 sram3 (
        `PWR_CONN
        .clk0  (1'b0),
        .csb0  (1'b1),
        .web0  (1'b1),
        .wmask0(4'b0000),
        .addr0 (9'b0),
        .din0  (32'b0),
        .dout0 (),
        .clk1  (1'b0),
        .csb1  (bank != 2'd3),
        .addr1 (sram_addr),
        .dout1 (instr3)
    );

    assign instr = (bank == 2'd0) ? instr0 :
                   (bank == 2'd1) ? instr1 :
                   (bank == 2'd2) ? instr2 : instr3;
endmodule
