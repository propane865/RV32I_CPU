`timescale 1ns/1ns
// CPU control unit - main decode
//
// Purely combinational: instruction fields in, control fields out. The decode is
// total: every one of the 2^32 instruction words is either a legal RV32I
// instruction this core implements, or it is reported by `illegal`. An illegal
// encoding asserts nothing at all - no register write, no memory access, no PC
// redirect - because legality is decided once from the whole instruction rather
// than per case arm. An arm that defends only its own field is how funct7 = 0x21
// came to execute as ADD, and how LOAD funct3 = 3'b011 came to write zero to rd.
//
// Every output is a reg given a default at the top of the block, so a field the
// opcode does not use keeps its default rather than latching something stale.
//
// The ALU control surface is just `alu_op`: the operation code says whether to
// invert B, whether to carry-in, and which way to shift. `cmp_sgn` is the odd one
// out - it is not consumed by the ALU at all but by the comparison unit one stage
// later. It has to be set for BOTH users of comparisons: SLT/SLTI, and the four
// ordering branches (BLT/BGE signed, BLTU/BGEU unsigned). A branch decode that
// forgets it still passes every BEQ/BNE test, because equality does not depend on
// signedness - which is exactly how this bug survived for so long.
// funct7 is taken as the whole architectural field even though RV32I only uses
// bit 5 of it (SUB vs ADD, SRA vs SRL); narrowing the port to one bit would hide
// which instruction field it came from - and the whole field is what makes an
// unrecognised R-type encoding detectable.
/* verilator lint_off UNUSEDSIGNAL */
module control(input  [6:0] opcode, funct7,
               input  [2:0] funct3,
               // instr[31:20]. Nothing here looks at it except SYSTEM, where it is
               // the only thing that tells ECALL from EBREAK.
               input  [11:0] imm12,
               output reg alu_src, reg_w_ena, mem_w_ena, mem_r_ena, mem_signed,
                        cmp_sgn, uses_rs1, uses_rs2, branch, jump, jalr,
               output reg [1:0] alu_src_a, wb_sel, mem_width,
               output reg [3:0] alu_op,
               output reg [2:0] imm_sel, branch_cond,
               // Decode verdicts, continuous: they are answers about the encoding,
               // not fields of an instruction, so no case arm owns them. All three
               // are consumed in execute 2 by rtl/trap_unit.v. FENCE needs no
               // verdict of its own: what makes it a legal no-op is that it is not
               // illegal, and it is the memory system - one outstanding access per
               // port, nothing to order - that makes the no-op correct.
               output wire illegal, is_ecall, is_ebreak);
/* verilator lint_on UNUSEDSIGNAL */
    `include "defines.vh"

    wire is_sub = (opcode == `RV_OP) && funct7[`RV_FUNC7_B5];

    // =========================================================================
    // Legal encodings, decided once from the whole instruction
    //
    // One place, because the question "may this encoding execute?" has to have one
    // answer. Asked per case arm, each arm only ever rejects the field it looks at,
    // which is how an unrecognised funct7 executed as ADD and an illegal LOAD
    // funct3 wrote a zero to rd: both were "not my field".
    // =========================================================================
    wire f7_base = (funct7 == `RV_F7_BASE);
    wire f7_alt  = (funct7 == `RV_F7_ALT);

    // R-type: RV32I defines exactly these two funct7 values, and the alternate one
    // exists for two funct3 values only - SUB and SRA. funct7 = 0x21 is neither
    // ADD nor SUB nor anything else; it must not execute.
    wire op_illegal = ~f7_base & ~(f7_alt & ((funct3 == `RV_F3_ADD) |
                                             (funct3 == `RV_F3_SRL)));

    // I-type ALU: for every form but the two shifts, the top seven bits are
    // immediate data (imm[11:5]) and any value is legal. SLLI requires them zero;
    // SRLI and SRAI share a funct3 and are told apart by it alone.
    wire op_imm_illegal = ((funct3 == `RV_F3_SLL) & ~f7_base)
                       | ((funct3 == `RV_F3_SRL) & ~(f7_base | f7_alt));

    // Five load widths out of eight funct3 values, three store widths out of
    // eight. The missing three loads are 3'b011 and 3'b111 (the store forms with
    // the signedness bit set); the missing stores are 3'h3 through 3'h7.
    wire load_illegal = ~((funct3 == `RV_F3_LB)  | (funct3 == `RV_F3_LH) |
                          (funct3 == `RV_F3_LW)  | (funct3 == `RV_F3_LBU) |
                          (funct3 == `RV_F3_LHU));
    wire store_illegal = ~((funct3 == `RV_F3_SB) | (funct3 == `RV_F3_SH) |
                           (funct3 == `RV_F3_SW));

    // Branches take six of the eight: BEQ, BNE and the four ordering forms. funct3
    // 2 and 3 are the holes, and they used to decode as branch_cond 2 and 3, which
    // the branch unit read as neither-equal-nor-ordering and never took.
    wire branch_illegal = (funct3 == 3'h2) | (funct3 == 3'h3);

    // JALR, FENCE and SYSTEM each have exactly one funct3; anything else on those
    // opcodes is a different instruction (or, for SYSTEM, a CSR form) that this
    // core does not have.
    wire f3_zero = (funct3 == 3'h0);

    // JALR has no sub-encodings; anything but funct3 = 0 is not a JALR.
    wire jalr_illegal = ~f3_zero;

    // FENCE is the only encoding MISC-MEM has.
    wire fence_illegal = ~f3_zero;

    // SYSTEM holds ECALL, EBREAK, and everything the privileged architecture puts
    // behind funct3 != 0 - the CSRRW/CSRRS/... forms and FENCE.I. Neither the CSRs
    // nor Zifencei is implemented, so calling all of them illegal is what turns
    // "no CSR block" from a claim into a checked property.
    wire system_illegal = ~f3_zero |
                          ((imm12 != 12'h000) & (imm12 != 12'h001));

    wire opcode_known = (opcode == `RV_OP)      | (opcode == `RV_OP_IMM) |
                        (opcode == `RV_LOAD)    | (opcode == `RV_STORE)  |
                        (opcode == `RV_BRANCH)  | (opcode == `RV_LUI)    |
                        (opcode == `RV_AUIPC)   | (opcode == `RV_JAL)    |
                        (opcode == `RV_JALR)    | (opcode == `RV_OP_FENCE) |
                        (opcode == `RV_OP_SYSTEM);

    assign illegal = ~opcode_known
                 | ((opcode == `RV_OP)        & op_illegal)
                 | ((opcode == `RV_OP_IMM)    & op_imm_illegal)
                 | ((opcode == `RV_LOAD)      & load_illegal)
                 | ((opcode == `RV_STORE)     & store_illegal)
                 | ((opcode == `RV_BRANCH)    & branch_illegal)
                 | ((opcode == `RV_JALR)      & jalr_illegal)
                 | ((opcode == `RV_OP_FENCE)  & fence_illegal)
                 | ((opcode == `RV_OP_SYSTEM) & system_illegal);

    // Legal, write nothing, and not NOPs in the architectural sense either: ECALL
    // and EBREAK because their whole effect is the trap. They are named here rather
    // than left for the trap path to re-recognise from an opcode and an immediate,
    // because by execute 2 the instruction is no longer available, only what decode
    // said about it.
    assign is_ecall  = (opcode == `RV_OP_SYSTEM)  &  f3_zero & (imm12 == 12'h000);
    assign is_ebreak = (opcode == `RV_OP_SYSTEM)  &  f3_zero & (imm12 == 12'h001);

    always @(*) begin
        // Initialize default signal values
        alu_op    = `ALU_ADD;
        cmp_sgn   = 0;
        alu_src = 0;
        alu_src_a = `ALU_A_RS1;
        reg_w_ena = 0;
        mem_w_ena = 0;
        // A load is the one instruction that writes a register from memory data,
        // and several stages need to know that: the hazard unit waits for it, and
        // the forwarding paths must never try to produce its value early. Saying
        // so here, at the point where the opcode is decoded, is what stops each
        // of them inventing its own test for "is this a load".
        mem_r_ena = 0;
        mem_width = `MEM_W;
        mem_signed = 0;
        wb_sel = `WB_ALU;
        branch = 0;

        // Which source registers this instruction actually reads. The hazard unit
        // needs these to avoid waiting for a register nobody reads: without them,
        // `lw x1, 0(x2)` followed by `lui x1, 0` looks like a dependency on x1 even
        // though LUI reads nothing at all, and every I-type instruction looks
        // dependent on its (unused) rs2 field. They describe the instruction, not
        // the operand values, so they cost nothing to produce here and need no
        // pipeline field - the consumer is always in decode, next to them.
        uses_rs1 = 0;
        uses_rs2 = 0;
        jump = 0;
        jalr = 0;
        imm_sel = `IMM_I;
        branch_cond = 0;

        // An unrecognised or half-recognised encoding stops here: the defaults
        // above stand, so it retires having touched nothing. rtl/trap_unit.v turns
        // the same verdict into a reported exception.
        if (!illegal) begin
        case (opcode)
            // -----------------------------------------------------------------
            // R-type (OP) and register-immediate (OP_IMM) ALU instructions.
            //
            // These share one decode: for every funct3 they compute the same
            // operation, and they differ only in where ALU input B comes from
            // (rs2 vs the immediate). They used to be two ~100-line copies of
            // each other, so every change had to be made twice.
            // -----------------------------------------------------------------
            `RV_OP, `RV_OP_IMM: begin
                reg_w_ena = 1;
                // R-type reads both operands; register-immediate reads only rs1.
                uses_rs1 = 1;
                uses_rs2 = (opcode == `RV_OP);
                // The only real difference between the two opcodes.
                alu_src   = (opcode == `RV_OP) ? 1'b0 : 1'b1;
                imm_sel   = `IMM_I;

                case (funct3)
                    // ADD / SUB / ADDI
                    // ADD / SUB / ADDI. Only R-type can subtract: for OP_IMM,
                    // funct7 overlaps the top bits of the immediate, so bit 5
                    // there is operand data, not an opcode extension.
                    `RV_F3_ADD: alu_op = is_sub ? `ALU_SUB : `ALU_ADD;

                    `RV_F3_XOR: alu_op = `ALU_XOR;
                    `RV_F3_OR:  alu_op = `ALU_OR;
                    `RV_F3_AND: alu_op = `ALU_AND;

                    // Shifts: the direction and the fill bit are part of the
                    // operation code, so the ALU needs no extra input.
                    `RV_F3_SLL: alu_op = `ALU_SHL;

                    // SRL/SRA and SRLI/SRAI: funct7[5] picks the fill.
                    `RV_F3_SRL: alu_op = funct7[`RV_FUNC7_B5] ? `ALU_SHA : `ALU_SHR;

                    // SLT / SLTI: signed less-than.
                    `RV_F3_SLT: begin
                        alu_op  = `ALU_CMP;
                        cmp_sgn = 1;   // signed: the comparator must be told
                    end

                    // SLTU / SLTIU: unsigned less-than (cmp_sgn stays 0).
                    `RV_F3_SLTU: alu_op = `ALU_CMP;

                    // Unreachable: funct3 has exactly eight values and all
                    // eight are decoded above.
                    default: ;
                endcase
            end

            // Load instructions (I-type)
            `RV_LOAD: begin
                // Enable register writing, ALU input B is from the immediate
                reg_w_ena = 1;
                uses_rs1 = 1;          // base address only
                alu_src = 1;

                // The memory stage reads, and does not write, on this one
                mem_r_ena = 1;

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
                uses_rs1 = 1;          // base address
                uses_rs2 = 1;          // stored value
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
                uses_rs1 = 1;
                uses_rs2 = 1;

                // Tell the comparator which comparison this branch wants.
                // funct3[1] is the signed flag across the four ordering forms:
                // BLT(100)/BGE(101) are signed, BLTU(110)/BGEU(111) unsigned.
                // (funct3[2] is not the flag - it separates the ordering forms
                // from BEQ/BNE.) BEQ and BNE only look at eq, which does not
                // depend on signedness, so the value they get here is a don't
                // care. Without this line every branch compares unsigned and
                // BLT is indistinguishable from BLTU.
                cmp_sgn = ~funct3[1];

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

                // Pass ALU input A (the immediate) straight through to writeback
                alu_op = `ALU_PASS;

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
                uses_rs1 = 1;          // the target base

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

            // FENCE: a decoded legal no-op, not a default fall-through. The
            // distinction is the whole point - this core has one outstanding access
            // per memory port, so there is nothing to order, but that is a property
            // of this memory system, not a reason to leave the encoding undecoded.
            `RV_OP_FENCE: ;      // uses no registers, writes nothing, no redirect -
                                 // the defaults say all of that, and uses_rs1/2 stay
                                 // 0 so the hazard unit does not hold FENCE behind a
                                 // load whose register its immediate bits happen to
                                 // name.

            // ECALL / EBREAK. Nothing to execute: the trap is raised in execute 2
            // from is_ecall / is_ebreak, by which point everything younger has been
            // flushed and this instruction has been kept out of the memory stage.
            // They read and write no registers, which is what the defaults already
            // say - a CSR form would have read one, and it is illegal (above).
            `RV_OP_SYSTEM: ;

            // Every opcode RV32I defines is listed above, and the illegal ones never
            // reach this case at all (the `if (!illegal)` above keeps them out), so
            // there is nothing left to fall through to: an unknown opcode is
            // `illegal`, not a NOP by omission.
            default: ;
        endcase
        end
    end
endmodule
