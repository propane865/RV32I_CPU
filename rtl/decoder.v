`timescale 1ns/1ns
// Instruction field splitter
//
// Pure wiring: slices the 32-bit instruction into the architectural fields the
// decoder and immediate generator need. Kept as its own module so the field
// positions are written down exactly once.
// RV32I Instruction Decoder

module decoder(input [31:0] instr, output [6:0] opcode, funct7, output [4:0] rd, rs1, rs2, output [2:0] funct3);
    // Decode instructions into parts
    assign opcode = instr[6:0];
    assign rd = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign funct7 = instr[31:25];
endmodule
