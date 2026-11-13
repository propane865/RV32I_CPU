// MEM/WB pipeline register
//
// Last staging register before the register file write port. See pipe_ex_mem.v
// for why the back half of the pipe has no flush input.
module pipe_mem_wb (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] i_alu_out,
    input  wire [31:0] i_mem_rdata,
    input  wire [31:0] i_pc_plus4,
    input  wire [4:0]  i_rd,
    input  wire [1:0]  i_wb_sel,
    input  wire        i_reg_w_ena,

    output wire [31:0] o_alu_out,
    output wire [31:0] o_mem_rdata,
    output wire [31:0] o_pc_plus4,
    output wire [4:0]  o_rd,
    output wire [1:0]  o_wb_sel,
    output wire        o_reg_w_ena
);
    // 3 words, 1 register address, 1 two-bit select, 1 single-bit control.
    localparam integer W = 32*3 + 5 + 2 + 1;

    localparam [W-1:0] BUBBLE = {
        32'h0, 32'h0, 32'h0,   // alu_out, mem_rdata, pc_plus4
        5'h0,                  // rd
        2'b0,                  // wb_sel
        1'b0                   // reg_w_ena
    };

    // PACK, UNPACK and BUBBLE list the fields in the same order.
    wire [W-1:0] pack = {
        i_alu_out, i_mem_rdata, i_pc_plus4,
        i_rd,
        i_wb_sel,
        i_reg_w_ena
    };

    reg [W-1:0] q;

    always @(posedge clk) begin
        q <= rst ? BUBBLE : pack;
    end

    assign { o_alu_out, o_mem_rdata, o_pc_plus4,
             o_rd,
             o_wb_sel,
             o_reg_w_ena } = q;
endmodule
