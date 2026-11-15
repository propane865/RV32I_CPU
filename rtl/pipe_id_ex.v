`timescale 1ns/1ns
// ID/EX pipeline register
//
// Carries the decoded instruction from the decode stage into execute 1: the
// read register operands, the immediate, the PC, and every control field the
// ALU, memory and writeback stages will need.
//
// This used to be 22 individual regs with a hand-written reset list of 22
// assignments, which had to be kept in sync with the 22 loading assignments by
// eye. The payload is now one vector, and the bubble is one named constant:
// "what a flushed slot looks like" is stated once, in one place.
module pipe_id_ex (
    input  wire        clk,
    input  wire        rst,
    input  wire        flush,   // insert a bubble (load-use stall or branch)

    input  wire [31:0] i_pc,
    input  wire [31:0] i_rs1_data,
    input  wire [31:0] i_rs2_data,
    input  wire [31:0] i_imm,
    input  wire [4:0]  i_rs1,
    input  wire [4:0]  i_rs2,
    input  wire [4:0]  i_rd,
    input  wire        i_alu_src,
    input  wire        i_cmp_sgn,
    input  wire        i_reg_w_ena,
    input  wire        i_mem_w_ena,
    input  wire        i_mem_r_ena,
    input  wire        i_mem_signed,
    input  wire        i_branch,
    input  wire        i_jump,
    input  wire        i_jalr,
    input  wire [1:0]  i_wb_sel,
    input  wire [1:0]  i_mem_width,
    input  wire [1:0]  i_alu_src_a,
    input  wire [3:0]  i_alu_op,
    input  wire [2:0]  i_branch_cond,

    output wire [31:0] o_pc,
    output wire [31:0] o_rs1_data,
    output wire [31:0] o_rs2_data,
    output wire [31:0] o_imm,
    output wire [4:0]  o_rs1,
    output wire [4:0]  o_rs2,
    output wire [4:0]  o_rd,
    output wire        o_alu_src,
    output wire        o_cmp_sgn,
    output wire        o_reg_w_ena,
    output wire        o_mem_w_ena,
    output wire        o_mem_r_ena,
    output wire        o_mem_signed,
    output wire        o_branch,
    output wire        o_jump,
    output wire        o_jalr,
    output wire [1:0]  o_wb_sel,
    output wire [1:0]  o_mem_width,
    output wire [1:0]  o_alu_src_a,
    output wire [3:0]  o_alu_op,
    output wire [2:0]  o_branch_cond
);
    `include "defines.vh"

    // Payload width, spelled out so PACK / UNPACK / BUBBLE cannot drift apart
    // silently: 4 words, 3 register addresses, 9 single-bit controls, 3 two-bit
    // selects, one 4-bit ALU op and one 3-bit branch condition.
    localparam integer W = 32*4 + 5*3 + 9 + 2*3 + 4 + 3;

    // A flushed slot writes nothing anywhere. mem_width is preset to a full word
    // so that a stray enable could never turn into a partial store.
    localparam [W-1:0] BUBBLE = {
        32'h0, 32'h0, 32'h0, 32'h0,          // pc, rs1_data, rs2_data, imm
        5'h0, 5'h0, 5'h0,                    // rs1, rs2, rd
        9'h0,                                // the 9 single-bit controls
        `WB_ALU, `MEM_W, `ALU_A_RS1,         // wb_sel, mem_width, alu_src_a
        `ALU_ADD, `RV_F3_BEQ                 // alu_op (4b), branch_cond
    };

    // PACK, UNPACK and BUBBLE list the fields in the same order.
    wire [W-1:0] pack = {
        i_pc, i_rs1_data, i_rs2_data, i_imm,
        i_rs1, i_rs2, i_rd,
        i_alu_src, i_cmp_sgn,
        i_reg_w_ena, i_mem_w_ena, i_mem_r_ena, i_mem_signed, i_branch, i_jump, i_jalr,
        i_wb_sel, i_mem_width, i_alu_src_a,
        i_alu_op, i_branch_cond
    };

    reg [W-1:0] q;

    always @(posedge clk) begin
        q <= (rst || flush) ? BUBBLE : pack;
    end

    assign { o_pc, o_rs1_data, o_rs2_data, o_imm,
             o_rs1, o_rs2, o_rd,
             o_alu_src, o_cmp_sgn,
             o_reg_w_ena, o_mem_w_ena, o_mem_r_ena, o_mem_signed, o_branch, o_jump, o_jalr,
             o_wb_sel, o_mem_width, o_alu_src_a,
             o_alu_op, o_branch_cond } = q;
endmodule
