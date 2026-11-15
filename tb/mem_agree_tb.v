`timescale 1ns/1ns
// Standalone probe: do the behavioural memories and the sky130 macro memories
// agree? Run with `make mem-agree`. The regression run can only ever exercise one
// build or the other, so this is the only place the substitution itself is checked.
//
// WHAT IS COMPARED, AND WHY AT THIS LEVEL
//
// Both data-memory models are bare masked storage with a registered read: they
// have identical port lists, so anything they could possibly disagree about -
// which bank an address lands in, which byte lanes a masked store writes, when
// read data appears - shows up as a difference in the word they present. The
// comparison is therefore SAME CYCLE, r_behav against r_sram, with no allowance
// for one model being later than the other.
//
// That is a strictly stronger check than the one this file used to make. When the
// behavioural read was combinational, the probe had to compare cycle T against
// cycle T+1 to say anything at all, and in doing so it excused exactly the
// difference that mattered: a core built against one model could not run on the
// other. Now a one-cycle skew in either direction is a divergence.
//
// The sub-word rules are not part of the comparison, deliberately:
// dmem_w_lanes.v and dmem_r_lanes.v compute them once for both models, so
// agreeing there is structural rather than observed. What is compared is the storage those rules are applied to - which is
// where the two implementations are independently written and where they can
// actually differ.
//
// INSTRUCTION MEMORY. Both read asynchronously (the macro's port 1 is a
// combinational read), so the comparison is same-cycle there too. It exists
// because these wrappers had the same bank-select bug as the data memory: csb is
// active low, and driving it the wrong way round sent every fetch from the lower
// 2 KiB to another macro instead. Nothing in the simulation build can see that,
// because that build contains no macros.
module agree_tb;
    `include "defines.vh"

    reg clk = 0;
    reg         w_ena = 0;
    reg  [1:0]  width = `MEM_W;
    reg  [31:0] addr = 0;
    reg  [31:0] w_data = 0;

    // The store-side lanes both models are fed, computed exactly the way dmem.v
    // computes them, from the live access.
    wire [3:0]  w_strb;
    wire [31:0] w_lanes;

    dmem_w_lanes LANES (
        .byte_off (addr[1:0]),
        .width    (width),
        .w_data   (w_data),
        .w_strb   (w_strb),
        .w_lanes  (w_lanes)
    );

    wire [31:0] r_behav;
    wire [31:0] r_sram;

    dmem_behav B(.clk(clk), .w_ena(w_ena), .w_strb(w_strb),
                 .w_lanes(w_lanes), .addr(addr), .rdata(r_behav));
    dmem_sram  S(.clk(clk), .w_ena(w_ena), .w_strb(w_strb),
                 .w_lanes(w_lanes), .addr(addr), .rdata(r_sram));

    // Instruction memories, both asynchronous
    reg  [31:0] pc = 0;
    wire [31:0] i_behav;
    wire [31:0] i_sram;

    imem_behav IB(.pc(pc), .instr(i_behav));
    imem_sram  IS(.pc(pc), .instr(i_sram));

    always #5 clk = ~clk;

    localparam IMEM_WORDS = `IMEM_WORDS;
    localparam BANK_WORDS = 512;               // one sky130 macro
    localparam TOP_ADDR   = 32'h0000_1FFC;     // last word of 8 KiB

    integer errors = 0;
    integer checks = 0;

    // The address the read data being compared this cycle belongs to: the models
    // register their reads, so read data always describes the previous cycle's
    // access. Reported with a divergence so the message says which access differ.
    reg [31:0] prev_addr = 0;
    reg [1:0]  prev_width = `MEM_W;
    integer    first = 1;

    // Apply one cycle of stimulus to both models and compare what they present
    // for it. Sampled at a negedge, so the stimulus is stable across the posedge
    // that clocks both.
    task drive;
        input         we;
        input [1:0]   w;
        input [31:0]  a;
        input [31:0]  d;
        begin
            @(negedge clk);
            w_ena = we; width = w; addr = a; w_data = d;
            #1;
            if (!first && r_behav !== r_sram) begin
                $display("DIVERGE  addr=0x%08h width=%0d", prev_addr, prev_width);
                $display("         behavioural 0x%08h  vs  macros 0x%08h",
                         r_behav, r_sram);
                errors = errors + 1;
            end
            checks     = checks + 1;
            first      = 0;
            prev_addr  = a;
            prev_width = w;
        end
    endtask

    integer i, off, wi, bad_imem;
    reg [31:0] pat;
    initial begin
        #1;   // let both models' power-on clears run before anything is back-doored

        // ---- instruction memory ------------------------------------------------
        // Back-door the same contents into the behavioural array and all four macro
        // arrays, then read every word, plus unaligned addresses and both sides of
        // every bank boundary.
        bad_imem = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1) begin
            pat = {i[7:0], ~i[3:0], 8'hC3, i[10:0], 2'b00};
            IB.mem[i] = pat;
            if      (i < 512)  IS.sram0.mem[i]       = pat;
            else if (i < 1024) IS.sram1.mem[i - 512] = pat;
            else if (i < 1536) IS.sram2.mem[i - 1024]= pat;
            else               IS.sram3.mem[i - 1536]= pat;
        end
        for (i = 0; i < IMEM_WORDS; i = i + 1) begin
            pc = {20'h0, i[10:0], 2'b00};
            #1;
            if (i_sram !== i_behav) begin
                if (bad_imem < 3)
                    $display("IMEM DIVERGE pc=0x%08h behavioural 0x%08h macros 0x%08h",
                             pc, i_behav, i_sram);
                bad_imem = bad_imem + 1;
            end
        end
        // Unaligned fetch addresses, and every bank boundary, behave identically
        // too. The macro read port answers from the word containing the address in
        // both models; what an unaligned fetch means architecturally is decided
        // elsewhere, but the two implementations must not disagree about the word.
        for (off = 0; off < 4; off = off + 1) begin
            for (i = 0; i < 4; i = i + 1) begin
                pc = (i * BANK_WORDS * 4) + off;      // first word of each bank
                #1;
                if (i_sram !== i_behav) bad_imem = bad_imem + 1;
                pc = (i * BANK_WORDS * 4) - 4 + off;  // last word of the bank below
                #1;
                if (i_sram !== i_behav) bad_imem = bad_imem + 1;
            end
        end
        if (bad_imem != 0) begin
            $display("instruction memory: %0d divergences", bad_imem);
            errors = errors + bad_imem;
        end else
            $display("instruction memory: %0d reads, 0 divergences",
                     IMEM_WORDS + 32);
        pc = 0;

        // ---- data memory -------------------------------------------------------
        // Seed every word with a distinguishable pattern through both models at
        // once (they are driven identically, so one store path fills both).
        for (i = 0; i < IMEM_WORDS; i = i + 1) begin
            pat = {8'hA0 + i[7:0], 8'h5A, ~i[7:0], i[7:0]};
            drive(1, `MEM_W, {20'h0, i[10:0], 2'b00}, pat);
        end

        // Read sweep: every width at every byte offset, low memory, the top of
        // memory, and both sides of all three bank boundaries - which is where the
        // registered bank select matters, because a deselected macro keeps the last
        // word it read.
        for (wi = 0; wi < 3; wi = wi + 1) begin
            for (off = 0; off < 4; off = off + 1) begin
                for (i = 0; i < 8; i = i + 1) begin
                    drive(0, wi[1:0], {20'h0, i[10:0], 2'b00} + off, 32'h0);
                    drive(0, wi[1:0], TOP_ADDR + off, 32'h0);
                    // word 511 (last of bank 0), 512 (first of bank 1), and the
                    // two higher boundaries
                    drive(0, wi[1:0], 32'h0000_07fc + off, 32'h0);
                    drive(0, wi[1:0], 32'h0000_0800 + off, 32'h0);
                    drive(0, wi[1:0], 32'h0000_0ffc + off, 32'h0);
                    drive(0, wi[1:0], 32'h0000_1000 + off, 32'h0);
                    drive(0, wi[1:0], 32'h0000_17fc + off, 32'h0);
                    drive(0, wi[1:0], 32'h0000_1800 + off, 32'h0);
                    // alternate banks on consecutive cycles: a load from bank 0
                    // immediately followed by an access in bank 2
                    drive(0, wi[1:0], 32'h0000_0004 + off, 32'h0);
                    drive(0, wi[1:0], 32'h0000_1004 + off, 32'h0);
                end
            end
        end

        // Sub-word stores at every offset, then read the containing word back, so
        // any disagreement about which lanes a masked store touched shows up. The
        // width of the store is applied through the shared lane module, so this is
        // checking that both arrays honour the same write mask.
        for (wi = 0; wi < 2; wi = wi + 1) begin
            for (i = 0; i < 16; i = i + 1) begin
                for (off = 0; off < 4; off = off + 1) begin
                    drive(1, wi[1:0], 32'h0000_0040 + (i << 2) + off, 32'hDEAD_BEEF);
                    drive(0, `MEM_W,  32'h0000_0040 + (i << 2), 32'h0);
                end
            end
        end

        // And the same over the top bank, where an off-by-one in the bank decode
        // would wrap rather than write.
        for (wi = 0; wi < 2; wi = wi + 1) begin
            for (i = 0; i < 8; i = i + 1) begin
                drive(1, wi[1:0], TOP_ADDR - (i << 2) + (i & 3), 32'h5A5A_00FF);
                drive(0, `MEM_W,  TOP_ADDR - (i << 2), 32'h0);
            end
        end

        $display("data memory compared over %0d cycles: %0d divergences",
                 checks, errors);
        if (errors == 0) $display("MEMORIES AGREE");
        else             $display("MEMORIES DISAGREE");
        $finish;
    end
endmodule
