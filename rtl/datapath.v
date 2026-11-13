// Link components of the CPU to form the datapath

/*
Clock:                  | clk
--------------------------------------
Reset:                  | rst
--------------------------------------
Program Counter:        | pc_out
--------------------------------------
Memory Address:         | dmem_addr
--------------------------------------
Memory Write Data:      | dmem_wdata
--------------------------------------
Memory Read Data:       | dmem_rdata
--------------------------------------
Memory Data Width:      | dmem_width
--------------------------------------
Memory Write Enable:    | dmem_w_ena
*/

module datapath(input clk, rst, output [31:0] pc_out, dmem_addr, dmem_wdata, dmem_rdata, output [1:0] dmem_width, output dmem_w_ena);
    `include "defines.vh"

    // Initialize relevant wires
    wire stall_pc, stall_if_id, flush_if_id, flush_id_ex, flush_ex1_ex2;
    wire [1:0] forward_a, forward_b;

    // ===============================================Stage 1 - Fetch===============================================
    wire [31:0] pc_current, pc_plus4, pc_target, instr_if;
    wire pc_src;

    // Load the Program Counter
    pc PC(
        .clk(clk),
        .rst(rst),
        .stall(stall_pc),
        .pc_src(pc_src),
        .pc_target(pc_target),
        .pc_out(pc_current),
        .pc_plus4(pc_plus4)
    );

    // Load instruction memory and link to the program counter
    imem IMEM(.pc(pc_current), .instr(instr_if));

    // IF/ID Pipeline Registers to store fetched instructions
    reg [31:0] IF_ID_pc, IF_ID_instr;
    always @(posedge clk) begin
        // If a control hazard or reset signal is detected, reset program counter and reset pipelined instruction to NOP
        if (rst || flush_if_id) begin
            IF_ID_pc <= 32'h0;
            IF_ID_instr <= `RV_NOP;
        end
        // If there is no load-use hazard, store the current instruction
        else if (!stall_if_id) begin
            IF_ID_pc <= pc_current;
            IF_ID_instr <= instr_if;
        end
    end

    // ===============================================Stage 2 - Decode===============================================
    wire [6:0] id_opcode, id_funct7;
    wire [4:0] id_rd, id_rs1, id_rs2;
    wire [2:0] id_funct3;

    // Load the instruction decoder, and decode an instruction from memory
    decoder DEC(
        .instr(IF_ID_instr),
        .opcode(id_opcode),
        .rd(id_rd), .rs1(id_rs1), .rs2(id_rs2),
        .funct3(id_funct3), .funct7(id_funct7)
    );

    wire id_alu_src, id_alu_cin, id_alu_invert, id_alu_sgn, id_alu_dir, id_alu_pass, id_reg_w_ena, id_mem_w_ena, id_mem_signed, id_branch, id_jump, id_jalr;
    wire [1:0] id_wb_sel, id_mem_width, id_alu_src_a;
    wire [2:0] id_alu_op, id_imm_sel, id_branch_cond;

    // Controller converts the input signals from the decoder to raw signals, which are passed to other CPU components
    control CTRL(
        .opcode(id_opcode),
        .funct7(id_funct7), .funct3(id_funct3),
        .alu_src(id_alu_src), .alu_src_a(id_alu_src_a),
        .reg_w_ena(id_reg_w_ena), .mem_w_ena(id_mem_w_ena),
        .mem_signed(id_mem_signed),
        .alu_cin(id_alu_cin), .alu_invert(id_alu_invert),
        .alu_sgn(id_alu_sgn), .alu_pass(id_alu_pass),
        .branch(id_branch), .jump(id_jump), .jalr(id_jalr),
        .wb_sel(id_wb_sel), .mem_width(id_mem_width),
        .alu_op(id_alu_op),
        .imm_sel(id_imm_sel),
        .branch_cond(id_branch_cond)
    );

    wire [31:0] wb_data;
    wire [4:0] wb_rd;
    wire wb_reg_w_ena;

    wire [31:0] id_rs1_data, id_rs2_data;

    // Load the registers of the CPU, link inputs to the decoder
    regfile RF(
        .clk(clk),
        .w_ena(wb_reg_w_ena),
        .rs1(id_rs1), .rs2(id_rs2), .rd(wb_rd),
        .w_data(wb_data), .r_data1(id_rs1_data), .r_data2(id_rs2_data)
    );

    wire [31:0] id_imm;
    // Generate immediates from the instruction, depending on type of immediate
    imm_gen IMMGEN(.instr(IF_ID_instr), .imm_sel(id_imm_sel), .imm(id_imm));

    // ID/EX Pipeline Registers to store decoded signals
    reg [31:0] ID_EX_pc, ID_EX_rs1_data, ID_EX_rs2_data, ID_EX_imm;
    reg [4:0] ID_EX_rs1, ID_EX_rs2, ID_EX_rd;
    reg ID_EX_alu_src, ID_EX_alu_cin, ID_EX_alu_invert, ID_EX_alu_sgn, ID_EX_alu_pass, ID_EX_reg_w_ena, ID_EX_mem_w_ena, ID_EX_mem_signed, ID_EX_branch, ID_EX_jump, ID_EX_jalr;
    reg [1:0] ID_EX_wb_sel, ID_EX_mem_width, ID_EX_alu_src_a;
    reg [2:0] ID_EX_alu_op, ID_EX_branch_cond;

    always @(posedge clk) begin
        if (rst || flush_id_ex) begin
            ID_EX_pc <= 32'h0;
            ID_EX_rs1_data <= 32'h0;
            ID_EX_rs2_data <= 32'h0;
            ID_EX_imm <= 32'h0;
            ID_EX_rs1 <= 5'b0;
            ID_EX_rs2 <= 5'b0;
            ID_EX_rd <= 5'b0;
            ID_EX_alu_src <= 1'b0;
            ID_EX_alu_cin <= 1'b0;
            ID_EX_alu_invert <= 1'b0;
            ID_EX_alu_sgn <= 1'b0;
            ID_EX_alu_pass <= 1'b0;
            ID_EX_reg_w_ena <= 1'b0;
            ID_EX_mem_w_ena <= 1'b0;
            ID_EX_mem_signed <= 1'b0;
            ID_EX_branch <= 1'b0;
            ID_EX_jump <= 1'b0;
            ID_EX_jalr <= 1'b0;
            ID_EX_wb_sel <= 2'b0;
            ID_EX_mem_width <= `MEM_W;
            ID_EX_alu_src_a <= 2'b0;
            ID_EX_alu_op <= 3'b0;
            ID_EX_branch_cond <= 3'b0;
        end
        else begin
            ID_EX_pc <= IF_ID_pc;
            ID_EX_rs1_data <= id_rs1_data;
            ID_EX_rs2_data <= id_rs2_data;
            ID_EX_imm <= id_imm;
            ID_EX_rs1 <= id_rs1;
            ID_EX_rs2 <= id_rs2;
            ID_EX_rd <= id_rd;
            ID_EX_alu_src <= id_alu_src;
            ID_EX_alu_cin <= id_alu_cin;
            ID_EX_alu_invert <= id_alu_invert;
            ID_EX_alu_sgn <= id_alu_sgn;
            ID_EX_alu_pass <= id_alu_pass;
            ID_EX_reg_w_ena <= id_reg_w_ena;
            ID_EX_mem_w_ena <= id_mem_w_ena;
            ID_EX_mem_signed <= id_mem_signed;
            ID_EX_branch <= id_branch;
            ID_EX_jump <= id_jump;
            ID_EX_jalr <= id_jalr;
            ID_EX_wb_sel <= id_wb_sel;
            ID_EX_mem_width <= id_mem_width;
            ID_EX_alu_src_a <= id_alu_src_a;
            ID_EX_alu_op <= id_alu_op;
            ID_EX_branch_cond <= id_branch_cond;
        end
    end

    // ===============================================Stage 3 - Execute 1===============================================
    wire [31:0] fwd_rs1, fwd_rs2;

    assign fwd_rs1 = (forward_a == `FWD_EX1)   ? EX1_EX2_alu_out : (forward_a == `FWD_EXMEM) ? EX_MEM_alu_out : (forward_a == `FWD_MEMWB) ? wb_data : ID_EX_rs1_data;
    assign fwd_rs2 = (forward_b == `FWD_EX1)   ? EX1_EX2_alu_out : (forward_b == `FWD_EXMEM) ? EX_MEM_alu_out : (forward_b == `FWD_MEMWB) ? wb_data : ID_EX_rs2_data;

    // Determine ALU inputs A and B:
    wire [31:0] alu_a, alu_b;

    // alu_src_a = `ALU_A_IMM: The immediate is passed to input A. 
    // alu_src_a = `ALU_A_PC: The program counter is passed instead.
    // If alu_src takes on any other value, then source register 1 is passed to imput A.
    assign alu_a = (ID_EX_alu_src_a == `ALU_A_IMM) ? ID_EX_imm : (ID_EX_alu_src_a == `ALU_A_PC) ? ID_EX_pc : fwd_rs1;

    // If alu_src is 1'b1, then the immediate is passed to input B.
    // Otherwise, the source register 2 is passed to input B.
    assign alu_b = ID_EX_alu_src ? ID_EX_imm : fwd_rs2;

    wire [31:0] ex_alu_out;
    wire ex_alu_cout;

    wire ex_gt_b, ex_lt_b, ex_eq_b;
    comp32 BCOMP(
        .a(fwd_rs1), .b(fwd_rs2),
        .u(~ID_EX_alu_sgn),
        .gt(ex_gt_b), .lt(ex_lt_b), .eq(ex_eq_b)
    );

    // Instantiate the ALU with relevant inputs and outputs
    alu ALU(
        .a(alu_a), .b(alu_b), .cin(ID_EX_alu_cin),
        .gt(ex_gt_b), .lt(ex_lt_b), .eq(ex_eq_b),
        .pass(ID_EX_alu_pass), .invert(ID_EX_alu_invert),
        .op(ID_EX_alu_op),
        .out(ex_alu_out), .cout(ex_alu_cout)
    );

    // EX1/EX2 Pipeline Registers
    reg [31:0] EX1_EX2_alu_out, EX1_EX2_rs1_data, EX1_EX2_rs2_data;
    reg [31:0] EX1_EX2_pc, EX1_EX2_imm;
    reg [4:0] EX1_EX2_rs1, EX1_EX2_rs2, EX1_EX2_rd;
    reg [2:0] EX1_EX2_branch_cond;
    reg [1:0] EX1_EX2_wb_sel, EX1_EX2_mem_width;
    reg EX1_EX2_reg_w_ena, EX1_EX2_mem_w_ena, EX1_EX2_mem_signed;
    reg EX1_EX2_jump, EX1_EX2_jalr, EX1_EX2_branch;
    reg EX1_EX2_gt, EX1_EX2_lt, EX1_EX2_eq;

    always @(posedge clk) begin
        if (rst || flush_ex1_ex2) begin
            EX1_EX2_alu_out <= 32'b0;
            EX1_EX2_rs1_data <= 32'b0;
            EX1_EX2_rs2_data <= 32'b0;
            EX1_EX2_pc <= 32'b0;
            EX1_EX2_imm <= 32'b0;
            EX1_EX2_rd <= 5'b0;
            EX1_EX2_rs1 <= 5'b0;
            EX1_EX2_rs2 <= 5'b0;
            EX1_EX2_branch_cond <= 3'b0;
            EX1_EX2_reg_w_ena <= 1'b0;
            EX1_EX2_mem_w_ena <= 1'b0;
            EX1_EX2_mem_signed <= 1'b0;
            EX1_EX2_wb_sel <= 2'b0;
            EX1_EX2_mem_width <= `MEM_W;
            EX1_EX2_jump <= 1'b0;
            EX1_EX2_jalr <= 1'b0;
            EX1_EX2_branch <= 1'b0;
            EX1_EX2_gt <= 1'b0;
            EX1_EX2_lt <= 1'b0;
            EX1_EX2_eq <= 1'b0;
        end
        else begin
            EX1_EX2_alu_out <= ex_alu_out;
            EX1_EX2_rs1_data <= fwd_rs1;
            EX1_EX2_rs2_data <= fwd_rs2;
            EX1_EX2_pc <= ID_EX_pc;
            EX1_EX2_imm <= ID_EX_imm;
            EX1_EX2_rd <= ID_EX_rd;
            EX1_EX2_rs1 <= ID_EX_rs1;
            EX1_EX2_rs2 <= ID_EX_rs2;
            EX1_EX2_branch_cond <= ID_EX_branch_cond;
            EX1_EX2_reg_w_ena <= ID_EX_reg_w_ena;
            EX1_EX2_mem_w_ena <= ID_EX_mem_w_ena;
            EX1_EX2_mem_signed <= ID_EX_mem_signed;
            EX1_EX2_wb_sel <= ID_EX_wb_sel;
            EX1_EX2_mem_width <= ID_EX_mem_width;
            EX1_EX2_jump <= ID_EX_jump;
            EX1_EX2_jalr <= ID_EX_jalr;
            EX1_EX2_branch <= ID_EX_branch;
            EX1_EX2_gt <= ex_gt_b;
            EX1_EX2_lt <= ex_lt_b;
            EX1_EX2_eq <= ex_eq_b;
        end
    end

    // ===============================================Stage 4 - Execute 2===============================================

    // Determine if a branch condition is met using the comparator. The signal (branch_cond) determines the type of comparison.
    reg ex_condition_met_r;
    always @(*) begin
        case (EX1_EX2_branch_cond)
            `RV_F3_BEQ:  ex_condition_met_r = EX1_EX2_eq;
            `RV_F3_BNE:  ex_condition_met_r = ~EX1_EX2_eq;
            `RV_F3_BLT:  ex_condition_met_r = EX1_EX2_lt;
            `RV_F3_BGE:  ex_condition_met_r = EX1_EX2_gt | EX1_EX2_eq;
            `RV_F3_BLTU: ex_condition_met_r = EX1_EX2_lt;
            `RV_F3_BGEU: ex_condition_met_r = EX1_EX2_gt | EX1_EX2_eq;
            default: ex_condition_met_r = 1'b0;
        endcase
    end

    // Set the value of the program counter to a target value if jump instructions are passed, or if B-type instructions are passed, with satisfied branch conditions
    assign pc_src = EX1_EX2_jump | (EX1_EX2_branch & ex_condition_met_r);

    wire [31:0] jalr_target, branch_jal_target;
    wire jalr_cout, branch_cout;
    ks32 jalr_adder(.a(EX1_EX2_rs1_data), .b(EX1_EX2_imm), .cin(1'b0), .sum(jalr_target), .cout(jalr_cout));
    ks32 branch_adder(.a(EX1_EX2_pc), .b(EX1_EX2_imm), .cin(1'b0), .sum(branch_jal_target), .cout(branch_cout));

    // Set the program counter to source register 1 plus immediate if JALR is passed.
    // Else, set the program counter to its current value plus the immediate (passed by the J-type instruction). 
    assign pc_target = EX1_EX2_jalr ? (jalr_target & ~32'b1) : branch_jal_target;

    wire [31:0] ex_pc_plus4 = EX1_EX2_pc + 32'h4;

    // EX/MEM Pipeline Registers
    reg [31:0] EX_MEM_alu_out, EX_MEM_rs2_data, EX_MEM_pc_plus4;
    reg [4:0] EX_MEM_rd;
    reg [1:0] EX_MEM_wb_sel, EX_MEM_mem_width;
    reg EX_MEM_reg_w_ena, EX_MEM_mem_w_ena, EX_MEM_mem_signed;

    always @(posedge clk) begin
        if (rst) begin
            EX_MEM_alu_out <= 32'b0;
            EX_MEM_rs2_data <= 32'b0;
            EX_MEM_pc_plus4 <= 32'b0;
            EX_MEM_rd <= 5'b0;
            EX_MEM_reg_w_ena <= 1'b0;
            EX_MEM_mem_w_ena <= 1'b0;
            EX_MEM_mem_signed <= 1'b0;
            EX_MEM_wb_sel <= 2'b0;
            EX_MEM_mem_width <= `MEM_W;
        end
        else begin
            EX_MEM_alu_out <= EX1_EX2_alu_out;
            EX_MEM_rs2_data <= EX1_EX2_rs2_data;
            EX_MEM_pc_plus4 <= ex_pc_plus4;
            EX_MEM_rd <= EX1_EX2_rd;
            EX_MEM_reg_w_ena <= EX1_EX2_reg_w_ena;
            EX_MEM_mem_w_ena <= EX1_EX2_mem_w_ena;
            EX_MEM_mem_signed <= EX1_EX2_mem_signed;
            EX_MEM_wb_sel <= EX1_EX2_wb_sel;
            EX_MEM_mem_width <= EX1_EX2_mem_width;
        end
    end
    // ===============================================Stage 5 - Memory===============================================
    wire [31:0] mem_rdata;

    // Instantiate the data memory with relevant inputs and outputs.
    // The memory address being read from or written to is calculated by the ALU.
    // The data being written is the data within the source register 2, as referenced by any S-type operation.
    dmem DMEM(
        .clk(clk), .w_ena(EX_MEM_mem_w_ena),
        .width(EX_MEM_mem_width), .is_signed(EX_MEM_mem_signed),
        .addr(EX_MEM_alu_out),
        .w_data(EX_MEM_rs2_data), .r_data(mem_rdata)
    );

    reg [31:0] MEM_WB_alu_out, MEM_WB_mem_rdata, MEM_WB_pc_plus4;
    reg [4:0] MEM_WB_rd;
    reg [1:0] MEM_WB_wb_sel;
    reg MEM_WB_reg_w_ena;

    always @(posedge clk) begin
        if (rst) begin
            MEM_WB_alu_out <= 32'b0;
            MEM_WB_mem_rdata <= 32'b0;
            MEM_WB_pc_plus4 <= 32'b0;
            MEM_WB_rd <= 5'b0;
            MEM_WB_reg_w_ena <= 1'b0;
            MEM_WB_wb_sel <= 2'b0;
        end
        else begin
            MEM_WB_alu_out <= EX_MEM_alu_out;
            MEM_WB_mem_rdata <= mem_rdata;
            MEM_WB_pc_plus4 <= EX_MEM_pc_plus4;
            MEM_WB_rd <= EX_MEM_rd;
            MEM_WB_reg_w_ena <= EX_MEM_reg_w_ena;
            MEM_WB_wb_sel <= EX_MEM_wb_sel;
        end
    end

    // ===============================================Stage 6 - Writeback===============================================
    assign wb_reg_w_ena = MEM_WB_reg_w_ena;
    assign wb_rd = MEM_WB_rd;

    // Determine the data to writeback into the registers.
    // `WB_ALU: Writeback the ALU output
    // `WB_MEM: Writeback the Memory Readout
    // `WB_PC4: Writeback the program counter plus 4
    reg [31:0] wb_data_r;
    always @(*) begin
        case (MEM_WB_wb_sel)
            `WB_ALU: wb_data_r = MEM_WB_alu_out;
            `WB_MEM: wb_data_r = MEM_WB_mem_rdata;
            `WB_PC4: wb_data_r = MEM_WB_pc_plus4;
            default: wb_data_r = 32'b0;
        endcase
    end
    assign wb_data = wb_data_r;

    // ===============================================Hazard Unit========================================================
    hazard_unit HU(
        .id_ex_mem_read(ID_EX_reg_w_ena && (ID_EX_mem_w_ena == 1'b0) && (ID_EX_wb_sel == `WB_MEM)),
        .id_ex_rd(ID_EX_rd),
        .if_id_rs1(id_rs1),
        .if_id_rs2(id_rs2),
        .pc_src(pc_src),
        .stall_pc(stall_pc),
        .stall_if_id(stall_if_id),
        .flush_if_id(flush_if_id),
        .flush_id_ex(flush_id_ex),
        .flush_ex1_ex2(flush_ex1_ex2)
    );

    // ===============================================Forwarding Unit====================================================
    forwarding_unit FWU(
        .ex1_ex2_reg_w_ena(EX1_EX2_reg_w_ena),
        .ex_mem_reg_w_ena(EX_MEM_reg_w_ena),
        .ex_mem_rd(EX_MEM_rd),
        .ex1_ex2_rd(EX1_EX2_rd),
        .mem_wb_reg_w_ena(MEM_WB_reg_w_ena),
        .mem_wb_rd(MEM_WB_rd),
        .id_ex_rs1(ID_EX_rs1),
        .id_ex_rs2(ID_EX_rs2),
        .forward_a(forward_a),
        .forward_b(forward_b)
    );

    // Map internal signals to outputs
    assign pc_out = pc_current;
    assign dmem_addr = EX_MEM_alu_out;
    assign dmem_wdata = EX_MEM_rs2_data;
    assign dmem_rdata = mem_rdata;
    assign dmem_w_ena = EX_MEM_mem_w_ena;
    assign dmem_width = EX_MEM_mem_width;
endmodule