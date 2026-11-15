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
// hazard_unit.v, exception detection in trap_unit.v, and every staging register
// in its own pipe_*.v. What is left here is the interconnection, the two muxes
// the stages share (operand forwarding and writeback selection), and the one
// piece of state that has no module of its own because it is three flops and a
// comparison: the record of the exception that stopped this machine.
//
// The testbench pokes the memories and register file through the IMEM, DMEM and
// RF instance names, so those three instance names must not change.
// Included before the module header rather than inside it: the exception width is
// used in the port list, and a `define is only in effect from the line it appears
// on, so a macro a port list depends on cannot be defined by the module body.
`include "defines.vh"

module datapath(
    input  clk, rst,
    output [31:0] pc_out, dmem_addr, dmem_wdata, dmem_rdata,
    output [1:0]  dmem_width,
    output        dmem_w_ena,
    // The exception report. `trap` says one happened and stays set until reset;
    // `trap_cause` says which of the six it was (`TRAP_* in defines.vh) and
    // `trap_pc` the address of the instruction that raised it. Together they are
    // the whole external interface of a core that has no handler to enter: no
    // CSRs, no mcause, no mret, so the machine stops here and says why.
    output        trap,
    output [`TRAP_CAUSE_W-1:0] trap_cause,
    output [31:0] trap_pc
);
    `include "defines.vh"

    wire        stall_pc, stall_if_id, flush_if_id, flush_id_ex, flush_ex1_ex2;
    wire [1:0]  forward_a, forward_b;

    // ===============================================Exceptions================
    // Declared at the top because the fetch stage below consumes all three, and a
    // net referenced by an instantiation must be visible where it is used or
    // iverilog binds it as an implicit one-bit wire (same reason as the forwarding
    // sources in stage 3).
    //
    // `trap_now` is combinational and lasts one cycle: the cycle whose instruction
    // in execute 2 raised the exception, which is the cycle that instruction would
    // otherwise have spent in the memory stage. The rest is what outlives it.
    wire                   trap_now;
    wire [`TRAP_CAUSE_W-1:0] trap_now_cause;

    reg                    trap_q;
    reg [`TRAP_CAUSE_W-1:0] trap_cause_q;
    reg [31:0]             trap_pc_q;

    // Stopping the fetch is the whole of the stop. With the PC frozen and bubbles
    // injected behind it - see discard_younger, in the execute 2 stage - the
    // pipeline drains forward through MEM and WB and nothing new enters: every
    // instruction older than the exception retires, the trapping one writes
    // nothing, and nothing younger starts. That is what makes the exception
    // precise, and it needs no bookkeeping about which instruction is which.
    wire halt;

    // ===============================================Stage 1 - Fetch===========
    wire [31:0] pc_current, pc_target, instr_if;
    // The transfer the branch unit is asking for, and the one the fetch actually
    // performs. They differ only for an instruction that traps: a taken branch to
    // a misaligned address must NOT transfer control, and a branch that does
    // transfer control is by definition not the misaligned one. Gating here rather
    // than inside the branch unit keeps that unit's job to one question - is the
    // condition met, and where would it go - and keeps the answer to "may it go"
    // next to the thing that says no.
    wire ex2_redirect, redirect;

    pc PC(
        .clk      (clk),
        .rst      (rst),
        .stall    (stall_pc),
        .halt     (halt),
        .pc_src   (redirect),
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
    // The decode's verdicts about the encoding rather than about execution. An
    // illegal instruction has already been made inert by rtl/control.v, which
    // asserts nothing for it; what travels down the pipeline is the reason it was
    // inert, which is what the exception report in execute 2 is made of.
    wire        id_illegal, id_is_ecall, id_is_ebreak;
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
        .illegal    (id_illegal),
        .is_ecall   (id_is_ecall),
        .is_ebreak  (id_is_ebreak)
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
                idex_branch, idex_jump, idex_jalr,
                idex_illegal, idex_is_ecall, idex_is_ebreak;
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
        .i_illegal      (id_illegal),
        .i_is_ecall     (id_is_ecall),
        .i_is_ebreak    (id_is_ebreak),
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
        .o_illegal      (idex_illegal),
        .o_is_ecall     (idex_is_ecall),
        .o_is_ebreak    (idex_is_ebreak),
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
    // Both arms above are unreachable for a jump producer, and it is worth saying
    // why, because the code looks like it is handling a case nothing tests. A taken
    // JAL/JALR redirects the fetch and flushes IF/ID and ID/EX, so the next
    // instruction to reach execute 1 is the target - at least two cycles after the
    // jump resolved - which is by then served by FWD_MEMWB or the register file. An
    // experiment that replaced these two arms with the plain ALU result left every
    // directed test, including the JAL/JALR link sweep, passing: what pins the link
    // value is the write-back arm, not these.
    //
    // They are kept because they cost nothing and because "this mux cannot be asked"
    // is a property of the hazard and flush logic two files away, not of this line -
    // and unlike the load case below, the value they would supply is the right one if
    // that property ever changed.
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

    // The comparison's operands are the forwarded source registers, except when
    // the instruction's second operand is an immediate - which is exactly when
    // alu_src is set, so alu_b is the right second operand for both cases and is
    // already the mux that says so.
    //
    // Taking it from fwd_rs2 instead, as this used to, is not a wrong value for
    // SLTI/SLTIU: it is a wrong *question*. An I-type has no rs2 - bits [24:20] are
    // imm[4:0], which names a register rather than holding one - so the comparison
    // was against whatever register the immediate's low five bits happened to point
    // at. `sltiu x10, x2, 0x404` asked whether x2 < x4, and got 0 for 512 < 1032.
    // It survived because imm[4:0] == 0 selects x0, which reads 0, and a comparison
    // against an immediate of 0 is the same comparison either way: the case that
    // would have caught it had to use an immediate whose low five bits name a
    // register holding something other than the immediate.
    comp32 BCOMP(
        .a  (fwd_rs1), .b (alu_b),
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
    // The decode verdicts travel one stage further than the hazard unit needs them:
    // the exception they describe is raised here, in execute 2, and by then this is
    // all that is left of the encoding (rtl/pipe_ex1_ex2.v).
    wire        ex1ex2_illegal, ex1ex2_is_ecall, ex1ex2_is_ebreak;
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
        .i_illegal     (idex_illegal),
        .i_is_ecall    (idex_is_ecall),
        .i_is_ebreak   (idex_is_ebreak),
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
        .o_illegal     (ex1ex2_illegal),
        .o_is_ecall    (ex1ex2_is_ecall),
        .o_is_ebreak   (ex1ex2_is_ebreak),
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
        .o_redirect   (ex2_redirect),
        .o_target     (pc_target),
        .o_pc_plus4   (ex_pc_plus4)
    );

    // ===============================================Exception detect==========
    // The exception itself is decided in rtl/trap_unit.v, combinationally, from
    // what decode said about this instruction and the two addresses execute 2 has
    // just computed. Everything below is the consequence of that one cycle.
    //
    // Three separate effects, because an exception has to stop three different
    // things happening, and no single one of them covers the others:
    //
    //   1. this instruction must not act     - the flush below, into EX/MEM, which
    //      is where its store enable, its write-back enable and its link value all
    //      still can be stopped;
    //   2. nothing younger may act          - discard_younger, the same injection a
    //      redirect performs, since the two instructions behind a trapping one were
    //      fetched from a path that is now abandoned;
    //   3. nothing older may be disturbed   - deliberately nothing: MEM and WB keep
    //      running, so older instructions retire, which is what "precise" means.
    trap_unit TRAP(
        .i_illegal    (ex1ex2_illegal),
        .i_is_ecall   (ex1ex2_is_ecall),
        .i_is_ebreak  (ex1ex2_is_ebreak),
        .i_mem_r_ena  (ex1ex2_mem_r_ena),
        .i_mem_w_ena  (ex1ex2_mem_w_ena),
        .i_mem_width  (ex1ex2_mem_width),
        .i_addr_lo    (ex1ex2_alu_out[1:0]),  // the effective address, EX1's result
        .i_redirect   (ex2_redirect),         // a transfer this instruction wants
        .i_target_lo  (pc_target[1:0]),
        .o_trap       (trap_now),
        .o_cause      (trap_now_cause)
    );

    // A trapped instruction does not transfer control. The case that makes this
    // load-bearing is a taken branch or jump to a misaligned address: the condition
    // is met and the target is computed, so the branch unit asks for the transfer in
    // the same cycle that the target's misalignment is reported. Doing it anyway
    // would jump past the exception, and the reported PC would name an instruction
    // that was never allowed to have an effect.
    assign redirect = ex2_redirect & ~trap_now;

    // Slots younger than execute 2 are discarded for any of three reasons, and the
    // hazard unit is the one that injects the bubbles, so it is told about all
    // three. A redirect discards them because they came from the wrong path. An
    // exception discards them for the same reason plus one: the machine is stopping,
    // and an instruction already in flight past the trapping one would retire after
    // an exception that architecturally stopped the machine before it. And once
    // stopped, the front end must keep injecting, or the frozen PC would refill the
    // pipeline with the same instruction over and over - which, since the trapping
    // instruction is the one that stays in front of the machine's eye, would look
    // exactly like an exception that fires every cycle.
    wire discard_younger = ex2_redirect | trap_now | halt;

    // Stopping the fetch is the whole of the stop: see the note on `halt` above.
    assign halt = trap_q;

    // One record per machine, kept until reset. The PC stored with it is the
    // trapping instruction's own address, not the target it was denied - a report
    // that said where the core would have gone would describe something that did not
    // happen. `ex1ex2_pc` is the PC that travelled with the instruction, so this
    // stays true for a branch (whose own PC is not pc_current), a JAL, or anything
    // that reached execute 2 out of step with the fetch.
    always @(posedge clk) begin
        if (rst) begin
            trap_q       <= 1'b0;
            trap_cause_q <= {`TRAP_CAUSE_W{1'b0}};
            trap_pc_q    <= 32'h0;
        end else if (trap_now) begin
            trap_q       <= 1'b1;
            trap_cause_q <= trap_now_cause;
            trap_pc_q    <= ex1ex2_pc;
        end
    end

    // (exmem_alu_out is declared with the forwarding sources, in stage 3.)
    wire [31:0] exmem_rs2_data;
    wire [4:0]  exmem_rd;
    wire [1:0]  exmem_wb_sel, exmem_mem_width;
    wire        exmem_reg_w_ena, exmem_mem_w_ena, exmem_mem_signed;

    pipe_ex_mem EX_MEM(
        .clk          (clk),
        .rst          (rst),
        .flush        (trap_now),
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
        .i_discard_younger     (discard_younger),
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

    // The exception report. Sticky, so that a harness can look at it any time
    // after the fact rather than sampling the one cycle it happened.
    assign trap       = trap_q;
    assign trap_cause = trap_cause_q;
    assign trap_pc    = trap_pc_q;
endmodule
