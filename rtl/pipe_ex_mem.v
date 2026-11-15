`timescale 1ns/1ns
// EX/MEM pipeline register
//
// Carries the executed instruction into the memory stage.
//
// WHY THIS REGISTER NOW HAS A FLUSH INPUT
//
// It used to have none, and the reason was sound for the instructions that
// existed then: the only thing that could disturb the pipeline behind execute 2
// was a taken branch or jump, and that squashes only the two YOUNGER slots (IF/ID
// and ID/EX). Everything reaching this register is older than the branch, so
// everything here must retire normally, and a flush input would have been an
// invitation to squash something that must not be squashed.
//
// An exception is the second thing that resolves in execute 2, and it is the
// opposite case: the trapping instruction is the one in execute 2 itself, and it
// must not retire at all. Its memory write, its register write and its link value
// all have to be suppressed - and by the time the exception is known, its
// effective address and its store data are sitting right here at the input. This
// register is the last place that can stop them, so this is where the flush goes.
//
// The flush takes a bubble, exactly as the other staging registers do: a store
// with its enable cleared, a load or ALU result with its write-back enable
// cleared, and rd zeroed so that even a mis-muxed writeback downstream could not
// find a register to corrupt. Older instructions, already in MEM/WB, are untouched
// and retire normally - which is what makes the exception precise.
module pipe_ex_mem (
    input  wire        clk,
    input  wire        rst,
    input  wire        flush,   // the instruction in execute 2 raised an exception

    input  wire [31:0] i_alu_out,
    input  wire [31:0] i_rs2_data,
    input  wire [31:0] i_pc_plus4,
    input  wire [4:0]  i_rd,
    input  wire [1:0]  i_wb_sel,
    input  wire [1:0]  i_mem_width,
    input  wire        i_reg_w_ena,
    input  wire        i_mem_w_ena,
    input  wire        i_mem_signed,

    output wire [31:0] o_alu_out,
    output wire [31:0] o_rs2_data,
    output wire [31:0] o_pc_plus4,
    output wire [4:0]  o_rd,
    output wire [1:0]  o_wb_sel,
    output wire [1:0]  o_mem_width,
    output wire        o_reg_w_ena,
    output wire        o_mem_w_ena,
    output wire        o_mem_signed
);
    `include "defines.vh"

    // 3 words, 1 register address, 2 two-bit selects, 3 single-bit controls.
    localparam integer W = 32*3 + 5 + 2*2 + 3;

    localparam [W-1:0] BUBBLE = {
        32'h0, 32'h0, 32'h0,       // alu_out, rs2_data, pc_plus4
        5'h0,                      // rd
        `WB_ALU, `MEM_W,           // wb_sel, mem_width
        3'b0                       // reg_w_ena, mem_w_ena, mem_signed
    };

    // PACK, UNPACK and BUBBLE list the fields in the same order.
    wire [W-1:0] pack = {
        i_alu_out, i_rs2_data, i_pc_plus4,
        i_rd,
        i_wb_sel, i_mem_width,
        i_reg_w_ena, i_mem_w_ena, i_mem_signed
    };

    reg [W-1:0] q;

    always @(posedge clk) begin
        q <= (rst || flush) ? BUBBLE : pack;
    end

    assign { o_alu_out, o_rs2_data, o_pc_plus4,
             o_rd,
             o_wb_sel, o_mem_width,
             o_reg_w_ena, o_mem_w_ena, o_mem_signed } = q;
endmodule
