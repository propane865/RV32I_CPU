// Hazard control unit
//
// Two independent reasons to disturb the front of the pipeline:
//
//   load-use  - the instruction in ID reads a register that the load currently
//               in EX has not written back yet. One bubble would deliver stale
//               data, so PC and IF/ID are frozen for a cycle while a bubble is
//               injected into ID/EX; the load then forwards from EX/MEM.
//
//   redirect  - a branch or jump taken in execute 2. The two instructions
//               already fetched from the wrong path are simply discarded.
//
// The load detect lives here rather than being assembled in the datapath, so
// that "what counts as a load" has one home next to the logic that uses it.
module hazard_unit (
    input  wire        i_id_ex_reg_w_ena,
    input  wire        i_id_ex_mem_w_ena,
    input  wire [1:0]  i_id_ex_wb_sel,
    input  wire [4:0]  i_id_ex_rd,
    input  wire [4:0]  i_if_id_rs1,
    input  wire [4:0]  i_if_id_rs2,
    input  wire        i_pc_redirect,

    output wire        o_stall_pc,
    output wire        o_stall_if_id,
    output wire        o_flush_if_id,
    output wire        o_flush_id_ex,
    output wire        o_flush_ex1_ex2
);
    `include "defines.vh"

    // A load is the only instruction that writes a register from memory data.
    // Stores write memory but never a register, so mem_w_ena must be clear.
    wire is_load = i_id_ex_reg_w_ena && !i_id_ex_mem_w_ena
                 && (i_id_ex_wb_sel == `WB_MEM);

    // x0 is hardwired to zero, so a dependency on it is never a hazard.
    wire uses_rs1 = (i_id_ex_rd == i_if_id_rs1) && (i_if_id_rs1 != 5'h0);
    wire uses_rs2 = (i_id_ex_rd == i_if_id_rs2) && (i_if_id_rs2 != 5'h0);

    wire load_use = is_load && (uses_rs1 || uses_rs2);

    assign o_stall_pc      = load_use;
    assign o_stall_if_id   = load_use;

    assign o_flush_id_ex   = load_use | i_pc_redirect;
    assign o_flush_if_id   = i_pc_redirect;
    assign o_flush_ex1_ex2 = i_pc_redirect;
endmodule
