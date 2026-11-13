`timescale 1ns/1ns
// Branch unit - execute 2
//
// Decides whether the instruction in execute 2 redirects the PC, and to where.
//
// Previously this logic sat inline in the datapath, mixed in with the pipeline
// registers, where the branch-condition table was written in raw 3'b100 style
// literals. That is how the signed/unsigned branch bug stayed hidden: the BLT
// and BLTU rows are literally the same expression (see below), so the only
// thing that can distinguish them is the comparison's signedness - which is not
// a signal in this module at all.
module branch_unit (
    input  wire [2:0]  i_branch_cond,   // funct3 of the branch instruction
    input  wire        i_branch,
    input  wire        i_jump,
    input  wire        i_jalr,
    input  wire        i_gt,            // comparison flags from execute 1
    input  wire        i_lt,
    input  wire        i_eq,
    input  wire [31:0] i_pc,
    input  wire [31:0] i_rs1_data,      // JALR base
    input  wire [31:0] i_imm,           // branch / JAL / JALR offset

    output wire        o_redirect,      // take the PC away from pc+4
    output wire [31:0] o_target,
    output wire [31:0] o_pc_plus4       // link address for JAL / JALR
);
    `include "defines.vh"

    reg condition_met;

    always @(*) begin
        case (i_branch_cond)
            `RV_F3_BEQ:  condition_met = i_eq;
            `RV_F3_BNE:  condition_met = ~i_eq;
            // BLT and BLTU are the same expression here, and so are BGE/BGEU:
            // this core does not yet tell the comparator which comparison is
            // wanted, so signed branches currently behave as unsigned.
            `RV_F3_BLT:  condition_met = i_lt;
            `RV_F3_BGE:  condition_met = i_gt | i_eq;
            `RV_F3_BLTU: condition_met = i_lt;
            `RV_F3_BGEU: condition_met = i_gt | i_eq;
            // funct3 values 2 and 3 are not branches.
            default:     condition_met = 1'b0;
        endcase
    end

    assign o_redirect = i_jump | (i_branch & condition_met);

    // Full custom carry-look-ahead adders rather than '+': the ASIC build is
    // timing-driven and these two sit on the redirect path. The carries are not
    // needed, only the sums.
    wire [31:0] jalr_target;
    wire [31:0] branch_target;

    ks32 jalr_adder (
        .a    (i_rs1_data),
        .b    (i_imm),
        .cin  (1'b0),
        .sum  (jalr_target),
        .cout ()
    );

    ks32 branch_adder (
        .a    (i_pc),
        .b    (i_imm),
        .cin  (1'b0),
        .sum  (branch_target),
        .cout ()
    );

    // JALR clears bit 0 of the target; branch and JAL offsets are already even.
    assign o_target   = i_jalr ? (jalr_target & ~32'b1) : branch_target;
    assign o_pc_plus4 = i_pc + 32'h4;
endmodule
