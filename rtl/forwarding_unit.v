`timescale 1ns/1ns
module forwarding_unit(input ex1ex2_reg_w_ena, exmem_reg_w_ena, memwb_reg_w_ena, input [4:0] ex1ex2_rd, exmem_rd, memwb_rd, idex_rs1, idex_rs2, output reg [1:0] forward_a, forward_b);
    `include "defines.vh"

    always @(*) begin
        if (ex1ex2_reg_w_ena && ex1ex2_rd != 5'b0 && ex1ex2_rd == idex_rs1) begin
            forward_a = `FWD_EX1;
        end
        else if (exmem_reg_w_ena && exmem_rd != 5'b0 && exmem_rd == idex_rs1) begin
            forward_a = `FWD_EXMEM;
        end
        else if (memwb_reg_w_ena && memwb_rd != 5'b0 && memwb_rd == idex_rs1) begin
            forward_a = `FWD_MEMWB;
        end
        else begin
            forward_a = `FWD_NONE;
        end

        if (ex1ex2_reg_w_ena && ex1ex2_rd != 5'b0 && ex1ex2_rd == idex_rs2) begin
            forward_b = `FWD_EX1;
        end
        else if (exmem_reg_w_ena && exmem_rd != 5'b0 && exmem_rd == idex_rs2) begin
            forward_b = `FWD_EXMEM;
        end
        else if (memwb_reg_w_ena && memwb_rd != 5'b0 && memwb_rd == idex_rs2) begin
            forward_b = `FWD_MEMWB;
        end
        else begin
            forward_b = `FWD_NONE;
        end
    end
endmodule
