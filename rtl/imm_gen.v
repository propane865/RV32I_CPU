`timescale 1ns/1ns
// Immediate generator
//
// Builds the sign-extended immediate for the selected format. The format is
// chosen by control.v (imm_sel), so this module knows the field positions of
// every RV32I immediate type but nothing about instructions.
//
//   I: instr[31:20]                        ADDI, loads, JALR, SLTI...
//   S: instr[31:25] + instr[11:7]          STORE (the fields straddle rd)
//   B: instr[31] + [7] + [30:25] + [11:8]  BRANCH, always even
//   U: instr[31:12] shifted up 12          LUI, AUIPC
//   J: instr[31] + [19:12] + [20] + [30:21] JAL, always even

    /* verilator lint_off UNUSEDSIGNAL */
    // Every immediate format is built from instr[31:7]; the opcode field
    // instr[6:0] is not needed here, but taking the whole instruction keeps this
    // module decoupled from the decoder's output splitting.
module imm_gen(input [31:0] instr, input [2:0] imm_sel, output reg [31:0] imm);
    /* verilator lint_on UNUSEDSIGNAL */
    `include "defines.vh"

    // Select immediate type depending on the input (imm_sel)
    always @(*) begin
        case (imm_sel)
            `IMM_I: imm = {{20{instr[31]}}, instr[31:20]};
            `IMM_S: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            `IMM_B: imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            `IMM_U: imm = {instr[31:12], 12'b0};
            `IMM_J: imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
            // Return zero if invalid immediate type is selected
            default: imm = 32'b0;
        endcase
    end
endmodule
