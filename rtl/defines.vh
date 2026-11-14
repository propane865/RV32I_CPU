// =============================================================================
// RV32I encodings and core microarchitecture constants.
//
// Single source of truth. Before this file existed the same encoding was
// written out in two or three places (IMM_* was localparam'd in both control.v
// and imm_gen.v; the ALU op values lived in control.v localparams and as raw
// literals in alu.v; branch conditions were funct3 in control.v and 3'b100 in
// datapath.v). Changing an encoding meant remembering to change it everywhere.
//
// Names prefixed RV_ are architectural (fixed by the RISC-V spec). The rest are
// this core's own choice of encoding and are free to change together.
// =============================================================================
`ifndef RV32I_DEFINES_VH
`define RV32I_DEFINES_VH

// ------------------------------------------------------------------ opcodes --
`define RV_OP      7'b0110011  // R-type ALU
`define RV_OP_IMM  7'b0010011  // I-type ALU
`define RV_LOAD    7'b0000011
`define RV_STORE   7'b0100011
`define RV_BRANCH  7'b1100011
`define RV_LUI     7'b0110111
`define RV_AUIPC   7'b0010111
`define RV_JAL     7'b1101111
`define RV_JALR    7'b1100111

// ------------------------------------------------------- funct3: ALU (R/I) --
`define RV_F3_ADD  3'h0   // ADD / SUB, ADDI
`define RV_F3_SLL  3'h1
`define RV_F3_SLT  3'h2   // signed
`define RV_F3_SLTU 3'h3
`define RV_F3_XOR  3'h4
`define RV_F3_SRL  3'h5   // SRL/SRA, SRLI/SRAI
`define RV_F3_OR   3'h6
`define RV_F3_AND  3'h7

// ------------------------------------------------------- funct3: branches --
// funct3 doubles as this core's branch_cond field, so these are also the
// branch_unit case labels.
`define RV_F3_BEQ  3'h0
`define RV_F3_BNE  3'h1
`define RV_F3_BLT  3'h4
`define RV_F3_BGE  3'h5
`define RV_F3_BLTU 3'h6
`define RV_F3_BGEU 3'h7

// --------------------------------------------------- funct3: loads / stores --
// Bits [1:0] select the access width, bit [2] selects signedness on loads.
`define RV_F3_B    3'h4   // LB, SB
`define RV_F3_BU   3'h5   // LBU
`define RV_F3_H    3'h6   // LH, SH
`define RV_F3_HU   3'h7   // LHU
`define RV_F3_W    3'h2   // LW, SW

// ------------------------------------------------------- funct7: SUB / SRA --
// Only bit 5 distinguishes ADD from SUB and SRL from SRA.
`define RV_FUNC7_B5 5

// ---------------------------------------------------------- NOP instruction --
// Used to fill flushed pipeline slots; addi x0, x0, 0.
`define RV_NOP     32'h00000013

// -------------------------------------------------------- core configuration --
// The address the program counter takes on reset. A define rather than a literal
// inside rtl/pc.v because where execution starts is a property of the system
// around the core, not of the pipeline: the compliance harness loads a linked
// image that begins at the bottom of the instruction memory, and this is the one
// place that says so.
`define RESET_PC   32'h0000_0000

// --------------------------------------------------- ALU operation select ----
// Microarchitecture-internal: control.v emits these, alu.v decodes them. Four
// bits, because the operation alone must say everything the ALU does: SUB is
// its own code rather than ADD plus an "invert" bit, and the three shifts each
// say their own direction and signedness rather than borrowing one from outside.
`define ALU_AND    4'd0
`define ALU_OR     4'd1
`define ALU_XOR    4'd2
`define ALU_ADD    4'd3
`define ALU_SUB    4'd4
`define ALU_SHL    4'd5   // shift left
`define ALU_SHR    4'd6   // shift right, logical (zero fill)
`define ALU_SHA    4'd7   // shift right, arithmetic (sign fill)
`define ALU_CMP    4'd8   // SLT / SLTU: the comparator's "a < b"
`define ALU_PASS   4'd9   // out = a, used by LUI

// ---------------------------------------------------- ALU input A select -----
`define ALU_A_RS1  2'b00
`define ALU_A_PC   2'b01  // AUIPC
`define ALU_A_IMM  2'b10  // LUI

// ------------------------------------------------------- immediate select ----
`define IMM_I      3'd0
`define IMM_S      3'd1
`define IMM_B      3'd2
`define IMM_U      3'd3
`define IMM_J      3'd4

// ------------------------------------------------------------ writeback mux --
`define WB_ALU     2'd0
`define WB_MEM     2'd1   // load data
`define WB_PC4     2'd2   // link address for JAL / JALR

// ----------------------------------------------------------- memory width ----
// Matches funct3[1:0] so load/store decode is a direct slice. MEM_W is also the
// reset/bubble value for the pipelined mem_width field.
`define MEM_B      2'd0
`define MEM_H      2'd1
`define MEM_W      2'd2

// -------------------------------------------------------- forwarding select --
`define FWD_NONE   2'd0   // take the register file read data
`define FWD_MEMWB  2'd1
`define FWD_EXMEM  2'd2
`define FWD_EX1    2'd3   // youngest writer, wins ties

// ------------------------------------------------- sky130 macro power pins --
// The SRAM macros carry power pins that only exist in the PDK netlist. Including
// them in the port list is switched on with +define+USE_POWER_PINS, and both
// wrappers need the identical spelling, so it lives here rather than being
// copy-pasted into each one (the original copy in each file also defined an
// unused PWR_PINS companion macro).
`ifdef USE_POWER_PINS
    `define PWR_CONN .vccd1(vccd1), .vssd1(vssd1),
`else
    `define PWR_CONN
`endif

`endif // RV32I_DEFINES_VH
