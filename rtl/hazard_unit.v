`timescale 1ns/1ns
// Hazard control unit
//
// Two independent reasons to disturb the front of the pipeline:
//
//   load-use  - the instruction in ID reads a register that a load has not
//               produced yet. PC and IF/ID are frozen and a bubble is injected
//               into ID/EX until the value can be handed over.
//
//   discard   - a branch or jump taken in execute 2, or an exception raised there.
//               The instructions already fetched from the wrong path are simply
//               discarded, and while the core is stopped the injection continues.
//
// HOW LONG A LOAD-USE WAIT IS, AND WHY IT IS EXACTLY THAT LONG
//
// A load's value is not its ALU result - the ALU result is its address. The value
// is the word the data memory reads, and the memory presents that word one cycle
// after the address, which is the load's own writeback cycle, because its read
// port is a flop in both memory implementations (rtl/mem/dmem.v). So the earliest
// cycle at which a load's value exists for anyone is the cycle the load sits in
// writeback, where the MEM/WB forwarding path can hand it across.
//
// Therefore: hold the consumer in decode while its producer load is in execute 1
// or execute 2 - that is, hold it until the cycle the load reaches writeback - and
// no longer. Counting what that means for a load at pipeline index 0:
//
//   cycle            2    3    4    5
//   load             EX1  EX2  MEM  WB
//   consumer (idx 1) ID   ID   ID   EX1     <- held for two cycles
//   consumer (idx 3)      ID   ID   EX1     <- held for one
//
// Two-cycle penalty on an immediately-dependent consumer, one bubble for the next
// slot over, and none from index 3 onwards, where the register file (which
// read-throughs its own write) already has the value.
//
// Watching exactly those two stages is not just sufficient, it is what makes the
// rest of the forwarding table total: a consumer can only be in execute 1 while a
// load it depends on is in writeback or later, because being in execute 1 or
// execute 2 in the previous cycle would have stalled it. So FWD_EX1 and FWD_EXMEM
// can never be asked to forward a load - which is the property that lets
// rtl/datapath.v mark that case impossible instead of quietly returning the
// address, which is what this core used to do.
//
// Whether a dependency exists is decided per source register by the decoder's
// uses_rs1 / uses_rs2, so an instruction that does not read a register is never
// held up by it, and x0 is excluded on top: it reads as zero whatever a pending
// write says it is being written with.
module hazard_unit (
    // Producer candidates: the two stages a load can occupy while its consumer is
    // still in decode. mem_r_ena is the decoder saying "this instruction reads
    // memory into a register", which is all this unit needs to know - it does not
    // get to invent its own test for what a load is.
    input  wire        i_id_ex_mem_r_ena,
    input  wire [4:0]  i_id_ex_rd,
    input  wire        i_ex1_ex2_mem_r_ena,
    input  wire [4:0]  i_ex1_ex2_rd,

    // Consumer: the instruction sitting in decode, held by the stall
    input  wire [4:0]  i_id_rs1,
    input  wire [4:0]  i_id_rs2,
    input  wire        i_id_uses_rs1,
    input  wire        i_id_uses_rs2,

    // Slots younger than execute 2 that must not execute: a taken redirect (they
    // were fetched from the abandoned path) or an exception in execute 2 (the same,
    // plus the machine is stopping). Named for the request rather than for one of
    // its two sources, because a bubble must be injected for either, and the
    // distinction belongs to the exception logic, not here.
    input  wire        i_discard_younger,

    output wire        o_stall_pc,
    output wire        o_stall_if_id,
    output wire        o_flush_if_id,
    output wire        o_flush_id_ex,
    output wire        o_flush_ex1_ex2
);
    `include "defines.vh"

    // Does the instruction in decode read the register this stage's load writes?
    //
    // A function, because the same question is asked of two stages and two
    // operand lanes and a fourth copy of it is exactly how the two lanes used to
    // disagree. It is called from continuous assignments, which is safe here and
    // only here: every signal it looks at is one of its arguments, so the
    // assignment's sensitivity list covers all of them. (rtl/forwarding_unit.v
    // documents the failure mode when a function reads its enclosing module
    // instead - stale operands, silently.)
    function reads;
        input        uses;     // does this operand lane read anything at all?
        input [4:0]  src;      // which register it must read
        input        is_load;  // does the producer write a register from memory?
        input [4:0]  rd;       // and which one
        begin
            reads = uses && is_load && (rd != 5'h0) && (src == rd);
        end
    endfunction

    wire waits_for_ex1 = reads(i_id_uses_rs1, i_id_rs1, i_id_ex_mem_r_ena,   i_id_ex_rd)
                      || reads(i_id_uses_rs2, i_id_rs2, i_id_ex_mem_r_ena,   i_id_ex_rd);

    wire waits_for_ex2 = reads(i_id_uses_rs1, i_id_rs1, i_ex1_ex2_mem_r_ena, i_ex1_ex2_rd)
                      || reads(i_id_uses_rs2, i_id_rs2, i_ex1_ex2_mem_r_ena, i_ex1_ex2_rd);

    wire load_use = waits_for_ex1 | waits_for_ex2;

    assign o_stall_pc      = load_use;
    assign o_stall_if_id   = load_use;

    // A stall injects a bubble where the consumer would otherwise have advanced;
    // a redirect or an exception discards everything younger than itself. Both
    // flush ID/EX, which is why the two requests arrive as one input: what a
    // consumer in decode does about either of them is identical.
    assign o_flush_id_ex   = load_use | i_discard_younger;
    assign o_flush_if_id   = i_discard_younger;
    assign o_flush_ex1_ex2 = i_discard_younger;
endmodule
