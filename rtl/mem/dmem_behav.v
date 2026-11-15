`timescale 1ns/1ns
// Data memory - behavioural implementation (simulation only)
//
// 8 KiB of byte-addressable storage with a masked synchronous write port and a
// REGISTERED read port, which is the whole point of this file: the sky130 macros
// in dmem_sram.v clock their read data, so a combinational read here would give
// the core a memory that answers a cycle earlier than the chip's does, and every
// load in the design would be simulated against hardware that does not exist.
// See the contract in rtl/mem/dmem.v.
//
// Storage and timing only. What a byte or halfword access means is decided by
// dmem_w_lanes.v and dmem_r_lanes.v, one level up, and both implementations are
// fed from them - so the masked write below just applies the strobes it is
// given, exactly the way the macro's wmask0 does.
//
// The storage stays a byte array because the testbench back-doors `IMPL.mem` byte
// by byte to check store results.
    /* verilator lint_off UNUSEDSIGNAL */
    // The data memory is 8 KiB, so addr[12:0] is all that decodes; the upper bits
    // are ignored, not checked (out-of-range addresses wrap). Checking them needs
    // a fault response the core does not have yet.
module dmem_behav(input clk, w_ena, input [3:0] w_strb, input [31:0] w_lanes,
                  input [31:0] addr, output [31:0] rdata);
    /* verilator lint_on UNUSEDSIGNAL */
    `include "defines.vh"

    reg [7:0] mem [0:`DMEM_BYTES-1];

    // The access is confined to this word; addr[1:0] only picks lanes within it.
    wire [12:0] word_base = {addr[12:2], 2'b00};

    wire [31:0] raw = {mem[word_base + 3], mem[word_base + 2],
                       mem[word_base + 1], mem[word_base]};

    // One register, and it is the macro's dout0: the word read at this edge is the
    // word the address selected, valid from the next cycle. Because both the write
    // and this capture are non-blocking, a read taken in the same cycle as a write
    // to the same word sees the value as of the start of the cycle, which is what
    // the macro does too - the two models cannot disagree about that either.
    reg [31:0] raw_q;
    always @(posedge clk) begin
        if (w_ena) begin
            if (w_strb[0]) mem[word_base    ] <= w_lanes[7:0];
            if (w_strb[1]) mem[word_base + 1] <= w_lanes[15:8];
            if (w_strb[2]) mem[word_base + 2] <= w_lanes[23:16];
            if (w_strb[3]) mem[word_base + 3] <= w_lanes[31:24];
        end
        raw_q <= raw;
    end

    assign rdata = raw_q;

    // synthesis translate_off
    integer i;
    initial begin
        for (i = 0; i < `DMEM_BYTES; i = i + 1) begin
            mem[i] = 8'h0;
        end
    end
    // synthesis translate_on
endmodule
