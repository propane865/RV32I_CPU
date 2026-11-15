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

    // ... and the same with funct3 exposed, to build the JALR encodings that are
    // not JALR.
    function [31:0] enc_jalr_f3;
        input [11:0] imm; input [4:0] rs1, rd; input [2:0] f3;
        begin enc_jalr_f3 = {imm, rs1, f3, rd, 7'b1100111}; end
    endfunction

    // Replace an encoding's opcode field. Half of the illegal encodings this suite
    // needs are legal fields under an opcode the core does not implement (SYSTEM's
    // CSR forms, and opcodes borrowed from extensions), which no format-specific
    // encoder above can express. Written as a function rather than a concatenation
    // for the same reason as the rest of them: getting S-type and I-type field
    // positions wrong by hand is how an earlier version of this suite encoded
    // `sw x0, 10(x4)` while meaning `sw x4, 0(x9)`, and the core faithfully stored
    // to x4 + 10 and looked broken.
    function [31:0] with_op;
        input [31:0] instr; input [6:0] op;
        begin with_op = {instr[31:7], op}; end
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
            enc_ok("jalr f3=0",     enc_jalr_f3(12'd0, 5'd5, 5'd0, 3'h0),  32'h00028067);
            enc_ok("sw x4,0(x9)",   enc_s(12'd0, 5'd4, 5'd9, 3'h2),        32'h0044a023);
            enc_ok("with_op csrrs", with_op(enc_i(12'h340, 5'd0, 3'h2, 5'd10),
                                            `RV_OP_SYSTEM), 32'h34002573);
            enc_ok("fence",         with_op(enc_i(12'h0ff, 5'd0, 3'h0, 5'd0),
                                            `RV_OP_FENCE), 32'h0ff0000f);
            enc_ok("slli x5,x3,4",  enc_i({7'h00, 5'd4}, 5'd3, 3'h1, 5'd5), 32'h00419293);
            enc_ok("srai x5,x3,2",  enc_i({7'h20, 5'd2}, 5'd3, 3'h5, 5'd5), 32'h4021d293);
            // Negative displacements, pinned separately because a sign bit is the one
            // thing an encoder can get wrong without changing any positive case. The
            // assembler had to be shown these as backward branches to a label - an
            // absolute "-8" it turns into a relocation and leaves the word incomplete.
            enc_ok("beq x5,x0,-8",  enc_b(13'h1ff8, 5'd0, 5'd5, 3'h0), 32'hfe028ce3);
            enc_ok("bne x5,x0,-8",  enc_b(13'h1ff8, 5'd0, 5'd5, 3'h1), 32'hfe029ce3);
            enc_ok("blt x6,x3,-8",  enc_b(13'h1ff8, 5'd3, 5'd6, 3'h4), 32'hfe334ce3);
            enc_ok("jal x10,-8",    enc_jal(21'h1ffff8, 5'd10),        32'hff9ff56f);
            if (failed == 0) $display("PASS encoders                    | all 22 match");
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


    // =========================================================================
    // Strict decode: encodings that must have no architectural effect
    //
    // The suspect instruction is always word 8 and always aims at x10, followed by
    // a fall-through marker in x11 and a jump marker in x12 at the address a
    // redirected or link-writing instruction would reach:
    //
    //   word 0..5   setup: x2 = 0x200 (load/store base), x3 = 0x100, x4 = 0x22,
    //               x8 = 0x50, x9 = 0x400 (store base); mem[0x200] = 0xABCD,
    //               mem[0x400] = 0
    //   word 8      the encoding under test
    //   word 9      addi x11, x0, 5      - runs iff execution fell through
    //   word 20     addi x12, x0, 99     - runs iff something redirected to 0x50
    //
    // Every case therefore checks all four things an encoding can do wrong: write a
    // register, write memory, redirect, and (by the fall-through marker) vanish.
    //
    // The first two cases are the positive control: legal encodings aimed at the
    // same x10 and the same mem[0x400], which MUST take effect. Without them every
    // "nothing happened" check below would also pass on a program that never ran -
    // which is not hypothetical, an earlier version of this testbench forgot to
    // re-assert reset between cases and reported a bench full of clean results.
    // =========================================================================
    localparam integer ILLEGAL_W = 8;

    // Sentinel for "this encoding must not raise anything". The cause codes are the
    // architectural ones and occupy 0..11, so 15 is free and, unlike a 0 or 1, it
    // cannot be mistaken for a cause that happened to be reported.
    localparam [`TRAP_CAUSE_W-1:0] NO_TRAP = {`TRAP_CAUSE_W{1'b1}};

    // The one program shape every encoding case uses.
    //
    //   word 0..6  setup: x2 = 0x200 (load/store base), x3 = 0x100, x4 = 0x22,
    //              x6 = -1, x7 = 2 (a shift amount), x8 = 0x50, x9 = 0x400 (store
    //              base); x5 and x10 are left at 0; mem[0x200] = 0xABCD,
    //              mem[0x400] = 0
    //   word 7     lw x14, 0(x2)     - older than the encoding under test
    //   word 8     the encoding under test, always writing x10 if it writes anything
    //   word 9     addi x11, x0, 5   - runs iff execution fell through
    //   word 10    jal x0, +44       - steps over the redirect marker below
    //   word 20    addi x12, x0, 99  - runs iff something transferred to 0x50
    //
    // Six things are then checked, and each one rules out a different way an
    // exception path can be wrong:
    //
    //   x10  nothing was written by an instruction that must not have written
    //   x11  nothing YOUNGER ran - the flush behind an exception is what makes it
    //        precise, and a core that reports the exception and then keeps going is
    //        the failure mode this catches
    //   x12  nothing transferred control to the address the exception is about
    //   mem  no store reached memory
    //   x14  an OLDER instruction still retired - the other half of precise, and
    //        invisible to every other check here
    //   cause, trap_pc  what is reported, and about which instruction
    //
    // The jump marker needs the skip above it: without the `jal`, execution walks
    // into word 20 on its own and "the redirect marker ran" stops meaning anything.
    task enc_case;
        input [255:0] base;
        input [31:0]  instr;
        input [31:0]  exp_x10;
        input [31:0]  exp_x11;
        input [31:0]  exp_x12;
        input [31:0]  exp_mem400;
        input [`TRAP_CAUSE_W-1:0] exp_cause;
        integer j;
        reg trapped;
        reg wanted;
        begin
            rst = 1;
            clear_all;
            `IMEM[0] = enc_i(DATA_ADDR[11:0],   5'd0, 3'h0, 5'd2);
            `IMEM[1] = enc_i(X3_VAL[11:0],      5'd0, 3'h0, 5'd3);
            `IMEM[2] = enc_i(X4_VAL[11:0],      5'd0, 3'h0, 5'd4);
            `IMEM[3] = enc_i(JUMP_TARGET[11:0], 5'd0, 3'h0, 5'd8);
            `IMEM[4] = enc_i(STORE_ADDR[11:0],  5'd0, 3'h0, 5'd9);
            `IMEM[5] = enc_i(12'd2,             5'd0, 3'h0, 5'd7);
            // x6 = -1. Signed and unsigned forms of SLT, SLTI, BLT and BGE agree on
            // every operand pair except one where a sign matters, so the sweep needs
            // a register whose interpretation differs: as a signed number this is the
            // smallest of them, as an unsigned number the largest.
            `IMEM[6] = enc_i(12'hfff,            5'd0, 3'h0, 5'd6);
            // An older load, deliberately one slot ahead: it is in the memory stage
            // when the exception below is detected, so it must still retire.
            `IMEM[ILLEGAL_W-1] = enc_load(12'd0, 5'd2, 3'h2, 5'd14);
            `IMEM[ILLEGAL_W]   = instr;
            `IMEM[ILLEGAL_W+1] = enc_i(12'd5, 5'd0, 3'h0, 5'd11);
            `IMEM[ILLEGAL_W+2] = enc_jal(21'd44, 5'd0);
            `IMEM[JUMP_TARGET[11:2]] = enc_i(12'd99, 5'd0, 3'h0, 5'd12);
            poke(DATA_ADDR,  LOAD_VAL);
            poke(STORE_ADDR, 32'h0000_0000);
            release_reset;
            run_cycles(60);
            trapped = (DUT.trap === 1'b1);
            // Parenthesised because `!=` and `!==` are the same precedence and chain
            // left to right: without these, the expression above reads as
            // "(trapped != exp_cause) !== NO_TRAP", which happens to be non-zero for
            // most inputs and quietly turns the whole check into a no-op.
            wanted  = (exp_cause !== NO_TRAP);
            if (trapped !== wanted) begin
                $display("FAIL %-14s | trap = %0b cause = %0d | expected trap = %0b cause = %0d",
                         base, trapped, DUT.trap_cause, exp_cause !== NO_TRAP, exp_cause);
                failed = failed + 1;
            end else if (trapped && (DUT.trap_cause !== exp_cause)) begin
                $display("FAIL %-14s | cause = %0d | expected %0d",
                         base, DUT.trap_cause, exp_cause);
                failed = failed + 1;
            end else if (trapped && (DUT.trap_pc !== ILLEGAL_W * 4)) begin
                // The report must name the instruction that trapped. PC+4, or the
                // target it was denied, or the fetch's own ahead-of-itself address
                // would all be plausible numbers here and all wrong.
                $display("FAIL %-14s | trap_pc = 0x%08h | expected 0x%08h",
                         base, DUT.trap_pc, ILLEGAL_W * 4);
                failed = failed + 1;
            end else
                $display("PASS %-14s | trap = %0b cause = %0d pc = 0x%08h",
                         base, trapped, DUT.trap_cause, DUT.trap_pc);
            check_reg(5'd10, exp_x10, "  rd untouched");
            check_reg(5'd11, exp_x11, "  fall-through");
            check_reg(5'd12, exp_x12, "  redirect target");
            check_reg(5'd14, LOAD_VAL, "  older load retired");
            check_mem_word13(STORE_ADDR[12:0], exp_mem400, "  mem[0x400]");
        end
    endtask

    // =========================================================================
    // D6: encodings that are not instructions, and the exception they report
    //
    // Every reject expects cause 2 (illegal instruction) at the encoding's own
    // address, with nothing written, nothing younger executed and the older load
    // still retired. Every accept expects exactly the opposite: no exception at
    // all, and its value.
    //
    // There are deliberately more acceptances than a bug-hunter would think is
    // necessary. A legality rule tested only on its negatives proves nothing, and
    // an over-eager decoder - rejecting SUB because it saw funct7 = 0x20, or ADDI
    // because its immediate happened to have bit 5 set - is as wrong as accepting
    // funct7 = 0x21, and much harder to notice, because the program it breaks is a
    // legal one.
    // =========================================================================
    task test_strict_decode;
        begin
            $display("\n--- D6: encodings the decode must reject ---");
            // ---- positive controls, aimed at the same x10 and the same mem[0x400]
            // ---- the rejects below check. "Nothing happened" is also what a
            // ---- program that never ran reports.
            enc_case("legal add",  enc_r(7'h00, 5'd4, 5'd3, 3'h0, 5'd10),
                     V_ALU_R, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal sw",   enc_s(12'h000, 5'd4, 5'd9, 3'h2),
                     32'h0, 32'h5, 32'h0, X4_VAL, NO_TRAP);

            // ---- R-type: two funct7 values, and 0x20 belongs to two funct3 ------
            // ADD with funct7 = 0x21: neither ADD nor SUB. Before the strict decode
            // it executed as SUB, because only bit 5 was read - which is why the
            // controls above use non-zero operands.
            enc_case("op f7=0x21", enc_r(7'h21, 5'd4, 5'd3, 3'h0, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("legal sub",  enc_r(7'h20, 5'd4, 5'd3, 3'h0, 5'd10),
                     X3_VAL - X4_VAL, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal sra",  enc_r(7'h20, 5'd7, 5'd3, 3'h5, 5'd10),
                     32'h0000_0040, 32'h5, 32'h0, 32'h0, NO_TRAP);  // x3 >> x7
            // SLL has no alternate form, so funct7 = 0x20 here is not an instruction.
            enc_case("op sll f7=20", enc_r(7'h20, 5'd7, 5'd3, 3'h1, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);

            // ---- I-type shifts: only here are the top seven bits a sub-opcode ----
            enc_case("slli f7=01", enc_i({7'h01, 5'd4}, 5'd3, 3'h1, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("srli f7=01", enc_i({7'h01, 5'd2}, 5'd3, 3'h5, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            // The same seven bits on ADDI are immediate data. One bit's edit away
            // from the two rejects above, and legal.
            enc_case("legal addi hi", enc_i({7'h01, 5'd4}, 5'd3, 3'h0, 5'd10),
                     X3_VAL + 32'h24, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal slli", enc_i({7'h00, 5'd2}, 5'd3, 3'h1, 5'd10),
                     32'h0000_0400, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal srli", enc_i({7'h00, 5'd2}, 5'd3, 3'h5, 5'd10),
                     32'h0000_0040, 32'h5, 32'h0, 32'h0, NO_TRAP);

            // ---- memory widths: three of eight funct3 values are not loads, five
            // ---- are not stores.
            enc_case("load f3=3",  enc_load(12'h000, 5'd2, 3'h3, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("load f3=6",  enc_load(12'h000, 5'd2, 3'h6, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("load f3=7",  enc_load(12'h000, 5'd2, 3'h7, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("store f3=3", enc_s(12'h000, 5'd4, 5'd9, 3'h3),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("store f3=4", enc_s(12'h000, 5'd4, 5'd9, 3'h4),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("store f3=7", enc_s(12'h000, 5'd4, 5'd9, 3'h7),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            // All five loads and all three stores, so the width decode is checked as
            // a set. It is a slice of funct3, and a constant naming the wrong slot
            // shows up here as a wrong value rather than as a missing case.
            enc_case("legal lb",   enc_load(12'h000, 5'd2, 3'h0, 5'd10),
                     32'hffff_ffcd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal lh",   enc_load(12'h000, 5'd2, 3'h1, 5'd10),
                     32'hffff_abcd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal lw",   enc_load(12'h000, 5'd2, 3'h2, 5'd10),
                     LOAD_VAL, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal lbu",  enc_load(12'h000, 5'd2, 3'h4, 5'd10),
                     32'h0000_00cd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal lhu",  enc_load(12'h000, 5'd2, 3'h5, 5'd10),
                     32'h0000_abcd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("legal sb",   enc_s(12'h000, 5'd4, 5'd9, 3'h0),
                     32'h0, 32'h5, 32'h0, 32'h0000_0022, NO_TRAP);
            enc_case("legal sh",   enc_s(12'h000, 5'd4, 5'd9, 3'h1),
                     32'h0, 32'h5, 32'h0, 32'h0000_0022, NO_TRAP);

            // ---- branch funct3 holes -------------------------------------------
            // funct3 2 and 3 are not branches. Before the exception path existed
            // these two could not be told apart at all - the branch unit's own
            // default for an unknown condition is also "not taken", so execution
            // fell through either way. The exception is what distinguishes them, and
            // the fall-through check (x11 = 0) is what shows the core stopped rather
            // than quietly continued.
            enc_case("branch f3=2", enc_b(13'd8, 5'd0, 5'd0, 3'h2),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("branch f3=3", enc_b(13'd8, 5'd0, 5'd0, 3'h3),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);

            // ---- JALR has no sub-encodings, and funct3 = 1 used to jump ---------
            enc_case("jalr f3=1",  enc_jalr_f3(12'h050, 5'd0, 5'd10, 3'h1),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("legal jalr", enc_jalr(12'h050, 5'd0, 5'd10),
                     32'h0000_0024, 32'h0, 32'h63, 32'h0, NO_TRAP);

            // ---- opcodes this core does not implement ---------------------------
            enc_case("opcode 0x2f",
                     with_op(enc_r(7'h21, 5'd4, 5'd3, 3'h0, 5'd10), 7'b0101111),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("opcode 0x7f",
                     with_op(enc_r(7'h00, 5'd4, 5'd3, 3'h0, 5'd10), 7'b1111111),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            enc_case("opcode 0x0b",
                     with_op(enc_load(12'h000, 5'd2, 3'h2, 5'd10), 7'b0001011),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);

            // ---- FENCE: legal, and legal means it must not be reported ----------
            // A decoder that rejected FENCE would look correct on every reject above.
            // Its rd field names x10, so this is also the check that a no-op which
            // names a register leaves the register alone.
            enc_case("fence nop",
                     with_op(enc_i(12'h000, 5'd0, 3'h0, 5'd10), `RV_OP_FENCE),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            // A CSR read: this core has no CSRs, so it is illegal rather than a
            // write to something that is not there - and it must not write the
            // register it names either.
            enc_case("csrrs",
                     with_op(enc_i(12'h340, 5'd0, 3'h2, 5'd10), `RV_OP_SYSTEM),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            // fence.i is SYSTEM with funct3 = 1, not a second flavour of FENCE, and
            // Zifencei is not implemented.
            enc_case("fence.i",
                     with_op(enc_i(12'h000, 5'd0, 3'h1, 5'd10), `RV_OP_SYSTEM),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
        end
    endtask

    // =========================================================================
    // D7: alignment exceptions, environment calls, and what a trap does to the
    // machine around it
    //
    // The alignment cases are checked at every address offset a load or store can
    // name, not one per width: a byte access has no misaligned case, a halfword
    // cares about one address bit and a word about two, and the three rules are
    // three separate chances to write the wrong mask. For each width there is
    // therefore an aligned acceptance next to the misaligned rejections - a rule
    // that rejects everything would pass a suite that only had the rejections.
    // =========================================================================
    task test_exceptions;
        begin
            $display("\n--- D7: alignment and environment-call exceptions ---");
            // ---- loads ----------------------------------------------------------------
            enc_case("lh odd",   enc_load(12'h001, 5'd2, 3'h1, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_LOAD_MISALIGN);
            enc_case("lw odd1",  enc_load(12'h001, 5'd2, 3'h2, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_LOAD_MISALIGN);
            enc_case("lw even2", enc_load(12'h002, 5'd2, 3'h2, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_LOAD_MISALIGN);
            enc_case("lw odd3",  enc_load(12'h003, 5'd2, 3'h2, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_LOAD_MISALIGN);
            enc_case("lhu odd",  enc_load(12'h001, 5'd2, 3'h5, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_LOAD_MISALIGN);
            // Byte loads at the same odd addresses: legal, and they read the byte
            // there. mem[0x201] = 0xAB, so both cases produce a non-zero answer and
            // neither can pass by writing nothing.
            enc_case("lbu odd",  enc_load(12'h001, 5'd2, 3'h4, 5'd10),
                     32'h0000_00ab, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("lb odd",   enc_load(12'h001, 5'd2, 3'h0, 5'd10),
                     32'hffff_ffab, 32'h5, 32'h0, 32'h0, NO_TRAP);

            // ---- stores ---------------------------------------------------------------
            enc_case("sh odd",   enc_s(12'h001, 5'd4, 5'd9, 3'h1),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_STORE_MISALIGN);
            enc_case("sw odd1",  enc_s(12'h001, 5'd4, 5'd9, 3'h2),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_STORE_MISALIGN);
            enc_case("sw even2", enc_s(12'h002, 5'd4, 5'd9, 3'h2),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_STORE_MISALIGN);
            enc_case("sw odd3",  enc_s(12'h003, 5'd4, 5'd9, 3'h2),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_STORE_MISALIGN);
            // The aligned forms of the same two widths, which must store.
            // Offset 2 rather than 0: the value must land in the upper half of the
            // word, which is the lane assignment the aligned-only rule leaves legal.
            enc_case("sh aligned", enc_s(12'h002, 5'd4, 5'd9, 3'h1),
                     32'h0, 32'h5, 32'h0, 32'h0022_0000, NO_TRAP);
            enc_case("sw aligned", enc_s(12'h000, 5'd4, 5'd9, 3'h2),
                     32'h0, 32'h5, 32'h0, 32'h0000_0022, NO_TRAP);
            enc_case("sb odd ok",  enc_s(12'h003, 5'd4, 5'd9, 3'h0),
                     32'h0, 32'h5, 32'h0, 32'h2200_0000, NO_TRAP);

            // ---- instruction address --------------------------------------------------
            // A B-type immediate is always even, so the only misaligned targets a
            // branch can name are the even-but-not-word-aligned ones. +6 from 0x20 is
            // 0x26: the condition is true, so this really would transfer control.
            enc_case("beq target 0x26", enc_b(13'd6, 5'd0, 5'd0, 3'h0),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_INSTR_MISALIGN);
            enc_case("jal target 0x26", enc_jal(21'd6, 5'd10),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_INSTR_MISALIGN);
            // A branch that is NOT taken has no target to check, even one whose
            // offset would have been misaligned: the exception is about the transfer,
            // not about the encoding.
            enc_case("beq not taken", enc_b(13'd6, 5'd3, 5'd4, 3'h0),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            // JALR clears bit 0 of the sum BEFORE the alignment rule is applied,
            // which is the architectural order. (rs1 + imm) = 0x201 becomes 0x200 and
            // is aligned, so this must not report anything; 0x203 becomes 0x202 and
            // must. Checking the unmasked sum would flag the first as an exception,
            // and `jalr rs1, 1(rs2)` is a legal instruction.
            enc_case("jalr mask ok",  enc_jalr(12'h001, 5'd2, 5'd0),
                     32'h0, 32'h0, 32'h0, 32'h0, NO_TRAP);
            enc_case("jalr mask bad", enc_jalr(12'h003, 5'd2, 5'd0),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_INSTR_MISALIGN);
            // A taken transfer to a properly aligned address, as the control.
            // The positive control for the transfer rule: +48 from 0x20 is 0x50, the
            // marker, word-aligned, so this jump must happen - link value written,
            // fall-through flushed, marker reached. Without it, "no exception for an
            // aligned target" would be satisfied just as well by a core that never
            // jumped anywhere.
            enc_case("jal aligned",   enc_jal(21'd48, 5'd10),
                     32'h0000_0024, 32'h0, 32'h63, 32'h0, NO_TRAP);

            // ---- environment calls ----------------------------------------------------
            // Both name x10 in their rd field, which no ECALL or EBREAK has any
            // business writing. Everything after them is flushed and the machine
            // stops: the fall-through marker must not run.
            enc_case("ecall",
                     with_op(enc_i(12'h000, 5'd0, 3'h0, 5'd10), `RV_OP_SYSTEM),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ECALL_M);
            enc_case("ebreak",
                     with_op(enc_i(12'h001, 5'd0, 3'h0, 5'd10), `RV_OP_SYSTEM),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_BREAKPOINT);
            // ECALL with the fields that would make it a CSR write if funct3 were
            // not zero: SYSTEM's sub-opcode field is what separates them, so this is
            // the pair that keeps "ECALL is legal" from meaning "anything with this
            // opcode is legal".
            enc_case("system f3=4",
                     with_op(enc_i(12'h000, 5'd0, 3'h4, 5'd10), `RV_OP_SYSTEM),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
            // ECALL with a non-zero immediate is not ECALL either.
            enc_case("system imm 2",
                     with_op(enc_i(12'h002, 5'd0, 3'h0, 5'd10), `RV_OP_SYSTEM),
                     32'h0, 32'h0, 32'h0, 32'h0, `TRAP_ILLEGAL_INSTR);
        end
    endtask

    // The stop has to be a stop. A trap that reported correctly and then kept
    // fetching would pass every check above, because the checks look at the cycle
    // the report appears. This one runs on, and asks whether anything changed.
    task test_trap_is_terminal;
        reg [31:0] pc_at_trap;
        integer j;
        begin
            $display("\n--- D7b: a trap stops the machine, and the report survives ---");
            // Rebuilt rather than reused: this test needs a long observation window
            // and markers of its own, and the shared program shape above is sized for
            // a 60-cycle check.
            rst = 1;
            clear_all;
            `IMEM[0] = enc_i(DATA_ADDR[11:0], 5'd0, 3'h0, 5'd2);
            `IMEM[ILLEGAL_W] = with_op(enc_i(12'h000, 5'd0, 3'h0, 5'd10),
                                       `RV_OP_SYSTEM);
            `IMEM[ILLEGAL_W+1] = enc_i(12'd5, 5'd0, 3'h0, 5'd11);
            `IMEM[ILLEGAL_W+2] = enc_i(12'd77, 5'd0, 3'h0, 5'd13);
            release_reset;
            for (j = 0; j < 60 && DUT.trap !== 1'b1; j = j + 1) @(posedge clk);
            pc_at_trap = DUT.trap_pc;
            if (DUT.trap !== 1'b1 || DUT.trap_cause !== `TRAP_ECALL_M) begin
                $display("FAIL ecall halts       | trap = %0b cause = %0d",
                         DUT.trap, DUT.trap_cause);
                failed = failed + 1;
            end else
                $display("PASS ecall halts       | trap = 1 cause = %0d pc = 0x%08h",
                         DUT.trap_cause, DUT.trap_pc);
            // 200 more cycles. The fetch is frozen, so the instructions that were in
            // flight ahead of the ECALL have drained and nothing new can enter: no
            // register beyond the trap point may change, ever.
            for (j = 0; j < 200; j = j + 1) @(posedge clk);
            check_reg(5'd11, 32'h0, "  still no marker");
            check_reg(5'd13, 32'h0, "  still no 2nd marker");
            if (DUT.trap !== 1'b1) begin
                $display("FAIL report is sticky   | trap fell back to 0 after 200 cycles");
                failed = failed + 1;
            end else if (DUT.trap_pc !== pc_at_trap ||
                         DUT.trap_cause !== `TRAP_ECALL_M) begin
                $display("FAIL report is sticky   | cause = %0d pc = 0x%08h | unchanged expected",
                         DUT.trap_cause, DUT.trap_pc);
                failed = failed + 1;
            end else
                $display("PASS report is sticky  | cause = %0d pc = 0x%08h after 200 cycles",
                         DUT.trap_cause, DUT.trap_pc);
        end
    endtask


    // =========================================================================
    // D8: one independent check per RV32I instruction
    //
    // Every instruction the core implements, executed for its value rather than for
    // its legality, each in a program of its own so that a wrong answer cannot be
    // hidden by an earlier instruction. FENCE, ECALL and EBREAK are in D6 and D7 -
    // for them the interesting fact is what they report, not what they compute.
    //
    // The pairs that matter are the ones an implementation can get wrong without
    // noticing. Signedness is the classic: this core once read BLT as BLTU, and every
    // BEQ/BNE test in the world still passed afterwards, because equality does not
    // depend on how the operands are interpreted. So each of the four ordering
    // branches and both SLT forms is checked on a pair where signed and unsigned
    // disagree - x3 = 0x100 and x6 = -1 - in BOTH directions: taken where the other
    // reading would not take it, and not taken where the other reading would.
    // =========================================================================
    task test_instruction_sweep;
        begin
            $display("\n--- D8: every instruction, for its value ---");
            // ---- R-type -------------------------------------------------------
            enc_case("add",  enc_r(7'h00, 5'd4, 5'd3, 3'h0, 5'd10),
                     32'h0000_0122, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("add neg", enc_r(7'h00, 5'd6, 5'd3, 3'h0, 5'd10),
                     32'h0000_00ff, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("sub",  enc_r(7'h20, 5'd4, 5'd3, 3'h0, 5'd10),
                     32'h0000_00de, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("sub neg", enc_r(7'h20, 5'd4, 5'd6, 3'h0, 5'd10),
                     32'hffff_ffdd, 32'h5, 32'h0, 32'h0, NO_TRAP);   // -1 - 34
            enc_case("sll",  enc_r(7'h00, 5'd7, 5'd3, 3'h1, 5'd10),
                     32'h0000_0400, 32'h5, 32'h0, 32'h0, NO_TRAP);
            // Signed compare: -1 < 256 is true signed, false unsigned (0xFFFFFFFF is
            // the largest operand pair available here).
            enc_case("slt true",  enc_r(7'h00, 5'd3, 5'd6, 3'h2, 5'd10),
                     32'h1, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("slt false", enc_r(7'h00, 5'd6, 5'd3, 3'h2, 5'd10),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("sltu false", enc_r(7'h00, 5'd3, 5'd6, 3'h3, 5'd10),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("sltu true",  enc_r(7'h00, 5'd6, 5'd3, 3'h3, 5'd10),
                     32'h1, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("xor",  enc_r(7'h00, 5'd4, 5'd3, 3'h4, 5'd10),
                     32'h0000_0122, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("or",   enc_r(7'h00, 5'd4, 5'd3, 3'h6, 5'd10),
                     32'h0000_0122, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("and",  enc_r(7'h00, 5'd4, 5'd3, 3'h7, 5'd10),
                     32'h0000_0000, 32'h5, 32'h0, 32'h0, NO_TRAP);

            // ---- I-type ALU ---------------------------------------------------
            enc_case("addi",  enc_i(12'hfff, 5'd3, 3'h0, 5'd10),
                     32'h0000_00ff, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("slti true",  enc_i(12'h000, 5'd6, 3'h2, 5'd10),
                     32'h1, 32'h5, 32'h0, 32'h0, NO_TRAP);           // -1 < 0
            enc_case("slti false", enc_i(12'hfff, 5'd4, 3'h2, 5'd10),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);           // 34 < -1
            enc_case("sltiu false", enc_i(12'h001, 5'd6, 3'h3, 5'd10),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);           // -1 <u 1
            // The pair that separates "compare against the immediate" from "compare
            // against the register the immediate's low five bits name": 0x404 has
            // imm[4:0] == 4, so the second reading is x2 < x4, which is false. The
            // register the field points at has to hold something other than the
            // immediate for the two to differ, which is why this took so long to
            // notice and is why the case is spelled out here.
            enc_case("slti imm vs field",  enc_i(12'h404, 5'd2, 3'h2, 5'd10),
                     32'h1, 32'h5, 32'h0, 32'h0, NO_TRAP);            // 512 < 1028
            enc_case("sltiu imm vs field", enc_i(12'h404, 5'd2, 3'h3, 5'd10),
                     32'h1, 32'h5, 32'h0, 32'h0, NO_TRAP);
            // A negative immediate, the other direction: -1 sign-extended, against a
            // positive register. Signed comparison of the immediate is what makes
            // this false.
            enc_case("slti imm neg", enc_i(12'hfff, 5'd3, 3'h2, 5'd10),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);            // 256 < -1
            enc_case("slti imm neg2", enc_i(12'hfff, 5'd6, 3'h2, 5'd10),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);            // -1 < -1
            enc_case("xori",  enc_i(12'hfff, 5'd3, 3'h4, 5'd10),
                     32'hffff_feff, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("ori",   enc_i(12'h022, 5'd3, 3'h6, 5'd10),
                     32'h0000_0122, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("andi",  enc_i(12'h0f0, 5'd3, 3'h7, 5'd10),
                     32'h0000_0000, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("slli",  enc_i({7'h00, 5'd4}, 5'd3, 3'h1, 5'd10),
                     32'h0000_1000, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("srli",  enc_i({7'h00, 5'd4}, 5'd6, 3'h5, 5'd10),
                     32'h0fff_ffff, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("srai",  enc_i({7'h20, 5'd4}, 5'd6, 3'h5, 5'd10),
                     32'hffff_ffff, 32'h5, 32'h0, 32'h0, NO_TRAP);
            // A shift amount of 0 and of 31: the two ends the shifter gets by
            // separate routes, and the one that shows an unmasked shamt.
            enc_case("slli 0",  enc_i({7'h00, 5'd0}, 5'd3, 3'h1, 5'd10),
                     32'h0000_0100, 32'h5, 32'h0, 32'h0, NO_TRAP);
            // x6 rather than x4: shifting 34 left by 31 is 0, because 34 is even and
            // every bit of it leaves the word. Only a value with bit 0 set shows the
            // top bit arriving.
            enc_case("slli 31", enc_i({7'h00, 5'd31}, 5'd6, 3'h1, 5'd10),
                     32'h8000_0000, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("srai 31", enc_i({7'h20, 5'd31}, 5'd6, 3'h5, 5'd10),
                     32'hffff_ffff, 32'h5, 32'h0, 32'h0, NO_TRAP);

            // ---- loads and stores ---------------------------------------------
            // (widths and alignment are D6/D7; these are the value-level forms, and
            // the stores are checked by what lands in memory, not by a register.)
            enc_case("lw",    enc_load(12'h000, 5'd2, 3'h2, 5'd10),
                     32'h0000_abcd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("lh",    enc_load(12'h000, 5'd2, 3'h1, 5'd10),
                     32'hffff_abcd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("lhu",   enc_load(12'h000, 5'd2, 3'h5, 5'd10),
                     32'h0000_abcd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("lb",    enc_load(12'h000, 5'd2, 3'h0, 5'd10),
                     32'hffff_ffcd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("lbu",   enc_load(12'h000, 5'd2, 3'h4, 5'd10),
                     32'h0000_00cd, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("sw",    enc_s(12'h000, 5'd4, 5'd9, 3'h2),
                     32'h0, 32'h5, 32'h0, 32'h0000_0022, NO_TRAP);
            enc_case("sh",    enc_s(12'h002, 5'd4, 5'd9, 3'h1),
                     32'h0, 32'h5, 32'h0, 32'h0022_0000, NO_TRAP);
            enc_case("sb",    enc_s(12'h001, 5'd4, 5'd9, 3'h0),
                     32'h0, 32'h5, 32'h0, 32'h0000_2200, NO_TRAP);

            // ---- upper immediates ---------------------------------------------
            enc_case("lui",   enc_u(20'hdeadb, 5'd10, 7'b0110111),
                     32'hdead_b000, 32'h5, 32'h0, 32'h0, NO_TRAP);
            // AUIPC is the one instruction whose answer depends on where it sits, so
            // this is also the check that the PC reaching the ALU is the instruction's
            // own address and not the fetch's ahead-of-itself one.
            enc_case("auipc", enc_u(20'h00001, 5'd10, 7'b0010111),
                     32'h0000_1020, 32'h5, 32'h0, 32'h0, NO_TRAP);

            // ---- jumps ---------------------------------------------------------
            enc_case("jal",   enc_jal(21'd48, 5'd10),
                     32'h0000_0024, 32'h0, 32'h63, 32'h0, NO_TRAP);
            enc_case("jal x0", enc_jal(21'd48, 5'd0),
                     32'h0000_0000, 32'h0, 32'h63, 32'h0, NO_TRAP);
            enc_case("jalr",  enc_jalr(12'h050, 5'd0, 5'd10),
                     32'h0000_0024, 32'h0, 32'h63, 32'h0, NO_TRAP);
            // JALR through a register, with the base coming from the setup rather
            // than from an immediate: the target is rs1 + imm, so this is the check
            // that the forwarded operand reached the target adder.
            enc_case("jalr x8", enc_jalr(12'h000, 5'd8, 5'd10),
                     32'h0000_0024, 32'h0, 32'h63, 32'h0, NO_TRAP);
            // Bit 0 of the sum is cleared before the target is used: 0x50 | 1 would
            // be misaligned, and with the mask applied it is 0x50 and legal.
            enc_case("jalr mask", enc_jalr(12'h051, 5'd0, 5'd10),
                     32'h0000_0024, 32'h0, 32'h63, 32'h0, NO_TRAP);

            // ---- branches, both directions, on a pair where signedness matters ---
            // +48 reaches the redirect marker at word 20, so "taken" is proved by
            // that register changing rather than by the absence of something.
            enc_case("beq taken",   enc_b(13'd48, 5'd3, 5'd3, 3'h0),
                     32'h0, 32'h0, 32'h63, 32'h0, NO_TRAP);
            enc_case("beq flush",   enc_b(13'd48, 5'd3, 5'd4, 3'h0),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("bne taken",   enc_b(13'd48, 5'd4, 5'd3, 3'h1),
                     32'h0, 32'h0, 32'h63, 32'h0, NO_TRAP);
            enc_case("bne flush",   enc_b(13'd48, 5'd3, 5'd3, 3'h1),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            // BLT vs BLTU on x6 = -1, x3 = 0x100: signed -1 < 256 takes it, unsigned
            // 0xFFFFFFFF < 256 does not. Both answers are checked for both forms.
            enc_case("blt taken",   enc_b(13'd48, 5'd3, 5'd6, 3'h4),
                     32'h0, 32'h0, 32'h63, 32'h0, NO_TRAP);
            enc_case("blt flush",   enc_b(13'd48, 5'd6, 5'd3, 3'h4),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("bge taken",   enc_b(13'd48, 5'd6, 5'd3, 3'h5),
                     32'h0, 32'h0, 32'h63, 32'h0, NO_TRAP);
            enc_case("bge flush",   enc_b(13'd48, 5'd3, 5'd6, 3'h5),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("bltu flush",  enc_b(13'd48, 5'd3, 5'd6, 3'h6),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
            enc_case("bltu taken",  enc_b(13'd48, 5'd6, 5'd3, 3'h6),
                     32'h0, 32'h0, 32'h63, 32'h0, NO_TRAP);
            enc_case("bgeu taken",  enc_b(13'd48, 5'd3, 5'd6, 3'h7),
                     32'h0, 32'h0, 32'h63, 32'h0, NO_TRAP);
            enc_case("bgeu flush",  enc_b(13'd48, 5'd6, 5'd3, 3'h7),
                     32'h0, 32'h5, 32'h0, 32'h0, NO_TRAP);
        end
    endtask

    // =========================================================================
    // D9 / D10: programs given as word lists
    //
    // The builders above all produce one instruction inside a fixed program, which
    // suits checking what an instruction computes. It does not suit checking what an
    // instruction *does to the pipeline around it*: several writers of one register,
    // or a store sitting on a path a taken branch is about to erase, only mean
    // anything as a sequence. So these cases lay out their own words.
    //
    // x2 is the load base (mem[0x200] = 0xABCD), x9 the store base (mem[0x400] = 0),
    // x4 = 0x22, x8 = 0x50. Everything else starts at zero.
    // =========================================================================
    reg [31:0] prog [0:31];

    task run_prog;
        input integer n;
        integer j;
        begin
            rst = 1;
            // clear_all leaves the whole instruction memory full of NOPs, so a program
            // shorter than the case's word list runs out into NOPs rather than into
            // the previous case's leftovers. What it must not do is touch prog[]: the
            // caller has already filled that in.
            clear_all;
            for (j = 0; j < n;  j = j + 1) `IMEM[j] = prog[j];
            poke(DATA_ADDR,  LOAD_VAL);
            poke(STORE_ADDR, 32'h0000_0000);
            `RF[2] = DATA_ADDR;
            `RF[3] = X3_VAL;
            `RF[4] = X4_VAL;
            `RF[8] = JUMP_TARGET;
            `RF[9] = STORE_ADDR;
            // Long enough for the longest program here - the loop - to finish and for
            // anything that was going to go wrong to have gone wrong.
            release_reset;
            run_cycles(60);
            rst = 1;
        end
    endtask

    // ---- D9: when several stages hold a value for the same register --------------
    task test_forwarding_priority;
        begin
            $display("\n--- D9: which pending writer of a register wins ---");

            // Three writers of x5, one sitting in each forwarding stage, and a
            // consumer that reads x5 on a cycle when all three are live: the youngest
            // in EX1, the middle in MEM, the oldest in WB. The answer names the end of
            // the priority chain the unit reads - youngest 3, middle 2, oldest 1.
            // Checking only "the value is right" would not separate the three: it is
            // the fact that all three are *different* values that does the work.
            prog[0] = enc_i(12'd1, 5'd0, 3'h0, 5'd5);
            prog[1] = enc_i(12'd2, 5'd0, 3'h0, 5'd5);
            prog[2] = enc_i(12'd3, 5'd0, 3'h0, 5'd5);
            prog[3] = enc_i(12'd0, 5'd5, 3'h0, 5'd10);
            run_prog(4);
            check_reg(5'd10, 32'h3, "youngest of three wins");

            // Same contest, youngest writer a load: the winner has to be the load and
            // the consumer has to wait for it, so a stale 2 and a value read before the
            // memory answered are both caught here.
            prog[0] = enc_i(12'd1, 5'd0, 3'h0, 5'd5);
            prog[1] = enc_i(12'd2, 5'd0, 3'h0, 5'd5);
            prog[2] = enc_load(12'h000, 5'd2, 3'h2, 5'd5);
            prog[3] = enc_i(12'd0, 5'd5, 3'h0, 5'd10);
            run_prog(4);
            check_reg(5'd10, 32'h0000_abcd, "load wins the contest");

            // x0 discards what is written to it, so nothing may be pending on it
            // either: a younger read has to see zero, not the result the instruction
            // that "wrote" x0 computed one stage back.
            prog[0] = enc_r(7'h00, 5'd3, 5'd4, 3'h0, 5'd0);       // x0 = x4 + x3
            prog[1] = enc_r(7'h00, 5'd0, 5'd0, 3'h0, 5'd10);      // x10 = x0 + x0
            run_prog(2);
            check_reg(5'd10, 32'h0, "x0 is never forwarded");

            // The other half: because nothing is ever written to x0, reading x0 cannot
            // depend on anything, so a load into x0 must not hold up a younger
            // instruction that reads x0. The value alone cannot tell a stall from no
            // stall, which is why D5 counts stalls for this case rather than here.
            prog[0] = enc_load(12'h000, 5'd2, 3'h2, 5'd0);        // lw x0, 0(x2)
            prog[1] = enc_i(12'h007, 5'd0, 3'h0, 5'd10);          // x10 = x0 + 7
            run_prog(2);
            check_reg(5'd10, 32'h7, "load to x0: no dependency");
        end
    endtask

    // ---- D10: effects a flushed instruction must not have ------------------------
    //
    // A taken branch does not merely stop executing the wrong-path instructions; it
    // has to take away everything they would otherwise have had an effect on.
    // Registers are the visible case and D1-D5 cover those. What is left is the
    // quieter set: a store that must not reach memory, an exception that must not be
    // reported, and - the one forwarding gets wrong - a write that must not become
    // the value a correctly fetched instruction reads.
    task test_wrong_path_effects;
        begin
            $display("\n--- D10: effects a flushed instruction must not have ---");

            // A store on the flushed path: memory is the effect with no register to
            // look at afterwards, and by the time the redirect lands the store's
            // address and data have both been forwarded, so it has everything it needs
            // to do damage.
            prog[0] = enc_b(13'd12, 5'd0, 5'd0, 3'h0);            // taken
            prog[1] = enc_s(12'h000, 5'd4, 5'd9, 3'h2);           // sw x4, 0(x9)
            prog[2] = enc_i(12'd5, 5'd0, 3'h0, 5'd11);
            prog[3] = enc_i(12'd99, 5'd0, 3'h0, 5'd12);
            run_prog(4);
            check_mem_word13(STORE_ADDR, 32'h0, "flushed store writes nothing");
            check_reg(5'd11, 32'h0, "flushed instruction ran");
            check_reg(5'd12, 32'h63, "branch target ran");
            check_reg(5'd10, 32'h0, "no link written by a branch");

            // A misaligned load on the flushed path. Exceptions are raised in execute
            // 2, which is also where the redirect is produced, so this case is about
            // which of the two wins: the branch says the load is not on the path, and
            // the machine has to believe it and keep running.
            prog[0] = enc_b(13'd12, 5'd0, 5'd0, 3'h0);            // taken
            prog[1] = enc_load(12'h001, 5'd2, 3'h2, 5'd10);       // lw x10, 1(x2)
            prog[3] = enc_i(12'd99, 5'd0, 3'h0, 5'd12);
            run_prog(4);
            if (DUT.trap !== 1'b0) begin
                failed = failed + 1;
                $display("FAIL %-24s | trap = %b cause = %0d at 0x%08h",
                         "flushed misalign trapped", DUT.trap,
                         DUT.trap_cause, DUT.trap_pc);
            end else begin
                $display("PASS %-24s | no exception, core ran on", "flushed misalign trapped");
            end
            check_reg(5'd10, 32'h0, "flushed load wrote a register");
            check_reg(5'd12, 32'h63, "branch target ran");

            // Again behind a JAL, because that redirect arrives with a link write
            // attached and travels a different data path.
            prog[0] = enc_jal(21'd12, 5'd10);
            prog[1] = enc_s(12'h000, 5'd4, 5'd9, 3'h1);           // sh x4, 0(x9)
            prog[3] = enc_i(12'd99, 5'd0, 3'h0, 5'd12);
            run_prog(4);
            check_mem_word13(STORE_ADDR, 32'h0, "store flushed behind a jump");
            check_reg(5'd10, 32'h4, "jump link");
            check_reg(5'd12, 32'h63, "jump target ran");

            // The forwarding form. The target reads x5; the flushed instruction between
            // the branch and the target also writes x5. Forwarding decides on register
            // numbers and pipeline positions, and neither of those says "the
            // instruction in EX/MEM was on the path we just abandoned" - only the flush
            // does. If a flushed write is ever forwarded, x10 comes out 9.
            prog[0] = enc_i(12'd7, 5'd0, 3'h0, 5'd5);             // x5 = 7
            prog[1] = enc_b(13'd8, 5'd0, 5'd0, 3'h0);             // taken: 0x04 + 8 = word 3
            prog[2] = enc_i(12'd9, 5'd0, 3'h0, 5'd5);             // x5 = 9, flushed
            prog[3] = enc_r(7'h00, 5'd0, 5'd5, 3'h0, 5'd10);      // x10 = x5 + x0
            run_prog(4);
            check_reg(5'd10, 32'h7, "flushed write not forwarded");

            // A not-taken branch is the opposite case: it resolves, changes nothing,
            // and the instruction after it still has to receive what the instruction
            // before it produced. There is no flush to lean on here, so a branch slot
            // that swallowed a forwarding source shows up as a stale zero.
            prog[0] = enc_r(7'h00, 5'd3, 5'd4, 3'h0, 5'd5);       // x5 = x4 + x3 = 0x122
            prog[1] = enc_b(13'd8, 5'd3, 5'd4, 3'h0);             // not taken
            prog[2] = enc_r(7'h00, 5'd0, 5'd5, 3'h0, 5'd10);      // x10 = x5 + x0
            prog[3] = enc_i(12'd5, 5'd0, 3'h0, 5'd11);            // still executed
            run_prog(4);
            check_reg(5'd10, 32'h0000_0122, "value past a not-taken branch");
            check_reg(5'd11, 32'h5, "not-taken fell through");

            // Backward branch: a loop, the one place a redirect goes somewhere lower
            // than the address being fetched and the one place a value written in one
            // iteration is read by the next. x10 reaching 4 is the loop-carried
            // dependency arriving; x11 being 5 says the loop left by the branch rather
            // than by running off the end, and x5 at zero says it left after four
            // iterations rather than three or five.
            prog[0] = enc_i(12'd4,   5'd0,  3'h0, 5'd5);          // x5 = 4
            prog[1] = enc_i(12'd1,   5'd10, 3'h0, 5'd10);         // x10 = x10 + 1
            prog[2] = enc_i(12'hfff, 5'd5,  3'h0, 5'd5);          // x5 = x5 - 1
            // -8 as a 13-bit field is 0x1ff8, not 0xff8; the shorter form is +4088,
            // which sends the loop somewhere nothing is waiting for it. enc_b is
            // checked against the assembler on exactly this value in D0.
            prog[3] = enc_b(13'h1ff8, 5'd0, 5'd5, 3'h1);           // bne x5, x0, -8
            prog[4] = enc_i(12'd5,   5'd0,  3'h0, 5'd11);
            run_prog(5);
            check_reg(5'd10, 32'h4, "loop iterations");
            check_reg(5'd5,  32'h0, "loop counter reached zero");
            check_reg(5'd11, 32'h5, "loop fell out at the end");
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
        test_instruction_sweep;
        test_forwarding_priority;
        test_wrong_path_effects;
        test_strict_decode;
        test_exceptions;
        test_trap_is_terminal;

        $display("\n========================================");
        if (failed == 0)
            $display("ALL DIRECTED TESTS PASSED");
        else
            $display("%0d DIRECTED TEST(S) FAILED", failed);
        $display("========================================\n");
        $finish;
    end

endmodule
