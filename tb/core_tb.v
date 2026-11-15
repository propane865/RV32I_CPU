`timescale 1ns/1ns

module core_tb;

    `include "defines.vh"

    // DUT signals
    reg clk, rst;
    wire dmem_w_ena;
    wire [1:0] dmem_width;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata, pc_out;

    rv32i_core DUT (.clk(clk), .rst(rst), .pc_out(pc_out), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata), .dmem_w_ena(dmem_w_ena), .dmem_width(dmem_width));

    // Clock 
    initial clk = 0;
    always #5 clk = ~clk;

    // Shorthand paths. The memories sit one level deeper than the rest because
    // rtl/mem/imem.v and rtl/mem/dmem.v pick between a behavioural model and the
    // sky130 macros at elaboration time; IMPL is whichever one was selected.
    `define RF   DUT.DP.RF.regs
    `define IMEM DUT.DP.IMEM.IMPL.mem
    `define DMEM DUT.DP.DMEM.IMPL.mem

    // Helpers
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
        input [127:0] name;
        begin
            if (read_reg(rnum) !== expected) begin
                $display("FAIL %-20s | x%-2d = 0x%08h | expected 0x%08h",
                        name, rnum, read_reg(rnum), expected);
                failed = failed + 1;
            end else
                $display("PASS %-20s | x%-2d = 0x%08h", name, rnum, read_reg(rnum));
        end
    endtask

    task check_mem_word;
        input [12:0]  addr;
        input [31:0]  expected;
        input [127:0] name;
        reg [31:0] got;
        begin
            got = {`DMEM[addr+3], `DMEM[addr+2], `DMEM[addr+1], `DMEM[addr]};
            if (got !== expected) begin
                $display("FAIL %-20s | mem[0x%04h] = 0x%08h | expected 0x%08h",
                         name, addr, got, expected);
                failed = failed + 1;
            end else
                $display("PASS %-20s | mem[0x%04h] = 0x%08h", name, addr, got);
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

    // Clear memories and registers, ready for the next test.
    //
    // The register file is included on purpose: `rst` does not clear it (it is
    // only zeroed by the initial block at time 0), so without this every test
    // inherits the previous test's register values. That silently makes any
    // "register must still be zero" check meaningless.
    //
    // The bounds are the storage sizes in rtl/defines.vh (`IMEM_WORDS words of
    // instruction, `DMEM_BYTES bytes of data); a test that wrote above them would
    // not be cleared between runs, so they are named rather than counted.
    task clear_mem;
        integer j;
        begin
            for (j = 0; j < `IMEM_WORDS; j = j + 1) `IMEM[j] = 32'h00000013;
            for (j = 0; j < `DMEM_BYTES; j = j + 1) `DMEM[j] = 8'h00;
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

    // Test 1: Arithmetic & Logic
    task test_arith;
        begin
            $display("\n--- Test 1: Arithmetic & Logic ---");
            rst = 1;
            clear_mem;
            `IMEM[0] = 32'h00500093; // ADDI x1, x0, 5
            `IMEM[1] = 32'h00300113; // ADDI x2, x0, 3
            `IMEM[2] = 32'h002081b3; // ADD  x3, x1, x2
            `IMEM[3] = 32'h40208233; // SUB  x4, x1, x2
            `IMEM[4] = 32'h0020f2b3; // AND  x5, x1, x2
            `IMEM[5] = 32'h0020e333; // OR   x6, x1, x2
            `IMEM[6] = 32'h0020c3b3; // XOR  x7, x1, x2
            `IMEM[7] = 32'hfff00413; // ADDI x8, x0, -1
            `IMEM[8] = 32'h001404b3; // ADD  x9, x8, x1
            release_reset;
            run_cycles(15);
            check_reg(1, 32'h00000005, "ADDI +5");
            check_reg(2, 32'h00000003, "ADDI +3");
            check_reg(3, 32'h00000008, "ADD");
            check_reg(4, 32'h00000002, "SUB");
            check_reg(5, 32'h00000001, "AND");
            check_reg(6, 32'h00000007, "OR");
            check_reg(7, 32'h00000006, "XOR");
            check_reg(8, 32'hFFFFFFFF, "ADDI -1");
            check_reg(9, 32'h00000004, "ADD overflow");
        end
    endtask

    // Test 2: Shifts
    task test_shifts;
        begin
            $display("\n--- Test 2: Shifts ---");
            rst = 1;
            clear_mem;
            `IMEM[0] = 32'h00100093; // ADDI x1, x0, 1
            `IMEM[1] = 32'h00409113; // SLLI x2, x1, 4
            `IMEM[2] = 32'h00215193; // SRLI x3, x2, 2
            `IMEM[3] = 32'hff800213; // ADDI x4, x0, -8
            `IMEM[4] = 32'h40225293; // SRAI x5, x4, 2
            `IMEM[5] = 32'h00225313; // SRLI x6, x4, 2
            release_reset;
            run_cycles(12);
            check_reg(1, 32'h00000001, "ADDI base");
            check_reg(2, 32'h00000010, "SLLI x4");
            check_reg(3, 32'h00000004, "SRLI x2");
            check_reg(4, 32'hFFFFFFF8, "ADDI -8");
            check_reg(5, 32'hFFFFFFFE, "SRAI sign");
            check_reg(6, 32'h3FFFFFFE, "SRLI zero");
        end
    endtask

    // Test 3: Loads & Stores
    task test_loads_stores;
        begin
            $display("\n--- Test 3: Loads & Stores ---");
            rst = 1;
            clear_mem;
            `IMEM[0]  = 32'h0ab00093; // ADDI x1, x0, 0xAB
            `IMEM[1]  = 32'h00102023; // SW   x1, 0(x0)
            `IMEM[2]  = 32'h00002103; // LW   x2, 0(x0)
            `IMEM[3]  = 32'h00100223; // SB   x1, 4(x0)
            `IMEM[4]  = 32'h00400183; // LB   x3, 4(x0)
            `IMEM[5]  = 32'h00404203; // LBU  x4, 4(x0)
            `IMEM[6]  = 32'h1ff00293; // ADDI x5, x0, 0x1FF
            `IMEM[7]  = 32'h00501423; // SH   x5, 8(x0)
            `IMEM[8]  = 32'h00801303; // LH   x6, 8(x0)
            `IMEM[9]  = 32'hfff00293; // ADDI x5, x0, -1
            `IMEM[10] = 32'h00501623; // SH   x5, 12(x0)
            `IMEM[11] = 32'h00c05383; // LHU  x7, 12(x0)
            `IMEM[12] = 32'h00c01403; // LH   x8, 12(x0)
            release_reset;
            run_cycles(19);
            check_reg(2, 32'h000000AB, "LW");
            check_reg(3, 32'hFFFFFFAB, "LB sign-ext");
            check_reg(4, 32'h000000AB, "LBU zero-ext");
            check_reg(6, 32'h000001FF, "LH positive");
            check_reg(7, 32'h0000FFFF, "LHU zero-ext");
            check_reg(8, 32'hFFFFFFFF, "LH sign-ext");
            check_mem_word(12'h000, 32'h000000AB, "SW roundtrip");
        end
    endtask

    // Test 4: Comparisons
    task test_comparisons;
        begin
            $display("\n--- Test 4: Comparisons ---");
            rst = 1;
            clear_mem;
            `IMEM[0] = 32'h00500093; // ADDI x1, x0, 5
            `IMEM[1] = 32'h00300113; // ADDI x2, x0, 3
            `IMEM[2] = 32'hfff00193; // ADDI x3, x0, -1
            `IMEM[3] = 32'h0011a233; // SLT  x4, x2, x1
            `IMEM[4] = 32'h0020a2b3; // SLT  x5, x1, x2
            `IMEM[5] = 32'h0011a333; // SLT  x6, x3, x1
            `IMEM[6] = 32'h0011b3b3; // SLTU x7, x3, x1
            `IMEM[7] = 32'h00602413; // SLTI x8, x1, 6
            `IMEM[8] = 32'h0011b493; // SLTIU x9, x3, 1
            release_reset;
            run_cycles(15);
            check_reg(4, 32'h00000001, "SLT true");
            check_reg(5, 32'h00000000, "SLT false");
            check_reg(6, 32'h00000001, "SLT neg<pos");
            check_reg(7, 32'h00000000, "SLTU wrap");
            check_reg(8, 32'h00000001, "SLTI");
            check_reg(9, 32'h00000000, "SLTIU wrap");
        end
    endtask

    // Test 5: Branches
    // Test 5: conditional branches, taken and not-taken.
    //
    // Every branch here is followed immediately by a marker instruction that
    // loads 99 into a register used by nothing else:
    //     branch  +8
    //     ADDI xP, x0, 99     <- runs only if the branch was NOT taken
    //     next instruction
    // so xP == 0 proves taken and xP == 99 proves not-taken.
    //
    // Earlier versions of this test put the not-taken instruction and the taken
    // destination next to each other and had both write the same register, so
    // they loaded the same value whichever way the branch went and the checks
    // passed no matter what the branch unit did. That is how BLT and BLTU were
    // able to be the same hardware and still report PASS.
    task test_branches;
        begin
            $display("\n--- Test 5: Branches ---");
            rst = 1;
            clear_mem;
            `IMEM[0]  = 32'h00100093; // ADDI x1, x0, 1
            `IMEM[1]  = 32'hfff00113; // ADDI x2, x0, -1
            `IMEM[2]  = 32'h00200193; // ADDI x3, x0, 2
            `IMEM[3]  = 32'h00208463; // BEQ  x1, x2, +8   1 == 2? no  -> NOT taken
            `IMEM[4]  = 32'h06300213; // ADDI x4, x0, 99   marker
            `IMEM[5]  = 32'h00209463; // BNE  x1, x2, +8   1 != 2? yes -> TAKEN
            `IMEM[6]  = 32'h06300293; // ADDI x5, x0, 99   marker
            `IMEM[7]  = 32'h00114463; // BLT  x2, x1, +8   SIGNED   -1 <  1 -> TAKEN
            `IMEM[8]  = 32'h06300313; // ADDI x6, x0, 99   marker
            `IMEM[9]  = 32'h00116463; // BLTU x2, x1, +8   UNSIGNED FFFFFFFF < 1 -> NOT taken
            `IMEM[10] = 32'h06300393; // ADDI x7, x0, 99   marker
            release_reset;
            run_cycles(24);
            check_reg(4, 32'h00000063, "BEQ not taken");
            check_reg(5, 32'h00000000, "BNE taken");
            check_reg(6, 32'h00000000, "BLT signed taken");
            check_reg(7, 32'h00000063, "BLTU unsigned not taken");
        end
    endtask

    // Test 6: JAL & JALR
    task test_jumps;
        begin
            $display("\n--- Test 6: JAL & JALR ---");
            rst = 1;
            clear_mem;
            `IMEM[0] = 32'h00c000ef; // JAL  x1, +12      PC=0x00 → 0x0C, x1=0x04
            `IMEM[1] = 32'h06300113; // ADDI x2, x0, 99   PC=0x04 (skipped by JAL)
            `IMEM[2] = 32'h06300113; // ADDI x2, x0, 99   PC=0x08 (skipped by JAL)
            `IMEM[3] = 32'h02a00113; // ADDI x2, x0, 42   PC=0x0C
            `IMEM[4] = 32'h000081e7; // JALR x3, x1, 0    PC=0x10 → x1+0=0x04, x3=0x14
            `IMEM[5] = 32'h00000013; // NOP               PC=0x14 (JALR link, never reached)
            release_reset;
            run_cycles(11);
            check_reg(1, 32'h00000004, "JAL link");
            check_reg(2, 32'h0000002A, "JAL skip");
            check_reg(3, 32'h00000014, "JALR link");
        end
    endtask

    // Test 7: LUI & AUIPC
    task test_upper_imm;
        begin
            $display("\n--- Test 7: LUI & AUIPC ---");
            rst = 1;
            clear_mem;
            `IMEM[0] = 32'habcde0b7; // LUI   x1, 0xABCDE
            `IMEM[1] = 32'h00001117; // AUIPC x2, 0x00001
            release_reset;
            run_cycles(8);
            check_reg(1, 32'hABCDE000, "LUI");
            check_reg(2, 32'h00001004, "AUIPC");
        end
    endtask

    // Test 8: x0 hardwired zero
    task test_x0;
        begin
            $display("\n--- Test 8: x0 hardwired zero ---");
            rst = 1;
            clear_mem;
            `IMEM[0] = 32'h06300013; // ADDI x0, x0, 99
            `IMEM[1] = 32'h00100093; // ADDI x1, x0, 1
            release_reset;
            run_cycles(8);
            check_reg(0, 32'h00000000, "x0 write ignored");
            check_reg(1, 32'h00000001, "x0 reads zero");
        end
    endtask

    // Test 9: BGE & BGEU
    // Test 9: BGE / BGEU, including the cases where the signed and unsigned
    // verdicts disagree. Same marker scheme as test_branches: probe register 0
    // means taken, 99 means not taken.
    task test_bge;
        begin
            $display("\n--- Test 9: BGE & BGEU ---");
            rst = 1;
            clear_mem;
            `IMEM[0]  = 32'h00500093; // ADDI x1, x0, 5
            `IMEM[1]  = 32'h00500113; // ADDI x2, x0, 5
            `IMEM[2]  = 32'hfff00193; // ADDI x3, x0, -1
            `IMEM[3]  = 32'h0020d463; // BGE  x1, x2, +8   5 >= 5, both agree -> TAKEN
            `IMEM[4]  = 32'h06300213; // ADDI x4, x0, 99   marker
            `IMEM[5]  = 32'h0011d463; // BGE  x3, x1, +8   SIGNED   -1 >= 5 is false -> NOT taken
            `IMEM[6]  = 32'h06300293; // ADDI x5, x0, 99   marker
            `IMEM[7]  = 32'h0011f463; // BGEU x3, x1, +8   UNSIGNED FFFFFFFF >= 5 -> TAKEN
            `IMEM[8]  = 32'h06300313; // ADDI x6, x0, 99   marker
            `IMEM[9]  = 32'h00318463; // BEQ  x3, x3, +8   sanity, equal -> TAKEN
            `IMEM[10] = 32'h06300393; // ADDI x7, x0, 99   marker
            release_reset;
            run_cycles(24);
            check_reg(4, 32'h00000000, "BGE equal taken");
            check_reg(5, 32'h00000063, "BGE signed not taken");
            check_reg(6, 32'h00000000, "BGEU unsigned taken");
            check_reg(7, 32'h00000000, "BEQ equal sanity");
        end
    endtask

    // Test 10: unaligned sub-word accesses - the memory system's contract.
    //
    // The rule both data memories implement (rtl/mem/dmem_w_lanes.v) is that an
    // access is confined to the word containing its address: an access never
    // reaches into the neighbouring word. These checks pin that down, including
    // the cases where the old behavioural model and the sky130 macros disagreed:
    //
    //   * byte accesses are exact at every offset - one byte never straddles,
    //     and an unaligned SB is visible to the aligned LW that covers it
    //   * LHU at offset 3 reads only the word's top byte (0x0011); the old
    //     byte-addressed model reached next door and returned 0x2211
    //   * LH / SH keep the value with the address: SH 0x0344 at offset 3 puts
    //     0x44 in byte 3 and leaves byte 4 at 0x22 (this also caught a
    //     replication bug that wrote 0x03 there instead)
    //   * an unaligned LW/SW is performed on the containing word, so LW at
    //     offset 1 reads all of word 0 and SW at 4095 writes word 1023 whole -
    //     critically, without wrapping around to corrupt byte 0
    //
    // This is a documented deviation from RV32I, which permits straddling
    // accesses: here they are truncated rather than wrapped or trapped, because a
    // single-port SRAM cannot write two words in one cycle. See dmem_w_lanes.v.
    task test_unaligned;
        begin
            $display("\n--- Test 10: Unaligned access contract ---");
            rst = 1;
            clear_mem;
            `IMEM[0]  = 32'h00000093; // ADDI x1, x0, 0      # data base address
            `IMEM[1]  = 32'h0ab00113; // ADDI x2, x0, 0xAB
            `IMEM[2]  = 32'h002080a3; // SB   x2, 1(x1)      # mem[1] = AB
            `IMEM[3]  = 32'h01100113; // ADDI x2, x0, 0x11
            `IMEM[4]  = 32'h002081a3; // SB   x2, 3(x1)      # mem[3] = 11
            `IMEM[5]  = 32'h02200113; // ADDI x2, x0, 0x22
            `IMEM[6]  = 32'h00208223; // SB   x2, 4(x1)      # mem[4] = 22, next word
            `IMEM[7]  = 32'h03300113; // ADDI x2, x0, 0x33
            `IMEM[8]  = 32'h002083a3; // SB   x2, 7(x1)      # mem[7] = 33
            `IMEM[9]  = 32'h0000a183; // LW   x3, 0(x1)      # aligned
            `IMEM[10] = 32'h0030d203; // LHU  x4, 3(x1)      # half in range only
            `IMEM[11] = 32'h0010a283; // LW   x5, 1(x1)      # -> containing word
            `IMEM[12] = 32'h34400113; // ADDI x2, x0, 0x344   # halfword 0x0344
            `IMEM[13] = 32'h002091a3; // SH   x2, 3(x1)      # only byte 3 is in range
            `IMEM[14] = 32'h0040c303; // LBU  x6, 4(x1)      # did SH spill here?
            `IMEM[15] = 32'h7ff00093; // ADDI x1, x0, 2047
            `IMEM[16] = 32'h7fd08093; // ADDI x1, x1, 2045   # x1 = 4092
            `IMEM[17] = 32'hdeadb137; // LUI  x2, 0xDEADB
            `IMEM[18] = 32'h0ef10113; // ADDI x2, x2, 239    # 0xDEADB0EF
            `IMEM[19] = 32'h0020a1a3; // SW   x2, 3(x1)      # address 4095
            release_reset;
            run_cycles(32);
            check_reg(3, 32'h1100ab00, "LW aligned 0");
            check_reg(4, 32'h00000011, "LHU top byte");
            check_reg(5, 32'h1100ab00, "LW unaligned 1");
            check_reg(6, 32'h00000022, "SH no spill");
            check_mem_word(12'h000, 32'h4400ab00, "SH low byte lands");
            check_mem_word(12'hffc, 32'hdeadb0ef, "SW at 4095");
        end
    endtask

    // ── Main ──────────────────────────────────────────────────────
    initial begin
        // NOTE: iverilog aborts the *whole* simulation if the dump file cannot be
        // opened, and still exits 0 - so a missing directory silently turns the
        // testbench into a no-op that looks like a pass. Dump into build/, which
        // the Makefile creates, and allow `make sim NODUMP=1` to skip it.
`ifndef NODUMP
        $dumpfile("build/core_tb.vcd");
        $dumpvars(0, core_tb);
`endif
        clk = 0;
        rst = 1;

        test_arith;
        test_shifts;
        test_loads_stores;
        test_comparisons;
        test_branches;
        test_jumps;
        test_upper_imm;
        test_x0;
        test_bge;
        test_unaligned;

        $display("\n========================================");
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d TEST(S) FAILED", failed);
        $display("========================================\n");
        $finish;
    end

endmodule