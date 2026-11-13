// Data memory - sky130 macro implementation
//
// 4 KiB built from two sky130_sram_2kbyte_1rw1r_32x512_8 macros (2 KiB each),
// banked on the top address bit. Both accesses use each macro's RW port; the
// read-only port is tied off.
//
// Sub-word accesses use the macro's byte write mask: the write word is
// replicated across all four byte lanes and wmask0 selects the lanes that
// actually change, so a byte or halfword store needs no read-modify-write. On
// reads the requested lanes are extracted using addr[1:0].
//
// CAUTION: dout0 is registered, so load data is valid one cycle later than the
// combinational read port of rtl/mem/dmem_behav.v provides. See the note in
// vendor/sky130_sram_2kbyte_1rw1r_32x512_8.v.

module dmem_sram(input clk, w_ena, is_signed, input [1:0] width, input [31:0] addr, w_data, output reg [31:0] r_data);
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

    // Which byte lanes a store touches, for the given access width and offset.
    reg [3:0] wmask;
    always @(*) begin
        case (width)
            `MEM_B: wmask = 4'b0001 << byte_off;
            `MEM_H: wmask = 4'b0011 << byte_off;
            `MEM_W: wmask = 4'b1111;
            default: wmask = 4'b0000;
        endcase
    end

    // Replicate the store value across every lane so the masked lanes see the
    // right bytes regardless of the offset.
    wire [31:0] wdata_rep = (width == `MEM_B) ? {4{w_data[7:0]}} :
                            (width == `MEM_H) ? {2{w_data[15:0]}} : w_data;

    wire [31:0] rdata_lo;
    wire [31:0] rdata_hi;

    // Lower 2 KiB: words 0-511
    sky130_sram_2kbyte_1rw1r_32x512_8 sram0 (
        `PWR_CONN
        // Port 0 (RW) - load/store port
        .clk0  (clk),
        .csb0  (~sel_upper),
        .web0  (~w_ena),
        .wmask0(wmask),
        .addr0 (sram_addr),
        .din0  (wdata_rep),
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
        .csb0  (sel_upper),
        .web0  (~w_ena),
        .wmask0(wmask),
        .addr0 (sram_addr),
        .din0  (wdata_rep),
        .dout0 (rdata_hi),
        .clk1  (1'b0),
        .csb1  (1'b1),
        .addr1 (9'b0),
        .dout1 ()
    );

    wire [31:0] raw = sel_upper ? rdata_hi : rdata_lo;
    wire [31:0] word_at_off = raw >> {byte_off, 3'b0};   // align to byte_off

    // Sign/zero extend the selected bytes. The MSB of the extracted field decides
    // the fill, per RV32I (LB/LBU, LH/LHU, LW).
    always @(*) begin
        case (width)
            `MEM_B: r_data = is_signed ? {{24{word_at_off[7]}},  word_at_off[7:0]}
                                       : {24'h0,                word_at_off[7:0]};
            `MEM_H: r_data = is_signed ? {{16{word_at_off[15]}}, word_at_off[15:0]}
                                       : {16'h0,                word_at_off[15:0]};
            `MEM_W: r_data = raw;
            default: r_data = 32'h0;
        endcase
    end
endmodule
