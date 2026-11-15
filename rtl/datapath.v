`timescale 1ns/1ns
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

    // Core stop. Held low until the trap path exists: a trap is detected in
    // execute 2, one stage after a redirect, and stopping the fetch is the only
    // thing that keeps a stopped core from putting another instruction in flight.
    // See rtl/trap_unit.v for the logic that will drive it.
    wire halt = 1'b0;

    // ===============================================Stage 1 - Fetch===========
    wire [31:0] pc_current, pc_target, instr_if;
    wire        pc_src;

    pc PC(
        .clk      (clk),
        .rst      (rst),
        .stall    (stall_pc),
        .halt     (halt),
        .pc_src   (pc_src),
        .pc_target(pc_target),
        .pc_out   (pc_current)
    );

    imem IMEM(.pc(pc_current), .instr(instr_if));

    wire [31:0] ifid_pc, ifid_instr;

    pipe_if_id IF_ID(
        .clk     (clk),
        .rst     (rst),
        .flush   (flush_if_id),
        .stall   (stall_if_id),
        .i_pc    (pc_current),
        .i_instr (instr_if),
        .o_pc    (ifid_pc),
        .o_instr (ifid_instr)
    );

    // ===============================================Stage 2 - Decode==========
    wire [6:0] id_opcode, id_funct7;
    wire [4:0] id_rd, id_rs1, id_rs2;
    wire [2:0] id_funct3;

    decoder DEC(
        .instr  (ifid_instr),
        .opcode (id_opcode),
        .rd     (id_rd), .rs1 (id_rs1), .rs2 (id_rs2),
        .funct3 (id_funct3), .funct7 (id_funct7)
    );

    wire        id_alu_src, id_cmp_sgn,
                id_reg_w_ena, id_mem_w_ena, id_mem_r_ena, id_mem_signed,
                id_uses_rs1, id_uses_rs2,
                id_branch, id_jump, id_jalr;
    wire [1:0]  id_wb_sel, id_mem_width, id_alu_src_a;
    wire [3:0]  id_alu_op;
    wire [2:0]  id_imm_sel, id_branch_cond;

    control CTRL(
        .opcode     (id_opcode),
        .funct7     (id_funct7), .funct3 (id_funct3),
        // instr[31:20], for the two SYSTEM encodings ECALL and EBREAK - see
        // rtl/control.v. The immediate itself is generated from the same field by
        // imm_gen, but the decode verdict is about the encoding, not a value, so it
        // is asked here rather than inferred downstream from imm.
        .imm12      (ifid_instr[31:20]),
        .alu_src    (id_alu_src), .alu_src_a (id_alu_src_a),
        .reg_w_ena  (id_reg_w_ena), .mem_w_ena (id_mem_w_ena),
        .mem_r_ena  (id_mem_r_ena),
        .mem_signed (id_mem_signed),
        .uses_rs1   (id_uses_rs1), .uses_rs2 (id_uses_rs2),
        .cmp_sgn    (id_cmp_sgn),
        .branch     (id_branch), .jump (id_jump), .jalr (id_jalr),
        .wb_sel     (id_wb_sel), .mem_width (id_mem_width),
        .alu_op     (id_alu_op),
        .imm_sel    (id_imm_sel),
        .branch_cond(id_branch_cond),
        // Decode verdicts about the encoding rather than about execution: no case
        // arm owns them, and nothing in the pipeline acts on them. An instruction
        // control.v calls illegal already asserts nothing at all, which is why the
        // pins are empty rather than tied into a control path - the consumer is the
        // exception report, which is not a control signal of this core.
        .illegal    (),
        .is_fence   (),
        .is_ecall   (),
        .is_ebreak  ()
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
        .instr  (ifid_instr),
        .imm_sel(id_imm_sel),
        .imm    (id_imm)
    );

    wire [31:0] idex_pc, idex_rs1_data, idex_rs2_data, idex_imm;
    wire [4:0]  idex_rs1, idex_rs2, idex_rd;
    wire        idex_alu_src, idex_cmp_sgn,
                idex_reg_w_ena, idex_mem_w_ena, idex_mem_r_ena, idex_mem_signed,
                idex_branch, idex_jump, idex_jalr;
    wire [1:0]  idex_wb_sel, idex_mem_width, idex_alu_src_a;
    wire [3:0]  idex_alu_op;
    wire [2:0]  idex_branch_cond;

    pipe_id_ex ID_EX(
        .clk            (clk),
        .rst            (rst),
        .flush          (flush_id_ex),
        .i_pc           (ifid_pc),
        .i_rs1_data     (id_rs1_data),
        .i_rs2_data     (id_rs2_data),
        .i_imm          (id_imm),
        .i_rs1          (id_rs1),
        .i_rs2          (id_rs2),
        .i_rd           (id_rd),
        .i_alu_src      (id_alu_src),
        .i_cmp_sgn      (id_cmp_sgn),
        .i_reg_w_ena    (id_reg_w_ena),
        .i_mem_w_ena    (id_mem_w_ena),
        .i_mem_r_ena    (id_mem_r_ena),
        .i_mem_signed   (id_mem_signed),
        .i_branch       (id_branch),
        .i_jump         (id_jump),
        .i_jalr         (id_jalr),
        .i_wb_sel       (id_wb_sel),
        .i_mem_width    (id_mem_width),
        .i_alu_src_a    (id_alu_src_a),
        .i_alu_op       (id_alu_op),
        .i_branch_cond  (id_branch_cond),
        .o_pc           (idex_pc),
        .o_rs1_data     (idex_rs1_data),
        .o_rs2_data     (idex_rs2_data),
        .o_imm          (idex_imm),
        .o_rs1          (idex_rs1),
        .o_rs2          (idex_rs2),
        .o_rd           (idex_rd),
        .o_alu_src      (idex_alu_src),
        .o_cmp_sgn      (idex_cmp_sgn),
        .o_reg_w_ena    (idex_reg_w_ena),
        .o_mem_w_ena    (idex_mem_w_ena),
        .o_mem_r_ena    (idex_mem_r_ena),
        .o_mem_signed   (idex_mem_signed),
        .o_branch       (idex_branch),
        .o_jump         (idex_jump),
        .o_jalr         (idex_jalr),
        .o_wb_sel       (idex_wb_sel),
        .o_mem_width    (idex_mem_width),
        .o_alu_src_a    (idex_alu_src_a),
        .o_alu_op       (idex_alu_op),
        .o_branch_cond  (idex_branch_cond)
    );

    // ===============================================Stage 3 - Execute 1=======
    // Operand forwarding: prefer the youngest pending writer of a register.
    // Which value a forwarding select actually means, applied to both operand
    // lanes from one definition. As in forwarding_unit.v, this is a generate over
    // the two lanes rather than a function: a function called from a continuous
    // assignment is only sensitive to its arguments, which silently produces stale
    // operands. The select encodings come from defines.vh, so they are interpreted
    // in exactly one place for both operands.
    // The two forwarding sources that live downstream of this stage. Their
    // drivers are the staging registers instantiated further down, but they are
    // declared here because the FWD generate block below reads them: a generate
    // block scope resolves a name in the enclosing module scope where it is used,
    // so a net referenced inside the block must already be declared or
    // elaboration fails (iverilog: "Unable to bind ... declaration after use").
    // The continuous assignments themselves stay order independent.
    wire [31:0] ex1ex2_alu_out;   // execute 1 result, one instruction ahead
    wire [31:0] exmem_alu_out;    // memory  stage result, two ahead
    // The link value a JAL/JALR writes. Computed by the branch unit, which owns
    // the PC of the instruction in execute 2 - and that is exactly the producer
    // the FWD_EX1 case below has to value, in the same cycle, so no extra copy of
    // it needs to be pipelined. Declared here for the same reason as the two above.
    wire [31:0] ex_pc_plus4;
    // ... and the copy of it that travels to the memory stage, which is the FWD_EXMEM
    // producer's link value two cycles later. Same declaration-order constraint as
    // above.
    wire [31:0] exmem_pc_plus4;

    // What each producer stage would actually write to the register file. This is
    // not always its ALU result: a JAL or JALR writes pc+4, which never appears at
    // the ALU output, so a forward that ignored wb_sel handed the consumer the sum
    // of two arbitrary operands instead of the link address.
    //
    // The load case is marked impossible rather than given a value. A load's data
    // does not exist this early - see rtl/hazard_unit.v, whose stall is exactly what
    // guarantees no forwarding select can ask for it - and returning the ALU
    // result, which is the load address, is the bug this replaces: plausible
    // enough to pass a test that happens to space its instructions out. Propagating
    // an unknown is the honest answer, and the one a test catches.
    wire [31:0] ex1ex2_fwd_data =
        (ex1ex2_wb_sel == `WB_PC4) ? ex_pc_plus4   :
        (ex1ex2_wb_sel == `WB_MEM) ? 32'hxxxx_xxxx : ex1ex2_alu_out;

    wire [31:0] exmem_fwd_data =
        (exmem_wb_sel == `WB_PC4) ? exmem_pc_plus4 :
        (exmem_wb_sel == `WB_MEM) ? 32'hxxxx_xxxx  : exmem_alu_out;

    wire [31:0] fwd_lane [0:1];

    genvar fwd_lane_ix;
    generate
        for (fwd_lane_ix = 0; fwd_lane_ix < 2; fwd_lane_ix = fwd_lane_ix + 1) begin : FWD
            wire [1:0]  sel         = (fwd_lane_ix == 0) ? forward_a    : forward_b;
            wire [31:0] register_value = (fwd_lane_ix == 0) ? idex_rs1_data : idex_rs2_data;

            assign fwd_lane[fwd_lane_ix] =
                (sel == `FWD_EX1)   ? ex1ex2_fwd_data :
                (sel == `FWD_EXMEM) ? exmem_fwd_data :
                (sel == `FWD_MEMWB) ? wb_data : register_value;
        end
    endgenerate

    wire [31:0] fwd_rs1 = fwd_lane[0];
    wire [31:0] fwd_rs2 = fwd_lane[1];

    // ALU input A: the immediate (LUI), the PC (AUIPC), or rs1.
    // ALU input B: the immediate for register-immediate ops, otherwise rs2.
    wire [31:0] alu_a, alu_b;

    assign alu_a = (idex_alu_src_a == `ALU_A_IMM) ? idex_imm :
                   (idex_alu_src_a == `ALU_A_PC)  ? idex_pc  : fwd_rs1;
    assign alu_b = idex_alu_src ? idex_imm : fwd_rs2;

    wire [31:0] ex_alu_out;
    wire        ex_gt_b, ex_lt_b, ex_eq_b;

    // Branch comparisons are taken from the forwarded operands, not the ALU
    // inputs, because a branch never uses the immediate.
    comp32 BCOMP(
        .a  (fwd_rs1), .b (fwd_rs2),
        .u  (~idex_cmp_sgn),
        .gt (ex_gt_b), .lt (ex_lt_b), .eq (ex_eq_b)
    );

    // The comparator's results are shared between the ALU (for SLT/SLTU) and the
    // branch unit (for the taken decision).
    alu ALU(
        .a   (alu_a),
        .b   (alu_b),
        .op  (idex_alu_op),
        .lt  (ex_lt_b),
        .out (ex_alu_out)
    );

    // (ex1ex2_alu_out is declared with the forwarding sources, in stage 3.)
    wire [31:0] ex1ex2_rs1_data, ex1ex2_rs2_data;
    wire [31:0] ex1ex2_pc, ex1ex2_imm;
    wire [4:0]  ex1ex2_rd;
    wire [2:0]  ex1ex2_branch_cond;
    wire [1:0]  ex1ex2_wb_sel, ex1ex2_mem_width;
    wire        ex1ex2_reg_w_ena, ex1ex2_mem_w_ena, ex1ex2_mem_r_ena, ex1ex2_mem_signed;
    wire        ex1ex2_jump, ex1ex2_jalr, ex1ex2_branch;
    wire        ex1ex2_gt, ex1ex2_lt, ex1ex2_eq;

    pipe_ex1_ex2 EX1_EX2(
        .clk           (clk),
        .rst           (rst),
        .flush         (flush_ex1_ex2),
        .i_alu_out     (ex_alu_out),
        .i_rs1_data    (fwd_rs1),
        .i_rs2_data    (fwd_rs2),
        .i_pc          (idex_pc),
        .i_imm         (idex_imm),
        .i_rd          (idex_rd),
        .i_reg_w_ena   (idex_reg_w_ena),
        .i_mem_w_ena   (idex_mem_w_ena),
        .i_mem_r_ena   (idex_mem_r_ena),
        .i_mem_signed  (idex_mem_signed),
        .i_jump        (idex_jump),
        .i_jalr        (idex_jalr),
        .i_branch      (idex_branch),
        .i_gt          (ex_gt_b),
        .i_lt          (ex_lt_b),
        .i_eq          (ex_eq_b),
        .i_wb_sel      (idex_wb_sel),
        .i_mem_width   (idex_mem_width),
        .i_branch_cond (idex_branch_cond),
        .o_alu_out     (ex1ex2_alu_out),
        .o_rs1_data    (ex1ex2_rs1_data),
        .o_rs2_data    (ex1ex2_rs2_data),
        .o_pc          (ex1ex2_pc),
        .o_imm         (ex1ex2_imm),
        .o_rd          (ex1ex2_rd),
        .o_reg_w_ena   (ex1ex2_reg_w_ena),
        .o_mem_w_ena   (ex1ex2_mem_w_ena),
        .o_mem_r_ena   (ex1ex2_mem_r_ena),
        .o_mem_signed  (ex1ex2_mem_signed),
        .o_jump        (ex1ex2_jump),
        .o_jalr        (ex1ex2_jalr),
        .o_branch      (ex1ex2_branch),
        .o_gt          (ex1ex2_gt),
        .o_lt          (ex1ex2_lt),
        .o_eq          (ex1ex2_eq),
        .o_wb_sel      (ex1ex2_wb_sel),
        .o_mem_width   (ex1ex2_mem_width),
        .o_branch_cond (ex1ex2_branch_cond)
    );

    // ===============================================Stage 4 - Execute 2=======
    // Branch/jump resolution and the redirect target. The writeback link value
    // (pc+4) is computed here because this is the stage that owns the PC; it is
    // declared with the forwarding sources in stage 3, because the forwarding mux
    // needs the link value of a jump in execute 2 just as much as EX/MEM does.

    branch_unit BRU(
        .i_branch_cond(ex1ex2_branch_cond),
        .i_branch     (ex1ex2_branch),
        .i_jump       (ex1ex2_jump),
        .i_jalr       (ex1ex2_jalr),
        .i_gt         (ex1ex2_gt),
        .i_lt         (ex1ex2_lt),
        .i_eq         (ex1ex2_eq),
        .i_pc         (ex1ex2_pc),
        .i_rs1_data   (ex1ex2_rs1_data),
        .i_imm        (ex1ex2_imm),
        .o_redirect   (pc_src),
        .o_target     (pc_target),
        .o_pc_plus4   (ex_pc_plus4)
    );

    // (exmem_alu_out is declared with the forwarding sources, in stage 3.)
    wire [31:0] exmem_rs2_data;
    wire [4:0]  exmem_rd;
    wire [1:0]  exmem_wb_sel, exmem_mem_width;
    wire        exmem_reg_w_ena, exmem_mem_w_ena, exmem_mem_signed;

    pipe_ex_mem EX_MEM(
        .clk          (clk),
        .rst          (rst),
        .i_alu_out    (ex1ex2_alu_out),
        .i_rs2_data   (ex1ex2_rs2_data),
        .i_pc_plus4   (ex_pc_plus4),
        .i_rd         (ex1ex2_rd),
        .i_wb_sel     (ex1ex2_wb_sel),
        .i_mem_width  (ex1ex2_mem_width),
        .i_reg_w_ena  (ex1ex2_reg_w_ena),
        .i_mem_w_ena  (ex1ex2_mem_w_ena),
        .i_mem_signed (ex1ex2_mem_signed),
        .o_alu_out    (exmem_alu_out),
        .o_rs2_data   (exmem_rs2_data),
        .o_pc_plus4   (exmem_pc_plus4),
        .o_rd         (exmem_rd),
        .o_wb_sel     (exmem_wb_sel),
        .o_mem_width  (exmem_mem_width),
        .o_reg_w_ena  (exmem_reg_w_ena),
        .o_mem_w_ena  (exmem_mem_w_ena),
        .o_mem_signed (exmem_mem_signed)
    );

    // ===============================================Stage 5 - Memory==========
    // The access address is the ALU result and the store data is rs2, both
    // carried down from the execute stages. The read data is a flop inside the
    // memory, so it belongs to this access one cycle from now - which is to say,
    // it belongs to the instruction now entering writeback, and the writeback mux
    // reads it here rather than from a stage register that would have had to
    // sample it before it existed.
    wire [31:0] mem_rdata;

    dmem DMEM(
        .clk      (clk), .w_ena (exmem_mem_w_ena),
        .width    (exmem_mem_width), .is_signed (exmem_mem_signed),
        .addr     (exmem_alu_out),
        .w_data   (exmem_rs2_data), .r_data (mem_rdata)
    );

    wire [31:0] memwb_alu_out, memwb_pc_plus4;
    wire [4:0]  memwb_rd;
    wire [1:0]  memwb_wb_sel;
    wire        memwb_reg_w_ena;

    pipe_mem_wb MEM_WB(
        .clk          (clk),
        .rst          (rst),
        .i_alu_out    (exmem_alu_out),
        .i_pc_plus4   (exmem_pc_plus4),
        .i_rd         (exmem_rd),
        .i_wb_sel     (exmem_wb_sel),
        .i_reg_w_ena  (exmem_reg_w_ena),
        .o_alu_out    (memwb_alu_out),
        .o_pc_plus4   (memwb_pc_plus4),
        .o_rd         (memwb_rd),
        .o_wb_sel     (memwb_wb_sel),
        .o_reg_w_ena  (memwb_reg_w_ena)
    );

    // ===============================================Stage 6 - Writeback=======
    assign wb_reg_w_ena = memwb_reg_w_ena;
    assign wb_rd        = memwb_rd;

    // A load's value is the only writeback source that is not a pipeline
    // register: it comes straight off the memory's registered read port, valid
    // for exactly as long as the load occupies this stage.
    always @(*) begin
        case (memwb_wb_sel)
            `WB_ALU: wb_data = memwb_alu_out;
            `WB_MEM: wb_data = mem_rdata;
            `WB_PC4: wb_data = memwb_pc_plus4;
            default: wb_data = 32'h0;
        endcase
    end

    // ===============================================Hazard Unit===============
    hazard_unit HU(
        .i_id_ex_mem_r_ena     (idex_mem_r_ena),
        .i_id_ex_rd            (idex_rd),
        .i_ex1_ex2_mem_r_ena   (ex1ex2_mem_r_ena),
        .i_ex1_ex2_rd          (ex1ex2_rd),
        .i_id_rs1              (id_rs1),
        .i_id_rs2              (id_rs2),
        .i_id_uses_rs1         (id_uses_rs1),
        .i_id_uses_rs2         (id_uses_rs2),
        .i_pc_redirect         (pc_src),
        .o_stall_pc      (stall_pc),
        .o_stall_if_id   (stall_if_id),
        .o_flush_if_id   (flush_if_id),
        .o_flush_id_ex   (flush_id_ex),
        .o_flush_ex1_ex2 (flush_ex1_ex2)
    );

    // ===============================================Forwarding Unit===========
    forwarding_unit FWU(
        .ex1ex2_reg_w_ena(ex1ex2_reg_w_ena),
        .exmem_reg_w_ena (exmem_reg_w_ena),
        .exmem_rd        (exmem_rd),
        .ex1ex2_rd       (ex1ex2_rd),
        .memwb_reg_w_ena (memwb_reg_w_ena),
        .memwb_rd        (memwb_rd),
        .idex_rs1        (idex_rs1),
        .idex_rs2        (idex_rs2),
        .forward_a        (forward_a),
        .forward_b        (forward_b)
    );

    // Map internal signals to outputs. Note the phase relationship: dmem_addr is
    // the access being issued now, dmem_rdata is the read data of the access that
    // was issued one cycle ago (see rtl/mem/dmem.v).
    assign pc_out     = pc_current;
    assign dmem_addr  = exmem_alu_out;
    assign dmem_wdata = exmem_rs2_data;
    assign dmem_rdata = mem_rdata;
    assign dmem_w_ena = exmem_mem_w_ena;
    assign dmem_width = exmem_mem_width;
endmodule
