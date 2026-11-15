`timescale 1ns/1ns
// EX1/EX2 pipeline register
//
// Sits between the two execute halves: execute 1 computes the ALU result and
// the comparison flags, execute 2 resolves branches and the target PC.
//
// The comparison results are registered here rather than recomputed in execute
// 2, so the comparator sits in the same stage as the ALU and both feed the same
// register.
module pipe_ex1_ex2 (
    input  wire        clk,
    input  wire        rst,
    input  wire        flush,   // insert a bubble (branch redirect)

    input  wire [31:0] i_alu_out,
    input  wire [31:0] i_rs1_data,
    input  wire [31:0] i_rs2_data,
    input  wire [31:0] i_pc,
    input  wire [31:0] i_imm,
    input  wire [4:0]  i_rd,
    input  wire        i_reg_w_ena,
    input  wire        i_mem_w_ena,
    input  wire        i_mem_r_ena,
    input  wire        i_mem_signed,
    input  wire        i_jump,
    input  wire        i_jalr,
    input  wire        i_branch,
    input  wire        i_gt,
    input  wire        i_lt,
    input  wire        i_eq,
    input  wire [1:0]  i_wb_sel,
    input  wire [1:0]  i_mem_width,
    input  wire [2:0]  i_branch_cond,

    output wire [31:0] o_alu_out,
    output wire [31:0] o_rs1_data,
    output wire [31:0] o_rs2_data,
    output wire [31:0] o_pc,
    output wire [31:0] o_imm,
    output wire [4:0]  o_rd,
    output wire        o_reg_w_ena,
    output wire        o_mem_w_ena,
    output wire        o_mem_r_ena,
    output wire        o_mem_signed,
    output wire        o_jump,
    output wire        o_jalr,
    output wire        o_branch,
    output wire        o_gt,
    output wire        o_lt,
    output wire        o_eq,
    output wire [1:0]  o_wb_sel,
    output wire [1:0]  o_mem_width,
    output wire [2:0]  o_branch_cond
);
    `include "defines.vh"

    // 5 words, 1 register address (the write destination), 10 single-bit controls
    // (7 control + 3 comparison flags), 2 two-bit selects, 1 three-bit branch
    // condition. The source register numbers are NOT carried: forwarding decides
    // what the operands are in execute 1, and nothing downstream re-decodes them.
    localparam integer W = 32*5 + 5 + 10 + 2*2 + 3;

    localparam [W-1:0] BUBBLE = {
        32'h0, 32'h0, 32'h0, 32'h0, 32'h0,  // alu_out, rs1_data, rs2_data, pc, imm
        5'h0,                                // rd
        10'h0,                               // 7 control bits + gt, lt, eq
        `WB_ALU, `MEM_W,                     // wb_sel, mem_width
        `RV_F3_BEQ                           // branch_cond
    };

    // PACK, UNPACK and BUBBLE list the fields in the same order.
    wire [W-1:0] pack = {
        i_alu_out, i_rs1_data, i_rs2_data, i_pc, i_imm,
        i_rd,
        i_reg_w_ena, i_mem_w_ena, i_mem_r_ena, i_mem_signed, i_jump, i_jalr, i_branch,
        i_gt, i_lt, i_eq,
        i_wb_sel, i_mem_width,
        i_branch_cond
    };

    reg [W-1:0] q;

    always @(posedge clk) begin
        q <= (rst || flush) ? BUBBLE : pack;
    end

    assign { o_alu_out, o_rs1_data, o_rs2_data, o_pc, o_imm,
             o_rd,
             o_reg_w_ena, o_mem_w_ena, o_mem_r_ena, o_mem_signed, o_jump, o_jalr, o_branch,
             o_gt, o_lt, o_eq,
             o_wb_sel, o_mem_width,
             o_branch_cond } = q;
endmodule
