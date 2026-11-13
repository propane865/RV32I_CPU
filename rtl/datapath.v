// CPU datapath - wiring between the pipeline stages
//
// Six stages:      IF      ID       EX1        EX2       MEM      WB
//               fetch   decode  execute   resolve   memory  writeback
//                          |        |          |
//                    pipe_if_id  pipe_id_ex  pipe_ex1_ex2  pipe_ex_mem  pipe_mem_wb
//
// This file holds no control policy of its own any more: decode is in
// control.v, branch resolution in branch_unit.v, hazard policy in
// hazard_unit.v, and every staging register in its own pipe_*.v. What is left
// here is the interconnection and the two muxes the stages share (operand
// forwarding and writeback selection).
//
// The testbench pokes the memories and register file through the IMEM, DMEM and
// RF instance names, so those three instance names must not change.
module datapath(input clk, rst, output [31:0] pc_out, dmem_addr, dmem_wdata, dmem_rdata, output [1:0] dmem_width, output dmem_w_ena);
    `include "defines.vh"

    wire        stall_pc, stall_if_id, flush_if_id, flush_id_ex, flush_ex1_ex2;
    wire [1:0]  forward_a, forward_b;

    // ===============================================Stage 1 - Fetch===========
    wire [31:0] pc_current, pc_plus4, pc_target, instr_if;
    wire        pc_src;

    pc PC(
        .clk      (clk),
        .rst      (rst),
        .stall    (stall_pc),
        .pc_src   (pc_src),
        .pc_target(pc_target),
        .pc_out   (pc_current),
        .pc_plus4 (pc_plus4)
    );

    imem IMEM(.pc(pc_current), .instr(instr_if));

    wire [31:0] IF_ID_pc, IF_ID_instr;

    pipe_if_id IF_ID(
        .clk     (clk),
        .rst     (rst),
        .flush   (flush_if_id),
        .stall   (stall_if_id),
        .i_pc    (pc_current),
        .i_instr (instr_if),
        .o_pc    (IF_ID_pc),
        .o_instr (IF_ID_instr)
    );

    // ===============================================Stage 2 - Decode==========
    wire [6:0] id_opcode, id_funct7;
    wire [4:0] id_rd, id_rs1, id_rs2;
    wire [2:0] id_funct3;

    decoder DEC(
        .instr  (IF_ID_instr),
        .opcode (id_opcode),
        .rd     (id_rd), .rs1 (id_rs1), .rs2 (id_rs2),
        .funct3 (id_funct3), .funct7 (id_funct7)
    );

    wire        id_alu_src, id_alu_sgn,
                id_reg_w_ena, id_mem_w_ena, id_mem_signed, id_branch, id_jump, id_jalr;
    wire [1:0]  id_wb_sel, id_mem_width, id_alu_src_a;
    wire [3:0]  id_alu_op;
    wire [2:0]  id_imm_sel, id_branch_cond;

    control CTRL(
        .opcode     (id_opcode),
        .funct7     (id_funct7), .funct3 (id_funct3),
        .alu_src    (id_alu_src), .alu_src_a (id_alu_src_a),
        .reg_w_ena  (id_reg_w_ena), .mem_w_ena (id_mem_w_ena),
        .mem_signed (id_mem_signed),
        .alu_sgn    (id_alu_sgn),
        .branch     (id_branch), .jump (id_jump), .jalr (id_jalr),
        .wb_sel     (id_wb_sel), .mem_width (id_mem_width),
        .alu_op     (id_alu_op),
        .imm_sel    (id_imm_sel),
        .branch_cond(id_branch_cond)
    );

    reg [31:0]  wb_data;      // writeback mux output, driven in stage 6
    wire [4:0]  wb_rd;
    wire        wb_reg_w_ena;
    wire [31:0] id_rs1_data, id_rs2_data;

    regfile RF(
        .clk     (clk),
        .w_ena   (wb_reg_w_ena),
        .rs1     (id_rs1), .rs2 (id_rs2), .rd (wb_rd),
        .w_data  (wb_data), .r_data1 (id_rs1_data), .r_data2 (id_rs2_data)
    );

    wire [31:0] id_imm;

    imm_gen IMMGEN(
        .instr  (IF_ID_instr),
        .imm_sel(id_imm_sel),
        .imm    (id_imm)
    );

    wire [31:0] ID_EX_pc, ID_EX_rs1_data, ID_EX_rs2_data, ID_EX_imm;
    wire [4:0]  ID_EX_rs1, ID_EX_rs2, ID_EX_rd;
    wire        ID_EX_alu_src, ID_EX_alu_sgn,
                ID_EX_reg_w_ena, ID_EX_mem_w_ena, ID_EX_mem_signed,
                ID_EX_branch, ID_EX_jump, ID_EX_jalr;
    wire [1:0]  ID_EX_wb_sel, ID_EX_mem_width, ID_EX_alu_src_a;
    wire [3:0]  ID_EX_alu_op;
    wire [2:0]  ID_EX_branch_cond;

    pipe_id_ex ID_EX(
        .clk            (clk),
        .rst            (rst),
        .flush          (flush_id_ex),
        .i_pc           (IF_ID_pc),
        .i_rs1_data     (id_rs1_data),
        .i_rs2_data     (id_rs2_data),
        .i_imm          (id_imm),
        .i_rs1          (id_rs1),
        .i_rs2          (id_rs2),
        .i_rd           (id_rd),
        .i_alu_src      (id_alu_src),
        .i_alu_sgn      (id_alu_sgn),
        .i_reg_w_ena    (id_reg_w_ena),
        .i_mem_w_ena    (id_mem_w_ena),
        .i_mem_signed   (id_mem_signed),
        .i_branch       (id_branch),
        .i_jump         (id_jump),
        .i_jalr         (id_jalr),
        .i_wb_sel       (id_wb_sel),
        .i_mem_width    (id_mem_width),
        .i_alu_src_a    (id_alu_src_a),
        .i_alu_op       (id_alu_op),
        .i_branch_cond  (id_branch_cond),
        .o_pc           (ID_EX_pc),
        .o_rs1_data     (ID_EX_rs1_data),
        .o_rs2_data     (ID_EX_rs2_data),
        .o_imm          (ID_EX_imm),
        .o_rs1          (ID_EX_rs1),
        .o_rs2          (ID_EX_rs2),
        .o_rd           (ID_EX_rd),
        .o_alu_src      (ID_EX_alu_src),
        .o_alu_sgn      (ID_EX_alu_sgn),
        .o_reg_w_ena    (ID_EX_reg_w_ena),
        .o_mem_w_ena    (ID_EX_mem_w_ena),
        .o_mem_signed   (ID_EX_mem_signed),
        .o_branch       (ID_EX_branch),
        .o_jump         (ID_EX_jump),
        .o_jalr         (ID_EX_jalr),
        .o_wb_sel       (ID_EX_wb_sel),
        .o_mem_width    (ID_EX_mem_width),
        .o_alu_src_a    (ID_EX_alu_src_a),
        .o_alu_op       (ID_EX_alu_op),
        .o_branch_cond  (ID_EX_branch_cond)
    );

    // ===============================================Stage 3 - Execute 1=======
    // Operand forwarding: prefer the youngest pending writer of a register.
    wire [31:0] fwd_rs1, fwd_rs2;

    assign fwd_rs1 = (forward_a == `FWD_EX1)   ? EX1_EX2_alu_out :
                     (forward_a == `FWD_EXMEM) ? EX_MEM_alu_out :
                     (forward_a == `FWD_MEMWB) ? wb_data : ID_EX_rs1_data;
    assign fwd_rs2 = (forward_b == `FWD_EX1)   ? EX1_EX2_alu_out :
                     (forward_b == `FWD_EXMEM) ? EX_MEM_alu_out :
                     (forward_b == `FWD_MEMWB) ? wb_data : ID_EX_rs2_data;

    // ALU input A: the immediate (LUI), the PC (AUIPC), or rs1.
    // ALU input B: the immediate for register-immediate ops, otherwise rs2.
    wire [31:0] alu_a, alu_b;

    assign alu_a = (ID_EX_alu_src_a == `ALU_A_IMM) ? ID_EX_imm :
                   (ID_EX_alu_src_a == `ALU_A_PC)  ? ID_EX_pc  : fwd_rs1;
    assign alu_b = ID_EX_alu_src ? ID_EX_imm : fwd_rs2;

    wire [31:0] ex_alu_out;
    wire        ex_gt_b, ex_lt_b, ex_eq_b;

    // Branch comparisons are taken from the forwarded operands, not the ALU
    // inputs, because a branch never uses the immediate.
    comp32 BCOMP(
        .a  (fwd_rs1), .b (fwd_rs2),
        .u  (~ID_EX_alu_sgn),
        .gt (ex_gt_b), .lt (ex_lt_b), .eq (ex_eq_b)
    );

    // The comparator's results are shared between the ALU (for SLT/SLTU) and the
    // branch unit (for the taken decision).
    alu ALU(
        .a   (alu_a),
        .b   (alu_b),
        .op  (ID_EX_alu_op),
        .lt  (ex_lt_b),
        .out (ex_alu_out)
    );

    wire [31:0] EX1_EX2_alu_out, EX1_EX2_rs1_data, EX1_EX2_rs2_data;
    wire [31:0] EX1_EX2_pc, EX1_EX2_imm;
    wire [4:0]  EX1_EX2_rs1, EX1_EX2_rs2, EX1_EX2_rd;
    wire [2:0]  EX1_EX2_branch_cond;
    wire [1:0]  EX1_EX2_wb_sel, EX1_EX2_mem_width;
    wire        EX1_EX2_reg_w_ena, EX1_EX2_mem_w_ena, EX1_EX2_mem_signed;
    wire        EX1_EX2_jump, EX1_EX2_jalr, EX1_EX2_branch;
    wire        EX1_EX2_gt, EX1_EX2_lt, EX1_EX2_eq;

    pipe_ex1_ex2 EX1_EX2(
        .clk           (clk),
        .rst           (rst),
        .flush         (flush_ex1_ex2),
        .i_alu_out     (ex_alu_out),
        .i_rs1_data    (fwd_rs1),
        .i_rs2_data    (fwd_rs2),
        .i_pc          (ID_EX_pc),
        .i_imm         (ID_EX_imm),
        .i_rs1         (ID_EX_rs1),
        .i_rs2         (ID_EX_rs2),
        .i_rd          (ID_EX_rd),
        .i_reg_w_ena   (ID_EX_reg_w_ena),
        .i_mem_w_ena   (ID_EX_mem_w_ena),
        .i_mem_signed  (ID_EX_mem_signed),
        .i_jump        (ID_EX_jump),
        .i_jalr        (ID_EX_jalr),
        .i_branch      (ID_EX_branch),
        .i_gt          (ex_gt_b),
        .i_lt          (ex_lt_b),
        .i_eq          (ex_eq_b),
        .i_wb_sel      (ID_EX_wb_sel),
        .i_mem_width   (ID_EX_mem_width),
        .i_branch_cond (ID_EX_branch_cond),
        .o_alu_out     (EX1_EX2_alu_out),
        .o_rs1_data    (EX1_EX2_rs1_data),
        .o_rs2_data    (EX1_EX2_rs2_data),
        .o_pc          (EX1_EX2_pc),
        .o_imm         (EX1_EX2_imm),
        .o_rs1         (EX1_EX2_rs1),
        .o_rs2         (EX1_EX2_rs2),
        .o_rd          (EX1_EX2_rd),
        .o_reg_w_ena   (EX1_EX2_reg_w_ena),
        .o_mem_w_ena   (EX1_EX2_mem_w_ena),
        .o_mem_signed  (EX1_EX2_mem_signed),
        .o_jump        (EX1_EX2_jump),
        .o_jalr        (EX1_EX2_jalr),
        .o_branch      (EX1_EX2_branch),
        .o_gt          (EX1_EX2_gt),
        .o_lt          (EX1_EX2_lt),
        .o_eq          (EX1_EX2_eq),
        .o_wb_sel      (EX1_EX2_wb_sel),
        .o_mem_width   (EX1_EX2_mem_width),
        .o_branch_cond (EX1_EX2_branch_cond)
    );

    // ===============================================Stage 4 - Execute 2=======
    // Branch/jump resolution and the redirect target. The writeback link value
    // (pc+4) is computed here because this is the stage that owns the PC.
    wire [31:0] ex_pc_plus4;

    branch_unit BRU(
        .i_branch_cond(EX1_EX2_branch_cond),
        .i_branch     (EX1_EX2_branch),
        .i_jump       (EX1_EX2_jump),
        .i_jalr       (EX1_EX2_jalr),
        .i_gt         (EX1_EX2_gt),
        .i_lt         (EX1_EX2_lt),
        .i_eq         (EX1_EX2_eq),
        .i_pc         (EX1_EX2_pc),
        .i_rs1_data   (EX1_EX2_rs1_data),
        .i_imm        (EX1_EX2_imm),
        .o_redirect   (pc_src),
        .o_target     (pc_target),
        .o_pc_plus4   (ex_pc_plus4)
    );

    wire [31:0] EX_MEM_alu_out, EX_MEM_rs2_data, EX_MEM_pc_plus4;
    wire [4:0]  EX_MEM_rd;
    wire [1:0]  EX_MEM_wb_sel, EX_MEM_mem_width;
    wire        EX_MEM_reg_w_ena, EX_MEM_mem_w_ena, EX_MEM_mem_signed;

    pipe_ex_mem EX_MEM(
        .clk          (clk),
        .rst          (rst),
        .i_alu_out    (EX1_EX2_alu_out),
        .i_rs2_data   (EX1_EX2_rs2_data),
        .i_pc_plus4   (ex_pc_plus4),
        .i_rd         (EX1_EX2_rd),
        .i_wb_sel     (EX1_EX2_wb_sel),
        .i_mem_width  (EX1_EX2_mem_width),
        .i_reg_w_ena  (EX1_EX2_reg_w_ena),
        .i_mem_w_ena  (EX1_EX2_mem_w_ena),
        .i_mem_signed (EX1_EX2_mem_signed),
        .o_alu_out    (EX_MEM_alu_out),
        .o_rs2_data   (EX_MEM_rs2_data),
        .o_pc_plus4   (EX_MEM_pc_plus4),
        .o_rd         (EX_MEM_rd),
        .o_wb_sel     (EX_MEM_wb_sel),
        .o_mem_width  (EX_MEM_mem_width),
        .o_reg_w_ena  (EX_MEM_reg_w_ena),
        .o_mem_w_ena  (EX_MEM_mem_w_ena),
        .o_mem_signed (EX_MEM_mem_signed)
    );

    // ===============================================Stage 5 - Memory==========
    // The access address is the ALU result and the store data is rs2, both
    // carried down from the execute stages.
    wire [31:0] mem_rdata;

    dmem DMEM(
        .clk      (clk), .w_ena (EX_MEM_mem_w_ena),
        .width    (EX_MEM_mem_width), .is_signed (EX_MEM_mem_signed),
        .addr     (EX_MEM_alu_out),
        .w_data   (EX_MEM_rs2_data), .r_data (mem_rdata)
    );

    wire [31:0] MEM_WB_alu_out, MEM_WB_mem_rdata, MEM_WB_pc_plus4;
    wire [4:0]  MEM_WB_rd;
    wire [1:0]  MEM_WB_wb_sel;
    wire        MEM_WB_reg_w_ena;

    pipe_mem_wb MEM_WB(
        .clk          (clk),
        .rst          (rst),
        .i_alu_out    (EX_MEM_alu_out),
        .i_mem_rdata  (mem_rdata),
        .i_pc_plus4   (EX_MEM_pc_plus4),
        .i_rd         (EX_MEM_rd),
        .i_wb_sel     (EX_MEM_wb_sel),
        .i_reg_w_ena  (EX_MEM_reg_w_ena),
        .o_alu_out    (MEM_WB_alu_out),
        .o_mem_rdata  (MEM_WB_mem_rdata),
        .o_pc_plus4   (MEM_WB_pc_plus4),
        .o_rd         (MEM_WB_rd),
        .o_wb_sel     (MEM_WB_wb_sel),
        .o_reg_w_ena  (MEM_WB_reg_w_ena)
    );

    // ===============================================Stage 6 - Writeback=======
    assign wb_reg_w_ena = MEM_WB_reg_w_ena;
    assign wb_rd        = MEM_WB_rd;

    always @(*) begin
        case (MEM_WB_wb_sel)
            `WB_ALU: wb_data = MEM_WB_alu_out;
            `WB_MEM: wb_data = MEM_WB_mem_rdata;
            `WB_PC4: wb_data = MEM_WB_pc_plus4;
            default: wb_data = 32'h0;
        endcase
    end

    // ===============================================Hazard Unit===============
    hazard_unit HU(
        .i_id_ex_reg_w_ena(ID_EX_reg_w_ena),
        .i_id_ex_mem_w_ena(ID_EX_mem_w_ena),
        .i_id_ex_wb_sel  (ID_EX_wb_sel),
        .i_id_ex_rd      (ID_EX_rd),
        .i_if_id_rs1     (id_rs1),
        .i_if_id_rs2     (id_rs2),
        .i_pc_redirect   (pc_src),
        .o_stall_pc      (stall_pc),
        .o_stall_if_id   (stall_if_id),
        .o_flush_if_id   (flush_if_id),
        .o_flush_id_ex   (flush_id_ex),
        .o_flush_ex1_ex2 (flush_ex1_ex2)
    );

    // ===============================================Forwarding Unit===========
    forwarding_unit FWU(
        .ex1_ex2_reg_w_ena(EX1_EX2_reg_w_ena),
        .ex_mem_reg_w_ena (EX_MEM_reg_w_ena),
        .ex_mem_rd        (EX_MEM_rd),
        .ex1_ex2_rd       (EX1_EX2_rd),
        .mem_wb_reg_w_ena (MEM_WB_reg_w_ena),
        .mem_wb_rd        (MEM_WB_rd),
        .id_ex_rs1        (ID_EX_rs1),
        .id_ex_rs2        (ID_EX_rs2),
        .forward_a        (forward_a),
        .forward_b        (forward_b)
    );

    // Map internal signals to outputs
    assign pc_out     = pc_current;
    assign dmem_addr  = EX_MEM_alu_out;
    assign dmem_wdata = EX_MEM_rs2_data;
    assign dmem_rdata = mem_rdata;
    assign dmem_w_ena = EX_MEM_mem_w_ena;
    assign dmem_width = EX_MEM_mem_width;
endmodule
