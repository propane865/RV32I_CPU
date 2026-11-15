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

    `include "defines.vh"

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

    // Storage depth, from the same defines the models are sized by.
    localparam IMEM_WORDS = `IMEM_WORDS;
    localparam DMEM_BYTES = `DMEM_BYTES;

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


    // =========================================================================
    // Instruction encoders
    //
    // The hazard and forwarding sweeps below vary two instructions and a
    // distance, which is a hundred programs - hand-typed hex would be a hundred
    // chances to test the wrong thing. So the few formats needed are encoded
    // from fields, and check_encoders() pins every one of them against words
    // produced by riscv64-unknown-elf-as -march=rv32im so a mistake in a bit
    // position fails the gate loudly instead of quietly encoding a different
    // instruction.
    // =========================================================================
    localparam [31:0] NOP = 32'h0000_0013;   // addi x0, x0, 0

    function [31:0] enc_r;      // OP:   f7 | rs2 | rs1 | f3 | rd
        input [6:0] f7; input [4:0] rs2, rs1; input [2:0] f3; input [4:0] rd;
        begin enc_r = {f7, rs2, rs1, f3, rd, 7'b0110011}; end
    endfunction

    function [31:0] enc_i;      // OP_IMM: imm | rs1 | f3 | rd
        input [11:0] imm; input [4:0] rs1; input [2:0] f3; input [4:0] rd;
        begin enc_i = {imm, rs1, f3, rd, 7'b0010011}; end
    endfunction

    function [31:0] enc_load;   // LOAD: imm | rs1 | f3 | rd
        input [11:0] imm; input [4:0] rs1; input [2:0] f3; input [4:0] rd;
        begin enc_load = {imm, rs1, f3, rd, 7'b0000011}; end
    endfunction

    function [31:0] enc_s;      // STORE: imm[11:5] | rs2 | rs1 | f3 | imm[4:0]
        input [11:0] imm; input [4:0] rs2, rs1; input [2:0] f3;
        begin enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'b0100011}; end
    endfunction

    function [31:0] enc_b;      // BRANCH: imm[12|10:5] ... imm[4:1|11]
        input [12:0] off; input [4:0] rs2, rs1; input [2:0] f3;
        begin enc_b = {off[12], off[10:5], rs2, rs1, f3, off[4:1], off[11],
                       7'b1100011}; end
    endfunction

    function [31:0] enc_u;      // LUI / AUIPC: imm20 | rd
        input [19:0] imm20; input [4:0] rd; input [6:0] op;
        begin enc_u = {imm20, rd, op}; end
    endfunction

    function [31:0] enc_jal;    // JAL: imm[20|10:1|11|19:12] | rd
        input [20:0] off; input [4:0] rd;
        begin enc_jal = {off[20], off[10:1], off[11], off[19:12], rd, 7'b1101111}; end
    endfunction

    function [31:0] enc_jalr;   // JALR: imm | rs1 | 000 | rd
        input [11:0] imm; input [4:0] rs1, rd;
        begin enc_jalr = {imm, rs1, 3'b000, rd, 7'b1100111}; end
    endfunction

    task enc_ok;
        input [255:0] text;
        input [31:0]  got, expected;
        begin
            if (got !== expected) begin
                $display("FAIL ENCODER %-24s | built 0x%08h | assembler 0x%08h",
                         text, got, expected);
                failed = failed + 1;
            end
        end
    endtask

    // Every encoder, against `riscv64-unknown-elf-as -march=rv32im -mabi=ilp32`.
    task check_encoders;
        begin
            $display("\n--- D0: instruction encoders vs the assembler ---");
            enc_ok("add x5,x3,x4",  enc_r(7'h00, 5'd4, 5'd3, 3'h0, 5'd5), 32'h004182b3);
            enc_ok("addi x5,x3,5",  enc_i(12'd5, 5'd3, 3'h0, 5'd5),       32'h00518293);
            enc_ok("lw x5,0(x2)",   enc_load(12'd0, 5'd2, 3'h2, 5'd5),    32'h00012283);
            enc_ok("lh x5,0(x2)",   enc_load(12'd0, 5'd2, 3'h1, 5'd5),    32'h00011283);
            enc_ok("lbu x5,0(x2)",  enc_load(12'd0, 5'd2, 3'h4, 5'd5),    32'h00014283);
            enc_ok("lui x5,0xb",    enc_u(20'h0000b, 5'd5, 7'b0110111),   32'h0000b2b7);
            enc_ok("auipc x5,0x1",  enc_u(20'h00001, 5'd5, 7'b0010111),   32'h00001297);
            enc_ok("addi x5,x2,8",  enc_i(12'd8, 5'd2, 3'h0, 5'd5),       32'h00810293);
            enc_ok("sw x5,0(x9)",   enc_s(12'd0, 5'd5, 5'd9, 3'h2),       32'h0054a023);
            enc_ok("lw x7,0(x5)",   enc_load(12'd0, 5'd5, 3'h2, 5'd7),    32'h0002a383);
            enc_ok("sw x4,0(x5)",   enc_s(12'd0, 5'd4, 5'd5, 3'h2),       32'h0042a023);
            enc_ok("slt x7,x5,x4",  enc_r(7'h00, 5'd4, 5'd5, 3'h2, 5'd7), 32'h0042a3b3);
            enc_ok("beq x5,x6,+28", enc_b(13'd28, 5'd6, 5'd5, 3'h0),      32'h00628e63);
            enc_ok("jal x5,+24",    enc_jal(21'd24, 5'd5),                 32'h018002ef);
            enc_ok("jalr x5,x8,0",  enc_jalr(12'd0, 5'd8, 5'd5),           32'h00402e7);
            enc_ok("jalr x0,x5,0",  enc_jalr(12'd0, 5'd5, 5'd0),           32'h00028067);
            enc_ok("slli x5,x3,4",  enc_i({7'h00, 5'd4}, 5'd3, 3'h1, 5'd5), 32'h00419293);
            enc_ok("srai x5,x3,2",  enc_i({7'h20, 5'd2}, 5'd3, 3'h5, 5'd5), 32'h4021d293);
            if (failed == 0) $display("PASS encoders                    | all 18 match");
        end
    endtask

    // =========================================================================
    // Producer / consumer distance sweep
    //
    // One program shape, used for every pair:
    //
    //   word 0..3   setup (writes the operand registers, far enough ahead of the
    //               producer that it cannot itself be a pending dependency)
    //   word 4..7   NOP
    //   word 8      producer           (byte address 0x20)
    //   word 9..    `d` NOPs
    //   word 9+d    consumer
    //
    // `d` is the number of instructions between producer and consumer, so d = 0
    // is the immediate dependency and d = 3 is the first distance the forwarding
    // paths are not involved in at all. The producer always writes x5 and the
    // consumer always reads x5 (or uses it as an address / stored value), so one
    // task covers the whole table.
    // =========================================================================
    localparam integer PROD_W = 8;         // producer word index, byte 0x20

    // Data and register constants used by the sweep. Kept in one place so the
    // expected values below are arithmetic, not guesswork.
    localparam [31:0] DATA_ADDR = 32'h0000_0200;   // loads read from here
    localparam [31:0] STORE_ADDR= 32'h0000_0400;   // stores write here
    localparam [31:0] LOAD_VAL  = 32'h0000_ABCD;
    localparam [31:0] PTR_VAL   = STORE_ADDR;      // mem[0x210]: a pointer to store
    localparam [31:0] X3_VAL    = 32'h0000_0100;
    localparam [31:0] X4_VAL    = 32'h0000_0022;
    // Word 20, the first instruction executed after the link-producing jump.
    localparam [31:0] JUMP_TARGET = 32'h0000_0050;

    task poke;
        input [12:0] a;
        input [31:0] v;
        begin
            `DMEM[a    ] = v[7:0];
            `DMEM[a + 1] = v[15:8];
            `DMEM[a + 2] = v[23:16];
            `DMEM[a + 3] = v[31:24];
        end
    endtask

    task check_mem_word13;
        input [12:0]  a;
        input [31:0]  expected;
        input [255:0] name;
        reg [31:0] got;
        begin
            got = {`DMEM[a+3], `DMEM[a+2], `DMEM[a+1], `DMEM[a]};
            if (got !== expected) begin
                $display("FAIL %-24s | mem[0x%04h] = 0x%08h | expected 0x%08h",
                         name, a, got, expected);
                failed = failed + 1;
            end else
                $display("PASS %-24s | mem[0x%04h] = 0x%08h", name, a, got);
        end
    endtask

    // The producer/consumer program. chk_mem < 0 checks a register, otherwise it
    // checks the memory word at that byte address (the store consumers).
    // The sweep's own check tasks, because its case names are a family name plus
    // the distance, and iverilog will not accept that composed as a task argument.
    // Printing the two parts separately also keeps every line the same width,
    // which a byte-exact golden transcript wants.
    task sweep_check_reg;
        input [255:0] base;
        input integer d;
        input [4:0]   rnum;
        input [31:0]  expected;
        begin
            if (read_reg(rnum) !== expected) begin
                $display("FAIL %-14s d%0d | x%-2d = 0x%08h | expected 0x%08h",
                         base, d, rnum, read_reg(rnum), expected);
                failed = failed + 1;
            end else
                $display("PASS %-14s d%0d | x%-2d = 0x%08h",
                         base, d, rnum, read_reg(rnum));
        end
    endtask

    task sweep_check_mem;
        input [255:0] base;
        input integer d;
        input [12:0]  a;
        input [31:0]  expected;
        reg [31:0] got;
        begin
            got = {`DMEM[a+3], `DMEM[a+2], `DMEM[a+1], `DMEM[a]};
            if (got !== expected) begin
                $display("FAIL %-14s d%0d | mem[0x%04h] = 0x%08h | expected 0x%08h",
                         base, d, a, got, expected);
                failed = failed + 1;
            end else
                $display("PASS %-14s d%0d | mem[0x%04h] = 0x%08h",
                         base, d, a, got);
        end
    endtask

    // Load the standard producer/consumer shape into a machine that is in reset,
    // with the data it reads preloaded. Shared by the value sweep and the stall
    // accounting sweep, so the program measured for timing is the same program
    // measured for correctness.
    task load_fw_case;
        input [31:0] prod;
        input integer d;
        input [31:0] cons;
        integer j;
        begin
            // Assert reset before loading the program: without it the core keeps
            // running from wherever the previous case left the PC, and every check
            // below silently reads a register nothing ever wrote.
            rst = 1;
            clear_all;
            // setup: x2 = load base, x3/x4 = ALU operands, x6 = 7,
            //        x8 = JALR target, x9 = store destination
            `IMEM[0] = enc_i(DATA_ADDR[11:0],   5'd0, 3'h0, 5'd2);
            `IMEM[1] = enc_i(X3_VAL[11:0],      5'd0, 3'h0, 5'd3);
            `IMEM[2] = enc_i(X4_VAL[11:0],      5'd0, 3'h0, 5'd4);
            `IMEM[3] = enc_i(12'd7,             5'd0, 3'h0, 5'd6);
            `IMEM[4] = enc_i(STORE_ADDR[11:0],  5'd0, 3'h0, 5'd9);
            `IMEM[5] = enc_i(JUMP_TARGET[11:0], 5'd0, 3'h0, 5'd8);
            for (j = 6; j < PROD_W; j = j + 1) `IMEM[j] = NOP;
            `IMEM[PROD_W]      = prod;
            for (j = 1; j <= d; j = j + 1) `IMEM[PROD_W + j] = NOP;
            `IMEM[PROD_W + d + 1] = cons;
            poke(DATA_ADDR,   LOAD_VAL);
            poke(DATA_ADDR + 4,  32'h0000_1234);
            poke(DATA_ADDR + 16, PTR_VAL);
            poke(STORE_ADDR,  32'h0000_0000);
        end
    endtask

    task fwd_case;
        input [255:0] base;      // case family; the distance is printed with it
        input [31:0]  prod;
        input integer d;
        input [31:0]  cons;
        input integer chk_mem;
        input [4:0]   chk_reg;
        input [31:0]  expected;
        begin
            load_fw_case(prod, d, cons);
            release_reset;
            run_cycles(40);
            if (chk_mem < 0) sweep_check_reg(base, d, chk_reg, expected);
            else             sweep_check_mem(base, d, chk_mem[12:0], expected);
        end
    endtask

    // =========================================================================
    // Stall accounting
    //
    // The value sweeps say a dependent consumer gets the right answer; they cannot
    // say what that cost. The cost is half of the fix's contract, and the reason
    // the fix is a stall rather than a forward: a load's value does not exist
    // before its own writeback cycle, so no forwarding path can shorten the wait to
    // zero. Counting the frozen cycles per case pins the wait (two cycles for an
    // immediately dependent consumer, one for the next slot, none from the third
    // slot over) and pins the other half as well - an instruction that does not
    // read the load's register must stall zero cycles, which is exactly what the
    // decoder's uses_rs1 / uses_rs2 are for.
    // =========================================================================
    integer stall_count = 0;

    always @(posedge clk)
        if (!rst && DUT.DP.stall_pc === 1'b1) stall_count = stall_count + 1;

    task stall_case;
        input [255:0] base;
        input integer d;
        input [31:0]  prod;
        input [31:0]  cons;
        input integer expected;
        begin
            load_fw_case(prod, d, cons);
            stall_count = 0;
            release_reset;
            run_cycles(40);
            if (stall_count !== expected) begin
                $display("FAIL %-14s d%0d | stalls = %0d | expected %0d",
                         base, d, stall_count, expected);
                failed = failed + 1;
            end else
                $display("PASS %-14s d%0d | stalls = %0d", base, d, stall_count);
        end
    endtask

    task test_stall_accounting;
        begin
            $display("\n--- D5: load-use stall cost ---");
            // A load's value appears the cycle after its memory access, so the
            // consumer waits two cycles, then one, then nothing.
            stall_case("lw->alu", 0, enc_load(12'd0, 5'd2, 3'h2, 5'd5),
                       enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), 2);
            stall_case("lw->alu", 1, enc_load(12'd0, 5'd2, 3'h2, 5'd5),
                       enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), 1);
            stall_case("lw->alu", 2, enc_load(12'd0, 5'd2, 3'h2, 5'd5),
                       enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), 0);
            stall_case("lw->alu", 3, enc_load(12'd0, 5'd2, 3'h2, 5'd5),
                       enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), 0);
            // The second operand lane is a dependency too, so it costs the same. An
            // instruction that ignored uses_rs2 would report 0 here and be wrong.
            stall_case("lw->alu rs2", 0, enc_load(12'd0, 5'd2, 3'h2, 5'd5),
                       enc_r(7'h00, 5'd5, 5'd4, 3'h0, 5'd7), 2);
            // A store's data and a second load's address are consumers as well.
            stall_case("lw->sw data", 0, enc_load(12'd0, 5'd2, 3'h2, 5'd5),
                       enc_s(12'd0, 5'd5, 5'd9, 3'h2), 2);
            stall_case("lw->lw addr", 0, enc_load(12'd0, 5'd2, 3'h2, 5'd5),
                       enc_load(12'd0, 5'd5, 3'h2, 5'd7), 2);
            // An ALU producer costs nothing: its value exists a stage earlier,
            // which is the whole difference between the two kinds of producer.
            stall_case("alu->alu", 0, enc_r(7'h00, 5'd4, 5'd3, 3'h0, 5'd5),
                       enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), 0);
            // False hazards: a load whose rd matches a *field* of the younger
            // instruction that does not read that operand. The ADDI's rs2 field is
            // part of its immediate (4), the LUI's rs1 field is part of its
            // immediate (8); neither instruction reads either register. Both used
            // to cost a bubble.
            stall_case("lw vs addi imm", 0, enc_load(12'd0, 5'd2, 3'h2, 5'd4),
                       enc_i(12'd4, 5'd0, 3'h0, 5'd7), 0);
            // 0x40, because an LUI's rs1 field is imm20[7:3]: 0x40 >> 3 == 8, which
            // is the register the load writes. An immediate of 0x400 would have put
            // x0 there, and x0 is excluded, so the case would have passed for the
            // wrong reason.
            stall_case("lw vs lui imm",  0, enc_load(12'd0, 5'd2, 3'h2, 5'd8),
                       enc_u(20'h00040, 5'd7, 7'b0110111), 0);
            // x0 is never a dependency, whatever a pending write claims about it.
            stall_case("lw x0", 0, enc_load(12'd0, 5'd2, 3'h2, 5'd0),
                       enc_r(7'h00, 5'd4, 5'd0, 3'h0, 5'd7), 0);
        end
    endtask


    // Producers, all writing x5. `val` is what x5 must hold afterwards, and is
    // the arithmetic the expected values below are built from.
    //
    //   name      instruction                x5
    //   alu_r     add  x5, x3, x4            0x122
    //   alu_i     addi x5, x3, 5             0x105
    //   lw        lw   x5, 0(x2)             0xABCD   (the memory value)
    //   lh        lh   x5, 0(x2)             0xABCD   (two bytes, sign-extended)
    //   lbu       lbu  x5, 0(x2)             0xCD     (one byte, zero-extended)
    //   lui       lui  x5, 0xb               0x0000B000
    //   auipc     auipc x5, 0x1              0x1020   (producer PC 0x20 + 0x1000)
    //   neg       addi x5, x0, -1            0xFFFFFFFF
    localparam [31:0] V_ALU_R = X3_VAL + X4_VAL;      // 0x0000_0122
    localparam [31:0] V_ALU_I = X3_VAL + 32'd5;       // 0x0000_0105
    localparam [31:0] V_LUI   = 32'h0000_B000;
    localparam [31:0] V_AUIPC = 32'h0000_1020;        // 0x20 + 0x1000
    localparam [31:0] V_NEG   = 32'hFFFF_FFFF;

    // Consumer expected values, per producer, for `add x7, x5, x4`.
    //
    // Distances: 0 = consumer immediately after the producer, 3 = the first
    // distance at which nothing is in flight any more.
    task test_forwarding_sweep;
        integer d;
        begin
            for (d = 0; d <= 3; d = d + 1) begin
                // --- ALU results into an ALU operand -------------------------
                fwd_case("alu_r rs1",
                         enc_r(7'h00, 5'd4, 5'd3, 3'h0, 5'd5), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), -1, 5'd7,
                         V_ALU_R + X4_VAL);
                fwd_case("alu_r rs2",
                         enc_r(7'h00, 5'd4, 5'd3, 3'h0, 5'd5), d,
                         enc_r(7'h00, 5'd5, 5'd4, 3'h0, 5'd7), -1, 5'd7,
                         V_ALU_R + X4_VAL);
                fwd_case("alu_i rs1",
                         enc_i(12'd5, 5'd3, 3'h0, 5'd5), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), -1, 5'd7,
                         V_ALU_I + X4_VAL);

                // --- the load result, at every width, into an operand --------
                fwd_case("lw rs1",
                         enc_load(12'd0, 5'd2, 3'h2, 5'd5), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), -1, 5'd7,
                         LOAD_VAL + X4_VAL);
                fwd_case("lw rs2",
                         enc_load(12'd0, 5'd2, 3'h2, 5'd5), d,
                         enc_r(7'h00, 5'd5, 5'd4, 3'h0, 5'd7), -1, 5'd7,
                         LOAD_VAL + X4_VAL);
                // lh sign-extends, and 0xABCD has bit 15 set, so the value the
                // consumer must see is 0xFFFFABCD - the width is not the whole
                // story, the extension is the part a load path gets wrong.
                fwd_case("lh rs1",
                         enc_load(12'd0, 5'd2, 3'h1, 5'd5), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), -1, 5'd7,
                         32'hffff_abcd + X4_VAL);
                fwd_case("lbu rs1",
                         enc_load(12'd0, 5'd2, 3'h4, 5'd5), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), -1, 5'd7,
                         32'h0000_00CD + X4_VAL);

                // --- upper-immediate producers -------------------------------
                fwd_case("lui rs1",
                         enc_u(20'h0000b, 5'd5, 7'b0110111), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), -1, 5'd7,
                         V_LUI + X4_VAL);
                fwd_case("auipc rs1",
                         enc_u(20'h00001, 5'd5, 7'b0010111), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7), -1, 5'd7,
                         V_AUIPC + X4_VAL);

                // --- load result into a store's data -------------------------
                fwd_case("lw st-data",
                         enc_load(12'd0, 5'd2, 3'h2, 5'd5), d,
                         enc_s(12'd0, 5'd5, 5'd9, 3'h2), STORE_ADDR, 5'd0,
                         LOAD_VAL);

                // --- load result used as a signed comparison operand ---------
                // A wrong operand does not just compute the wrong sum here, it
                // flips the predicate, so this pins the comparator's inputs too.
                fwd_case("neg slt",
                         enc_i(12'hfff, 5'd0, 3'h0, 5'd5), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h2, 5'd7), -1, 5'd7,
                         32'h1);
                fwd_case("lw slt",
                         enc_load(12'd0, 5'd2, 3'h2, 5'd5), d,
                         enc_r(7'h00, 5'd4, 5'd5, 3'h2, 5'd7), -1, 5'd7,
                         32'h0);
            end
        end
    endtask

    // A produced value used as an *address*, which is a different operand path
    // from an ALU source: it goes to the ALU as the base of a load or a store,
    // and an unforwarded copy would read or write the wrong place rather than
    // compute a wrong value - a failure mode the register checks cannot see.
    //
    // Producer x5 = DATA_ADDR via the ALU, or via a load of a pointer held in
    // memory (mem[0x210] = 0x400). Consumers read/write through x5.
    task test_address_operand_sweep;
        integer d;
        begin
            for (d = 0; d <= 3; d = d + 1) begin
                fwd_case("ptr-alu ld",
                         enc_i(12'd0, 5'd2, 3'h0, 5'd5), d,
                         enc_load(12'd0, 5'd5, 3'h2, 5'd7), -1, 5'd7,
                         LOAD_VAL);
                fwd_case("ptr-lw st",
                         enc_load(12'd16, 5'd2, 3'h2, 5'd5), d,   // x5 = mem[0x210]
                         enc_s(12'd0, 5'd4, 5'd5, 3'h2), STORE_ADDR, 5'd0,
                         X4_VAL);                                  // sw x4, 0(x5)
                fwd_case("ptr-alu st",
                         enc_i(12'd0, 5'd9, 3'h0, 5'd5), d,   // x5 = x9 = 0x400
                         enc_s(12'd0, 5'd4, 5'd5, 3'h2), STORE_ADDR, 5'd0,
                         X4_VAL);
                fwd_case("ptr-lw st-data",
                         enc_load(12'd16, 5'd2, 3'h2, 5'd5), d,
                         enc_s(12'd0, 5'd5, 5'd9, 3'h2), STORE_ADDR, 5'd0,
                         PTR_VAL);
            end
        end
    endtask


    // A jump's link value, consumed at increasing distance from the jump.
    //
    // JAL/JALR are the only instructions that write PC+4, so they are the only
    // producers whose write-back value is not the ALU result. Their link value
    // reaches a consumer through a different forwarding path than an ALU result
    // would, and a forwarding mux that only knows about the ALU result would hand
    // the consumer the jump's *target* instead of its return address.
    //
    // One program covers the whole distance range: the jump goes forward, and
    // consumers sit 1, 2, 3 and 4 executed instructions past it, each writing its
    // own register. Note the distance is counted in executed instructions: a taken
    // jump flushes the fetch behind it, so the instruction at the target is always
    // one place behind the jump in the pipeline no matter how far it was jumped to.
    //
    // The link value is the producer's PC + 4 = 0x24, so every consumer leaves
    // 0x24 + x4 = 0x46.
    task test_link_value_sweep;
        integer T;                 // target word index
        begin
            rst = 1;
            clear_all;
            `IMEM[0] = enc_i(DATA_ADDR[11:0],  5'd0, 3'h0, 5'd2);
            `IMEM[1] = enc_i(X3_VAL[11:0],     5'd0, 3'h0, 5'd3);
            `IMEM[2] = enc_i(X4_VAL[11:0],     5'd0, 3'h0, 5'd4);
            `IMEM[3] = enc_i(JUMP_TARGET[11:0],5'd0, 3'h0, 5'd8);
            T   = JUMP_TARGET[11:2];
            `IMEM[PROD_W] = enc_jal(JUMP_TARGET - PROD_W * 4, 5'd5);
            `IMEM[T]      = enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7);   // distance 1
            `IMEM[T + 1]  = enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd10);  // distance 2
            `IMEM[T + 2]  = enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd11);  // distance 3
            `IMEM[T + 3]  = enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd12);  // distance 4
            release_reset;
            run_cycles(80);
            check_reg(5'd5,  32'h0000_0024, "jal link value");
            check_reg(5'd7,  32'h0000_0046, "jal link d1");
            check_reg(5'd10, 32'h0000_0046, "jal link d2");
            check_reg(5'd11, 32'h0000_0046, "jal link d3");
            check_reg(5'd12, 32'h0000_0046, "jal link d4");

            rst = 1;
            clear_all;
            `IMEM[0] = enc_i(DATA_ADDR[11:0],  5'd0, 3'h0, 5'd2);
            `IMEM[1] = enc_i(X3_VAL[11:0],     5'd0, 3'h0, 5'd3);
            `IMEM[2] = enc_i(X4_VAL[11:0],     5'd0, 3'h0, 5'd4);
            `IMEM[3] = enc_i(JUMP_TARGET[11:0],5'd0, 3'h0, 5'd8);
            `IMEM[PROD_W] = enc_jalr(12'd0, 5'd8, 5'd5);   // x5 = PC+4, x8 = target
            `IMEM[T]      = enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd7);
            `IMEM[T + 1]  = enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd10);
            `IMEM[T + 2]  = enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd11);
            `IMEM[T + 3]  = enc_r(7'h00, 5'd4, 5'd5, 3'h0, 5'd12);
            release_reset;
            run_cycles(80);
            check_reg(5'd5,  32'h0000_0024, "jalr link value");
            check_reg(5'd7,  32'h0000_0046, "jalr link d1");
            check_reg(5'd10, 32'h0000_0046, "jalr link d2");
            check_reg(5'd11, 32'h0000_0046, "jalr link d3");
            check_reg(5'd12, 32'h0000_0046, "jalr link d4");
        end
    endtask

    initial begin
`ifndef NODUMP
        $dumpfile("build/directed_tb.vcd");
        $dumpvars(0, directed_tb);
`endif
        clk = 0;
        rst = 1;

        check_encoders;
        test_redirect_load_use_beq;
        test_redirect_load_use_bne;
        test_redirect_load_use_jal;
        test_redirect_load_use_jalr;
        test_forwarding_sweep;
        test_address_operand_sweep;
        test_link_value_sweep;
        test_stall_accounting;

        $display("\n========================================");
        if (failed == 0)
            $display("ALL DIRECTED TESTS PASSED");
        else
            $display("%0d DIRECTED TEST(S) FAILED", failed);
        $display("========================================\n");
        $finish;
    end

endmodule
