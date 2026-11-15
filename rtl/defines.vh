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
`define RV_OP_FENCE 7'b0001111  // MISC-MEM: FENCE
`define RV_OP_SYSTEM 7'b1110011 // ENV: ECALL, EBREAK - and the CSR forms, absent here

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
// Loads and stores share the encoding, which is why the pairs below have equal
// values: the opcode distinguishes them, funct3 only says width and signedness.
// Bits [1:0] select the width, bit [2] selects signedness on loads - so the two
// encodings with no legal load form (3'b011, 3'b111) are the ones with a legal
// store form, and the two with no legal store form are the unsigned loads.
//
// These replace a set of constants that were simply wrong (LB/SB were given as
// 3'h4, LH/SH as 3'h6, LHU as 3'h7, which are the *store* and *branch* slots).
// Nothing referenced them, so nothing was broken - which is the worst kind of
// wrong, because the next person to write a load decode would have trusted them.
`define RV_F3_LB   3'h0
`define RV_F3_LH   3'h1
`define RV_F3_LW   3'h2
`define RV_F3_LBU  3'h4
`define RV_F3_LHU  3'h5
`define RV_F3_SB   3'h0
`define RV_F3_SH   3'h1
`define RV_F3_SW   3'h2

// ------------------------------------------------------- funct7: SUB / SRA --
// Only bit 5 distinguishes ADD from SUB and SRL from SRA.
`define RV_FUNC7_B5 5
// ... and RV32I defines exactly two whole funct7 values for R-type, of which the
// alternate one exists for only two funct3 values. Both facts are needed to call
// an encoding illegal: funct7 = 0x21 is not SUB, not ADD, and not anything.
`define RV_F7_BASE 7'h00
`define RV_F7_ALT  7'h20

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

// Storage depth, in the units each model is addressed in: imem is a word array,
// dmem is a byte array. Both are 8 KiB, which is the smallest power of two that
// holds a linked RV32I test image and its data and stack without wrapping; the
// sky130 wrappers build both out of the PDK's 2 KiB macros, so these numbers must
// stay whole multiples of 2 KiB. A fetch or access above the end of storage
// wraps, so the compliance harness checks that an image fits instead of letting
// it silently alias.
`define IMEM_WORDS 2048
`define DMEM_BYTES 8192

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

// --------------------------------------------------------------- trap cause --
// Architectural exception causes, so that a later CSR version can write them
// straight into mcause without re-deriving anything. Values are the privileged
// spec's, not this core's: 0, 2, 3, 4, 6 and 11 are instruction-address
// misaligned, illegal instruction, breakpoint, load address misaligned, store
// address misaligned and environment call from M-mode. Four bits holds all six
// and is narrower than mcause's XLEN-wide field, which is the right direction to
// be wrong in: adding a cause is a define, not a refactor.
`define TRAP_CAUSE_W        4
`define TRAP_INSTR_MISALIGN 4'd0
`define TRAP_ILLEGAL_INSTR  4'd2
`define TRAP_BREAKPOINT     4'd3
`define TRAP_LOAD_MISALIGN  4'd4
`define TRAP_STORE_MISALIGN 4'd6
`define TRAP_ECALL_M        4'd11

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
