module forwarding_unit(input ex1_ex2_reg_w_ena, ex_mem_reg_w_ena, mem_wb_reg_w_ena, input [4:0] ex1_ex2_rd, ex_mem_rd, mem_wb_rd, id_ex_rs1, id_ex_rs2, output reg [1:0] forward_a, forward_b);
    `include "defines.vh"

    always @(*) begin
        if (ex1_ex2_reg_w_ena && ex1_ex2_rd != 5'b0 && ex1_ex2_rd == id_ex_rs1) begin
            forward_a = `FWD_EX1;
        end
        else if (ex_mem_reg_w_ena && ex_mem_rd != 5'b0 && ex_mem_rd == id_ex_rs1) begin
            forward_a = `FWD_EXMEM;
        end
        else if (mem_wb_reg_w_ena && mem_wb_rd != 5'b0 && mem_wb_rd == id_ex_rs1) begin
            forward_a = `FWD_MEMWB;
        end
        else begin
            forward_a = `FWD_NONE;
        end

        if (ex1_ex2_reg_w_ena && ex1_ex2_rd != 5'b0 && ex1_ex2_rd == id_ex_rs2) begin
            forward_b = `FWD_EX1;
        end
        else if (ex_mem_reg_w_ena && ex_mem_rd != 5'b0 && ex_mem_rd == id_ex_rs2) begin
            forward_b = `FWD_EXMEM;
        end
        else if (mem_wb_reg_w_ena && mem_wb_rd != 5'b0 && mem_wb_rd == id_ex_rs2) begin
            forward_b = `FWD_MEMWB;
        end
        else begin
            forward_b = `FWD_NONE;
        end
    end
endmodule