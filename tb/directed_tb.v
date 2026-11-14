`timescale 1ns/1ns
// Directed pipeline-control regression
//
// Companion to tb/core_tb.v. Where core_tb asks "does this instruction compute
// the right value", this testbench asks the questions that only a pipeline can
// get wrong: which instruction is in which stage when two control events land in
// the same cycle, and whether a discarded instruction really is discarded.
//
// Every program here is built so that the interesting cycle has TWO control
// requests at once - a taken branch or jump resolving in execute 2 while a
// load-use hazard is freezing the front end - because that is where the PC
// update used to give the stall priority over the redirect and lose the
// redirect for good (rtl/pc.v, bug B1). A program whose redirect target happens
// to be the address the stalled PC is already holding cannot detect that, so the
// targets here are deliberately placed somewhere the sequential path does not
// reach on time: the instruction right behind the wrong-path consumer is a
// marker that must stay zero, and only zero, while the target marker must be
// 99.
//
// Programs are hand-encoded hex, in the same style as core_tb, with the
// disassembly on the same line as the word so a reviewer can check the encoding
// without an assembler.
module directed_tb;

    reg clk, rst;
    wire [31:0] pc_out, dmem_addr, dmem_wdata, dmem_rdata;
    wire [1:0] dmem_width;
    wire dmem_w_ena;

    rv32i_core DUT (.clk(clk), .rst(rst), .pc_out(pc_out),
                    .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
                    .dmem_rdata(dmem_rdata), .dmem_w_ena(dmem_w_ena),
                    .dmem_width(dmem_width));

    initial clk = 0;
    always #5 clk = ~clk;

    // The memories sit one level deeper than the rest of the hierarchy because
    // rtl/mem/{imem,dmem}.v pick a model at elaboration time; IMPL is whichever
    // one was selected. Same paths core_tb uses.
    `define RF   DUT.DP.RF.regs
    `define IMEM DUT.DP.IMEM.IMPL.mem
    `define DMEM DUT.DP.DMEM.IMPL.mem

    // Storage depth. Kept as locals so the clear loops cannot outgrow the model.
    localparam IMEM_WORDS = 1024;
    localparam DMEM_BYTES = 4096;

    integer failed = 0;

    function [31:0] read_reg;
        input [4:0] rnum;
        begin
            read_reg = (rnum == 5'b0) ? 32'b0 : `RF[rnum];
        end
    endfunction

    task check_reg;
        input [4:0]   rnum;
        input [31:0]  expected;
        input [255:0] name;
        begin
            if (read_reg(rnum) !== expected) begin
                $display("FAIL %-24s | x%-2d = 0x%08h | expected 0x%08h",
                        name, rnum, read_reg(rnum), expected);
                failed = failed + 1;
            end else
                $display("PASS %-24s | x%-2d = 0x%08h", name, rnum, read_reg(rnum));
        end
    endtask

    task run_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
            #1;
        end
    endtask

    // Fresh machine for every program: rst does not clear the register file, so a
    // test that expects a register to still be zero has to say so by clearing it.
    task clear_all;
        integer j;
        begin
            for (j = 0; j < IMEM_WORDS; j = j + 1) `IMEM[j] = 32'h00000013;
            for (j = 0; j < DMEM_BYTES; j = j + 1) `DMEM[j] = 8'h00;
            for (j = 1; j < 32;  j = j + 1) `RF[j]   = 32'h0;
        end
    endtask

    task release_reset;
        begin
            @(posedge clk);
            @(posedge clk);
            rst = 0;
            #1;
        end
    endtask

    // ---------------------------------------------------------------------------
    // Redirect vs. load-use stall, in the same cycle.
    //
    // Stage occupancy in the cycle the control transfer resolves (execute 2):
    //
    //   cycle T   branch/jump in EX2   load in EX1   dependent op in ID
    //
    // which is exactly the shape "producer, consumer, control transfer" does not
    // have and "control transfer, load, load's consumer" does: the transfer is
    // fetched first, so it is the oldest of the three and resolves while the load
    // is one stage behind it and the consumer is still in decode.
    //
    // The load reads a word that is preloaded with a non-zero pattern, so "the
    // wrong-path load never wrote its destination register" is a real check
    // rather than a check against the reset value of memory.
    // ---------------------------------------------------------------------------

    // The value preloaded at data word 0. No test may expect a register to hold
    // this and still be a meaningful check on the load path.
    localparam [31:0] LOAD_DATA = 32'h0000_ABCD;

    // All four programs below have the same shape, differing only in the control
    // transfer at 0x00c:
    //
    //   0x000  ADDI x6, x0, 7          addend for the wrong-path consumer
    //   0x004  setup                   (branch operands, or the JALR base)
    //   0x008  setup
    //   0x00c  control transfer  ->0x020
    //   0x010  LW   x3, 0(x0)          wrong path, load-use producer
    //   0x014  ADD  x5, x3, x6         wrong path, load-use consumer
    //   0x018  ADDI x8, x0, 77         wrong-path marker: the address the fetch is
    //                                  at in the cycle the transfer resolves, so
    //                                  it runs if and only if the redirect is lost
    //   0x01c  NOP
    //   0x020  ADDI x7, x0, 99         redirect target
    //
    //   x3 and x5 are the wrong path's register writes and must stay 0; x8 is the
    //   lost-redirect marker and must stay 0; x7 must be 99.
    task redirect_hazard_prologue;
        begin
            clear_all;
            `DMEM[0] = 8'hCD;  `DMEM[1] = 8'hAB;   // LOAD_DATA at word 0
            `DMEM[2] = 8'h00;  `DMEM[3] = 8'h00;
            `IMEM[0] = 32'h00700313; // ADDI x6, x0, 7
            `IMEM[4] = 32'h00002183; // LW   x3, 0(x0)   wrong path, producer
            `IMEM[5] = 32'h006182b3; // ADD  x5, x3, x6  wrong path, consumer
            `IMEM[6] = 32'h04d00413; // ADDI x8, x0, 77  wrong-path marker
            `IMEM[7] = 32'h00000013; // NOP
            `IMEM[8] = 32'h06300393; // ADDI x7, x0, 99  redirect target
        end
    endtask

    // Test 1: BEQ taken while a load-use stall freezes the PC.
    task test_redirect_load_use_beq;
        begin
            $display("\n--- D1: BEQ taken + load-use stall ---");
            rst = 1;
            redirect_hazard_prologue;
            `IMEM[1]  = 32'h00100093; // ADDI x1, x0, 1
            `IMEM[2]  = 32'h00100113; // ADDI x2, x0, 1   x1 == x2, so BEQ is taken
            `IMEM[3]  = 32'h00208a63; // BEQ  x1, x2, +20 -> 0x020
            release_reset;
            run_cycles(24);
            check_reg(7, 32'd99,       "BEQ+stall target ran");
            check_reg(8, 32'h0,        "BEQ+stall skipped");
            check_reg(3, 32'h0,        "BEQ+stall no load wr");
            check_reg(5, 32'h0,        "BEQ+stall no add wr");
        end
    endtask

    // Test 2: the same shape with BNE, so the taken verdict does not come from
    // equality - the two conditions share almost no decode logic.
    task test_redirect_load_use_bne;
        begin
            $display("\n--- D2: BNE taken + load-use stall ---");
            rst = 1;
            redirect_hazard_prologue;
            `IMEM[1]  = 32'h00100093; // ADDI x1, x0, 1
            `IMEM[2]  = 32'h00200113; // ADDI x2, x0, 2   x1 != x2, so BNE is taken
            `IMEM[3]  = 32'h00209a63; // BNE  x1, x2, +20 -> 0x020
            release_reset;
            run_cycles(24);
            check_reg(7, 32'd99,       "BNE+stall target ran");
            check_reg(8, 32'h0,        "BNE+stall skipped");
            check_reg(3, 32'h0,        "BNE+stall no load wr");
        end
    endtask

    // Test 3: JAL, which resolves unconditionally, so there is no question of
    // whether the transfer should have been taken at all.
    task test_redirect_load_use_jal;
        begin
            $display("\n--- D3: JAL + load-use stall ---");
            rst = 1;
            redirect_hazard_prologue;
            `IMEM[1]  = 32'h00000013; // NOP
            `IMEM[2]  = 32'h00000013; // NOP
            `IMEM[3]  = 32'h014000ef; // JAL  x1, +20     -> 0x020, x1 = 0x010
            release_reset;
            run_cycles(24);
            check_reg(7, 32'd99,       "JAL+stall target ran");
            check_reg(1, 32'h00000010, "JAL+stall link");
            check_reg(8, 32'h0,        "JAL+stall skipped");
            check_reg(3, 32'h0,        "JAL+stall no load wr");
        end
    endtask

    // Test 4: JALR, whose target comes from a register - the one redirect whose
    // own operand needs forwarding (x2 was written one instruction earlier).
    task test_redirect_load_use_jalr;
        begin
            $display("\n--- D4: JALR + load-use stall ---");
            rst = 1;
            redirect_hazard_prologue;
            `IMEM[1]  = 32'h00000013; // NOP
            `IMEM[2]  = 32'h02000113; // ADDI x2, x0, 32   jump base = 0x020
            `IMEM[3]  = 32'h000100e7; // JALR x1, x2, 0    -> 0x020, x1 = 0x010
            release_reset;
            run_cycles(24);
            check_reg(7, 32'd99,       "JALR+stall target ran");
            check_reg(1, 32'h00000010, "JALR+stall link");
            check_reg(8, 32'h0,        "JALR+stall skipped");
            check_reg(3, 32'h0,        "JALR+stall no load wr");
        end
    endtask

    initial begin
`ifndef NODUMP
        $dumpfile("build/directed_tb.vcd");
        $dumpvars(0, directed_tb);
`endif
        clk = 0;
        rst = 1;

        test_redirect_load_use_beq;
        test_redirect_load_use_bne;
        test_redirect_load_use_jal;
        test_redirect_load_use_jalr;

        $display("\n========================================");
        if (failed == 0)
            $display("ALL DIRECTED TESTS PASSED");
        else
            $display("%0d DIRECTED TEST(S) FAILED", failed);
        $display("========================================\n");
        $finish;
    end

endmodule
