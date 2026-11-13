`timescale 1ns/1ns
// Forwarding unit - chooses where each execute-stage operand comes from
//
// Three candidate producers, checked newest first, because the most recent write
// is the one whose value the younger instruction needs:
//
//   FWD_EX1    execute 1 result, from the instruction one stage ahead
//   FWD_EXMEM  execute 1 result, two stages ahead
//   FWD_MEMWB  writeback value, three stages ahead (a load's read data only
//              exists this late, which is why the oldest stage is still needed)
//   FWD_NONE   the register file value is already correct
//
// rd == 0 never forwards: x0 is architecturally zero, and forwarding one would
// hand an operand a value the ISA says must not exist. The register file already
// discards writes to x0 on its own, so this check is about reads, not writes.
//
// The two operands go through the identical decode, so it is written once and
// applied to both lanes. It used to be two copies that differed only in which
// source register they compared - the sort of duplication that drifts, since
// fixing a priority case in one copy leaves the other quietly holding the old
// rule.
//
// A function would read better here, and was tried: it is a trap. A function
// called from a continuous assignment has only its ARGUMENTS in that assignment's
// sensitivity list, so the signals it reads from the enclosing module do not
// trigger re-evaluation. The first version of this fold produced stale operands
// and failed five tests. A generate over the two lanes has one definition and no
// such dependency on how a simulator builds sensitivity lists.
module forwarding_unit(input ex1ex2_reg_w_ena, exmem_reg_w_ena, memwb_reg_w_ena, input [4:0] ex1ex2_rd, exmem_rd, memwb_rd, idex_rs1, idex_rs2, output [1:0] forward_a, forward_b);
    `include "defines.vh"

    // forward_sel[0] is operand A, forward_sel[2] is operand B; the port
    // declarations slice it back into the two signals the datapath expects.
    wire [3:0] forward_sel;

    genvar lane;
    generate
        for (lane = 0; lane < 2; lane = lane + 1) begin : LANE
            // Which source register this operand lane must read, and the resulting
            // select code. Everything below is identical for both lanes.
            wire [4:0] src = (lane == 0) ? idex_rs1 : idex_rs2;

            assign forward_sel[lane*2 +: 2] =
                (ex1ex2_reg_w_ena && ex1ex2_rd != 5'b0 && ex1ex2_rd == src)
                    ? `FWD_EX1 :
                (exmem_reg_w_ena && exmem_rd != 5'b0 && exmem_rd == src)
                    ? `FWD_EXMEM :
                (memwb_reg_w_ena && memwb_rd != 5'b0 && memwb_rd == src)
                    ? `FWD_MEMWB : `FWD_NONE;
        end
    endgenerate

    assign forward_a = forward_sel[1:0];
    assign forward_b = forward_sel[3:2];
endmodule
