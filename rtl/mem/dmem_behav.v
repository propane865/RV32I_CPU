`timescale 1ns/1ns
// Data memory - behavioural model (simulation only)
//
// 4 KiB of byte-addressable storage with a synchronous write port and a
// combinational read port, which is what the pipeline currently expects: the
// address is presented in MEM and the read data is captured into MEM/WB on the
// same edge.
//
// The storage stays a byte array because the testbench back-doors `IMPL.mem`
// byte by byte to check store results. The sub-word rules, though, are NOT
// written here: dmem_lanes.v owns them, shared with the macro implementation, so
// that a byte or halfword store means the same thing in both builds. The write
// applies that module's byte strobes to the four bytes of the addressed word,
// which is exactly the macro's wmask0 operation.
//
// The one thing that still differs from rtl/mem/dmem_sram.v is read *timing* -
// see the note in rtl/mem/dmem.v.
    /* verilator lint_off UNUSEDSIGNAL */
    // The data memory is 4 KiB, so addr[11:0] is all that decodes; the upper
    // bits are ignored, not checked (out-of-range addresses wrap).
module dmem_behav(input clk, w_ena, is_signed, input [1:0] width, input [31:0] addr, w_data, output [31:0] r_data);
    /* verilator lint_on UNUSEDSIGNAL */
    `include "defines.vh"

    reg [7:0] mem [0:4095];

    // The access is confined to this word; addr[1:0] only picks lanes within it.
    wire [11:0] word_base = {addr[11:2], 2'b00};

    wire [3:0]  w_strb;
    wire [31:0] w_lanes;

    dmem_lanes lanes (
        .byte_off (addr[1:0]),
        .width    (width),
        .is_signed(is_signed),
        .w_data   (w_data),
        .raw      ({mem[word_base + 3], mem[word_base + 2],
                    mem[word_base + 1], mem[word_base]}),
        .w_strb   (w_strb),
        .w_lanes  (w_lanes),
        .r_data   (r_data)
    );

    always @(posedge clk) begin
        if (w_ena) begin
            if (w_strb[0]) mem[word_base    ] <= w_lanes[7:0];
            if (w_strb[1]) mem[word_base + 1] <= w_lanes[15:8];
            if (w_strb[2]) mem[word_base + 2] <= w_lanes[23:16];
            if (w_strb[3]) mem[word_base + 3] <= w_lanes[31:24];
        end
    end

    // synthesis translate_off
    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) begin
            mem[i] = 8'h0;
        end
    end
    // synthesis translate_on
endmodule
