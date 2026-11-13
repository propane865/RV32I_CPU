// CPU Control Unit

/*
Opcode:                         | opcode
-----------------------------------------------
Funct7:                         | funct7
-----------------------------------------------
Funct3:                         | funct3
-----------------------------------------------
ALU Source Select B:            | alu_src
-----------------------------------------------
Register Write Enable:          | reg_w_ena
-----------------------------------------------
Memory Write Enable:            | mem_w_ena
-----------------------------------------------
Memory Signed Read:             | mem_signed
-----------------------------------------------
ALU Input CIN:                  | alu_cin
-----------------------------------------------
ALU Input INVERT:               | alu_invert
-----------------------------------------------
ALU Input SIGNED COMPARISON:    | alu_sgn
-----------------------------------------------
ALU Input PASS:                 | alu_pass
-----------------------------------------------
Enable Branching:               | branch
-----------------------------------------------
Program Counter `RV_JAL:            | jump
-----------------------------------------------
Program Counter `RV_JALR:           | jalr
-----------------------------------------------
ALU Source Select A:            | alu_src_a
-----------------------------------------------
Writeback Selection:            | wb_sel
-----------------------------------------------
Memory R/W Width:               | mem_width
*/

module control(input [6:0] opcode, funct7, input [2:0] funct3, output reg alu_src, reg_w_ena, mem_w_ena, mem_signed, alu_cin, alu_invert, alu_sgn, alu_pass, branch, jump, jalr, output reg [1:0] alu_src_a, wb_sel, mem_width, output reg [2:0] alu_op, imm_sel, branch_cond);
    `include "defines.vh"


    always @(*) begin
        // Initialize default signal values
        alu_op = `ALU_ADD;
        alu_cin = 0;
        alu_invert = 0;
        alu_sgn = 0;
        alu_pass = 0;
        alu_src = 0;
        alu_src_a = `ALU_A_RS1;
        reg_w_ena = 0;
        mem_w_ena = 0;
        mem_width = `MEM_W;
        mem_signed = 0;
        wb_sel = `WB_ALU;
        branch = 0;
        jump = 0;
        jalr = 0;
        imm_sel = `IMM_I;
        branch_cond = 0;

        case (opcode)
            // R-type instructions
            `RV_OP: begin
                // Enable register writing, ALU inputs are from the registers
                reg_w_ena = 1;
                alu_src = 0;
                case (funct3)
                    // ADD/SUB: Addition and Subtraction
                    `RV_F3_ADD: begin
                        // Add (Default)
                        alu_op = `ALU_ADD;

                        // Change to Subtract if funct7[5] is 1'b1, by inverting the output and incrementing using (alu_cin).
                        alu_cin = funct7[5];
                        alu_invert = funct7[5];
                    end

                    // XOR
                    `RV_F3_XOR: alu_op = `ALU_XOR;

                    // OR
                    `RV_F3_OR: alu_op = `ALU_OR;

                    // AND
                    `RV_F3_AND: alu_op = `ALU_AND;

                    // SLL: Left Shift
                    `RV_F3_SLL: begin
                        // SLL
                        alu_op = `ALU_SHL;

                        // Disable invert for left shift
                        alu_invert = 0;
                    end

                    // SRL/SRA: Right Shift
                    `RV_F3_SRL: begin
                        // Enable invert for right shift
                        alu_invert = 1;

                        // If funct7[5] is 1'b1, then do arithmetic shift, else do logical shift
                        case (funct7[5])
                            1'b0: begin
                                // SRL
                                alu_op = `ALU_SHL;
                            end
                            1'b1: begin
                                // SRA
                                alu_op = `ALU_SHA;
                            end
                        endcase
                    end

                    // SLT: Signed Comparison
                    `RV_F3_SLT: begin
                        alu_op = `ALU_CMP;
                        
                        // Disable invert for less-than comparisons
                        alu_invert = 0;

                        // Enable signed comparison in ALU
                        alu_sgn = 1;
                    end

                    // SLTU: Unsigned Comparison
                    `RV_F3_SLTU: begin
                        alu_op = `ALU_CMP;
                        
                        // Disable invert for less-than comparisons
                        alu_invert = 0;

                        // Disable signed comparison in ALU
                        alu_sgn = 0;
                    end
                endcase
            end

            // I-type instructions
            `RV_OP_IMM: begin

                // Enable register writing, ALU input B is from the immediate
                reg_w_ena = 1;
                alu_src = 1;

                // Use I-type immediate encoding
                imm_sel = `IMM_I;

                case (funct3)
                    // ADDI: Add Immediate
                    `RV_F3_ADD: alu_op = `ALU_ADD;

                    // XORI: XOR Immediate
                    `RV_F3_XOR: alu_op = `ALU_XOR;

                    // ORI: OR Immediate
                    `RV_F3_OR: alu_op = `ALU_OR;

                    // ANDI: AND Immediate
                    `RV_F3_AND: alu_op = `ALU_AND;

                    // SLLI: Shift Left by Immediate
                    `RV_F3_SLL: begin
                        // SLLI
                        alu_op = `ALU_SHL;

                        // Disable invert for left shift
                        alu_invert = 0;
                    end

                    // SRLI/SRAI: Shift Right by Immediate
                    `RV_F3_SRL: begin
                        // Enable invert for right shift
                        alu_invert = 1;

                        // If funct7[5] is 1'b1, then do arithmetic shift, else do logical shift
                        case (funct7[5])
                            1'b0: begin
                                // SRLI
                                alu_op = `ALU_SHL;
                            end
                            1'b1: begin
                                // SRAI
                                alu_op = `ALU_SHA;
                            end
                        endcase
                    end

                    // SLTI: Signed Comparison with Immediate
                    `RV_F3_SLT: begin
                        alu_op = `ALU_CMP;

                        // Disable invert for less-than comparisons
                        alu_invert = 0;

                        // Enable signed comparison for ALU
                        alu_sgn = 1;
                    end

                    // SLTIU: Unsigned Comparison with Immediate
                    `RV_F3_SLTU: begin
                        alu_op = `ALU_CMP;

                        // Disable invert for less-than comparisons
                        alu_invert = 0;

                        // Disable signed comparison for ALU
                        alu_sgn = 0;
                    end
                endcase
            end

            // Load instructions (I-type)
            `RV_LOAD: begin
                // Enable register writing, ALU input B is from the immediate
                reg_w_ena = 1;
                alu_src = 1;

                // Set ALU to ADD to compute the memory read address (rs1 + imm)
                alu_op = `ALU_ADD;

                // Use I-type immediate encoding
                imm_sel = `IMM_I;

                // Select writeback from memory readout rather than ALU
                wb_sel = `WB_MEM;

                // Determine whether to load a byte, a halfword, or a word from the instruction
                mem_width = funct3[1:0];

                // Determine whether to read the memory as a signed or unsigned value from the instruction
                mem_signed = ~funct3[2];
            end

            // Store instructions (S-type)
            `RV_STORE: begin
                // Enable register writing, ALU input B is from the immediate
                mem_w_ena = 1;
                alu_src = 1;

                // Set ALU to ADD to compute the memory write address (rs1 + imm)
                alu_op = `ALU_ADD;

                // Use S-type immediate encoding
                imm_sel = `IMM_S;

                // Determine whether to store a byte, a halfword, or a word from the instruction
                mem_width = funct3[1:0];
            end

            // Branch instructions (B-type)
            `RV_BRANCH: begin
                // Enable CPU branching
                branch = 1;

                // ALU is not used for these instructions, but both ALU inputs are from the registers
                alu_src = 0;

                // Use B-type immediate encoding
                imm_sel = `IMM_B;

                // Branch condition type is determined by the instruction
                branch_cond = funct3;
            end

            // Load Upper Immediate (U-type)
            `RV_LUI: begin
                // Enable register writing, ALU input A is from the immediate
                reg_w_ena = 1;
                alu_src_a = `ALU_A_IMM;

                // Enable ALU passthrough (no operation is performed on the input A)
                alu_pass = 1;

                // Use U-type immediate encoding
                imm_sel = `IMM_U;
            end

            // Add Upper Immediate to Program Counter (U-type)
            `RV_AUIPC: begin
                // Enable register writing
                reg_w_ena = 1;

                // Set ALU to ADD to compute (imm + pc_current)
                alu_op = `ALU_ADD;

                // ALU input B is from the immediate
                alu_src = 1;

                // ALU input A is from the program counter
                alu_src_a = `ALU_A_PC;

                // Use U-type immediate encoding
                imm_sel = `IMM_U;
            end

            // Jump And Link (J-type)
            `RV_JAL: begin
                // Enable register writing
                reg_w_ena = 1;

                // Allow program counter to be rewritten to a target value
                jump = 1;

                // Select memory writeback from program counter plus 4
                wb_sel = `WB_PC4;

                // Use J-type immediate encoding
                imm_sel = `IMM_J;
            end

            // Jump And Link Register (I-type)
            `RV_JALR: begin
                // Enable register writing
                reg_w_ena = 1;

                // Allow program counter to be rewritten to a target value
                jump = 1;

                // Allow the target value of the program counter to be computed as (rs1 + imm) instead of (pc_current + imm).
                jalr = 1;

                // Select memory writeback from program counter plus 4
                wb_sel = `WB_PC4;

                // Set ALU to ADD to compute (rs1 + imm)
                alu_op = `ALU_ADD;

                // ALU input B is from the immediate
                alu_src = 1;

                // Use I-type immediate encoding
                imm_sel = `IMM_I;
            end
        endcase
    end
endmodule