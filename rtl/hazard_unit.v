module hazard_unit(input id_ex_mem_read, pc_src, input [4:0] id_ex_rd, if_id_rs1, if_id_rs2, output stall_pc, stall_if_id, flush_if_id, flush_id_ex, flush_ex1_ex2);
    `include "defines.vh"

    wire load_use = id_ex_mem_read && ((id_ex_rd == if_id_rs1 && if_id_rs1 != 5'b0) || (id_ex_rd == if_id_rs2 && if_id_rs2 != 5'b0));

    assign stall_pc = load_use;
    assign stall_if_id = load_use;

    assign flush_id_ex = load_use | pc_src;
    assign flush_if_id = pc_src;
    assign flush_ex1_ex2 = pc_src;
endmodule