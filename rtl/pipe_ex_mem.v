`timescale 1ns/1ns
// EX/MEM pipeline register
//
// Carries the executed instruction into the memory stage.
//
// There is deliberately no flush input: a branch or jump resolved in execute 2
// squashes only the two younger slots (IF/ID and ID/EX). Everything already in
// EX/MEM and MEM/WB is older than the branch and must retire normally.
module pipe_ex_mem (
    input  wire        clk,
    input  wire        rst,

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
        q <= rst ? BUBBLE : pack;
    end

    assign { o_alu_out, o_rs2_data, o_pc_plus4,
             o_rd,
             o_wb_sel, o_mem_width,
             o_reg_w_ena, o_mem_w_ena, o_mem_signed } = q;
endmodule
