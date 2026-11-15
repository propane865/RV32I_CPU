`timescale 1ns/1ns
// Exception detection - the whole instruction, in execute 2
//
// One combinational unit that answers "does the instruction in execute 2 raise an
// exception, and which one". It has no state and no clock: everything it needs is
// either a decoded qualifier that came down the pipeline with the instruction, or
// an address that execute 2 itself computes.
//
// WHY EXECUTE 2, AND WHY THAT IS NOT AN ACCIDENT
//
// An exception has to be detected at the last point where the instruction can
// still be prevented from having any effect, and no later - and that point is
// exactly where a branch or jump resolves. Before execute 2 a taken branch is not
// yet known to be taken, and its target is not yet known either, so an
// instruction-address-misaligned exception cannot be decided. After execute 2 the
// instruction has issued its memory access. So the same stage that already ends a
// redirect ends an exception, and the exception reuses the redirect's own
// machinery: squash everything younger, keep this instruction out of the memory
// stage, and - unlike a redirect - do not transfer control anywhere.
//
// That also makes the exception precise without any bookkeeping: everything older
// than the trapping instruction has already reached the memory stage and retires
// normally, everything younger is discarded, and the trapping instruction itself
// writes nothing. The core then stops, because this build has no handler to
// return to (no CSRs, no mcause, no mret) - see the trap_q latch in rtl/datapath.v.
//
// THE CAUSES, AND THE ORDER AMONG THEM
//
// Illegal instruction first, because for an encoding that does not exist, the
// address it would have used and the target it would have jumped to are not
// wrong, they are meaningless: reporting a misalignment derived from them would
// invent a fact.
//
// The rest are listed in the order the plan specifies - instruction address, then
// load, then store, then breakpoint, then environment call - but the order is
// documentation rather than arbitration, because no two of them can be asserted by
// the same instruction: an instruction either accesses memory or redirects, never
// both, and ECALL and EBREAK are distinguished by the encoding alone. Saying so
// here is better than letting a reader assume a conflict was resolved, because a
// future cause that CAN overlap - a fetch exception on the same cycle as a
// previous instruction's store exception, say - would need the priority to be real.
module trap_unit (
    // Decoded qualifiers, carried down the pipeline with the instruction. The
    // memory fields are the same ones the memory stage and the hazard unit use -
    // this unit does not get to invent its own idea of what a load is.
    input  wire        i_illegal,
    input  wire        i_is_ecall,
    input  wire        i_is_ebreak,
    input  wire        i_mem_r_ena,
    input  wire        i_mem_w_ena,
    input  wire [1:0]  i_mem_width,

    // What execute 2 knows about this instruction's addresses. Two bits each, not
    // 32, because alignment is all this unit reads out of an address and an
    // exception unit that took the whole word would invite someone to add a check
    // on the bits above it that cannot exist.
    input  wire [1:0]  i_addr_lo,   // effective address (the execute 1 result), low bits
    input  wire        i_redirect,  // a branch or jump that really will be taken
    input  wire [1:0]  i_target_lo, // transfer target, low bits, JALR's ~1 already applied

    output wire        o_trap,
    output wire [`TRAP_CAUSE_W-1:0] o_cause   // meaningful only when o_trap is set
);
    `include "defines.vh"

    // Natural alignment, by access size. A byte is always aligned, so it is not
    // tested at all - and testing it would be a bug, since byte accesses have no
    // misaligned case to catch. Halfword accesses care about bit 1 of the address
    // (addr[0]), word accesses about bits [1:0].
    //
    // A wider load would be wrong here in both directions: an RV32E-style 8-byte
    // access would need addr[2:0], and testing a byte for addr[1:0] != 0 would
    // reject every odd-addressed LB, which is legal.
    wire misaligned_by_width =
        (i_mem_width == `MEM_W) ? (i_addr_lo != 2'b00) :
        (i_mem_width == `MEM_H) ? (i_addr_lo[0] != 1'b0) : 1'b0;

    wire load_misaligned  = i_mem_r_ena & misaligned_by_width;
    wire store_misaligned = i_mem_w_ena & misaligned_by_width;

    // Instruction address. Only a transfer that is actually taken can be
    // misaligned - a branch that falls through has no target to check, and its
    // sequential PC+4 never is. The target arrives with JALR's `and ~1` already
    // applied, which is the architectural order: JALR computes (rs1 + imm) and
    // clears bit 0, and *then* the result must be 4-byte aligned in a core without
    // the C extension. Checking the unmasked sum would report an exception for
    // `jalr rs1, 1(rs2)`, which is legal - and bit 0 of the pair here is the masked
    // one, so it is always zero for a JALR, which costs nothing to check.
    wire instr_misaligned = i_redirect & (i_target_lo != 2'b00);

    assign o_trap = i_illegal | instr_misaligned | load_misaligned |
                    store_misaligned | i_is_ebreak | i_is_ecall;

    assign o_cause =
        i_illegal         ? `TRAP_ILLEGAL_INSTR  :
        instr_misaligned  ? `TRAP_INSTR_MISALIGN :
        load_misaligned   ? `TRAP_LOAD_MISALIGN  :
        store_misaligned  ? `TRAP_STORE_MISALIGN :
        i_is_ebreak       ? `TRAP_BREAKPOINT     :
                            `TRAP_ECALL_M;
endmodule
