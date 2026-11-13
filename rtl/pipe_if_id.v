`timescale 1ns/1ns
// IF/ID pipeline register
//
// Holds the fetched instruction and its PC. This is the only stage register
// that both stalls (load-use hazard) and flushes (branch redirect); flushing
// inserts a NOP rather than an enable-clear because the decoder must see a
// valid instruction.
module pipe_if_id (
    input  wire        clk,
    input  wire        rst,
    input  wire        flush,  // branch taken: drop the two younger instructions
    input  wire        stall,  // load-use hazard: hold this entry for a cycle

    input  wire [31:0] i_pc,
    input  wire [31:0] i_instr,

    output wire [31:0] o_pc,
    output wire [31:0] o_instr
);
    `include "defines.vh"

    // PACK, UNPACK and BUBBLE list the fields in the same order. Adding a field
    // means editing all three; verilator -Wall reports the width drift if you
    // edit only two of them.
    localparam [63:0] BUBBLE = { 32'h0, `RV_NOP };

    wire [63:0] pack = { i_pc, i_instr };

    reg [63:0] q;

    always @(posedge clk) begin
        if (rst || flush) begin
            q <= BUBBLE;
        end
        else if (!stall) begin
            q <= pack;
        end
    end

    assign { o_pc, o_instr } = q;
endmodule
