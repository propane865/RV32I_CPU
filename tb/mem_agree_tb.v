`timescale 1ns/1ns
// Standalone probe: do the behavioural memories and the sky130 macro memories
// agree? Run with `make mem-agree`. The regression run can only ever exercise one
// build or the other, so this is the only place the substitution itself is checked.
//
// DATA MEMORY. Both models get identical stimulus, and the comparison accounts for
// the one cycle the macros add:
//
//   behavioural r_data during cycle T  ==  macro r_data during cycle T+1
//
// which is the exact relationship stated in rtl/mem/dmem.v. Anything it reports is
// therefore a difference in the VALUE of a load or store, not a timing artifact.
//
// INSTRUCTION MEMORY. Both read asynchronously, so the comparison is same-cycle.
// It exists because this wrapper had the same bank-select bug as the data memory:
// csb is active low, and both wrappers drove it the wrong way round, so every
// fetch or access in the lower 2 KiB enabled the upper macro instead. Nothing in
// the simulation build can see that, because that build contains no macros.
module agree_tb;
    reg clk = 0;
    reg         w_ena = 0;
    reg         is_signed = 0;
    reg  [1:0]  width = 0;
    reg  [31:0] addr = 0;
    reg  [31:0] w_data = 0;
    wire [31:0] r_behav;
    wire [31:0] r_sram;

    dmem_behav B(.clk(clk), .w_ena(w_ena), .is_signed(is_signed),
                 .width(width), .addr(addr), .w_data(w_data), .r_data(r_behav));
    dmem_sram  S(.clk(clk), .w_ena(w_ena), .is_signed(is_signed),
                 .width(width), .addr(addr), .w_data(w_data), .r_data(r_sram));

    // Instruction memories, both asynchronous
    reg  [31:0] pc = 0;
    wire [31:0] i_behav;
    wire [31:0] i_sram;
    imem_behav IB(.pc(pc), .instr(i_behav));
    imem_sram  IS(.pc(pc), .instr(i_sram));

    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;
    reg [31:0] behav_prev;
    reg [31:0] addr_prev;
    reg [1:0]  width_prev;
    reg        sgn_prev;

    // Apply one cycle of stimulus, remember what the behavioural model read during
    // it, then compare the macros' output one cycle later.
    //
    // Sampled at negedges: during cycle T the behavioural read sees the array as of
    // the previous edge, and the macro's dout0 during cycle T+1 was clocked out of
    // that same array state with cycle T's address. So the two must be equal.
    integer first = 1;
    task drive;
        input         we;
        input [1:0]   w;
        input         sg;
        input [31:0]  a;
        input [31:0]  d;
        begin
            @(negedge clk);
            w_ena = we; width = w; is_signed = sg; addr = a; w_data = d;
            #1;
            behav_prev = r_behav;      // what the models must agree on for cycle T
            addr_prev  = a;
            width_prev = w;
            sgn_prev   = sg;

            @(negedge clk);            // now in cycle T+1
            #1;
            if (!first && r_sram !== behav_prev) begin
                $display("DIVERGE  addr=0x%08h width=%0d signed=%0b",
                         addr_prev, width_prev, sgn_prev);
                $display("         behavioural 0x%08h  vs  macros 0x%08h",
                         behav_prev, r_sram);
                errors = errors + 1;
            end
            checks = checks + 1;
            first  = 0;
        end
    endtask

    integer i, off, wi, bad_imem;
    reg [31:0] pat;
    initial begin
        #1;   // let both models' power-on clears run before anything is back-doored

        // ---- instruction memory ------------------------------------------------
        // Back-door the same contents into the behavioural array and the two macro
        // arrays, then read every word, unaligned addresses too, and both banks on
        // consecutive addresses.
        bad_imem = 0;
        for (i = 0; i < 1024; i = i + 1) begin
            pat = {i[7:0], ~i[3:0], 8'hC3, i[9:0], 2'b00};
            IB.mem[i] = pat;
            if (i < 512) IS.sram0.mem[i] = pat;
            else         IS.sram1.mem[i - 512] = pat;
        end
        for (i = 0; i < 1024; i = i + 1) begin
            pc = {20'h0, i[9:0], 2'b00};
            #1;
            if (i_sram !== i_behav) begin
                if (bad_imem < 3)
                    $display("IMEM DIVERGE pc=0x%08h behavioural 0x%08h macros 0x%08h",
                             pc, i_behav, i_sram);
                bad_imem = bad_imem + 1;
            end
        end
        // unaligned fetch addresses must behave identically too
        for (i = 0; i < 4; i = i + 1) begin
            pc = 32'h0000_07fc + i;      // across the bank boundary
            #1;
            if (i_sram !== i_behav) bad_imem = bad_imem + 1;
            pc = 32'h0000_0800 + i;
            #1;
            if (i_sram !== i_behav) bad_imem = bad_imem + 1;
        end
        if (bad_imem != 0) begin
            $display("instruction memory: %0d divergences", bad_imem);
            errors = errors + bad_imem;
        end else
            $display("instruction memory: 1028 reads, 0 divergences");
        pc = 0;

        // ---- data memory -------------------------------------------------------
        // Seed every word with a distinguishable pattern through both models at
        // once (they are driven identically, so one store path fills both).
        for (i = 0; i < 1024; i = i + 1) begin
            pat = {8'hA0 + i[7:0], 8'h5A, ~i[7:0], i[7:0]};
            drive(1, 2'd2, 0, {20'h0, i[9:0], 2'b00}, pat);
        end

        // Read sweep: every width at every byte offset, low memory, high memory
        // and across the 2 KiB bank boundary (word 511/512), which is where the
        // bank-select register matters.
        for (wi = 0; wi < 3; wi = wi + 1) begin
            for (off = 0; off < 4; off = off + 1) begin
                for (i = 0; i < 8; i = i + 1) begin
                    drive(0, wi[1:0], 0, {20'h0, i[9:0], 2'b00} + off, 32'h0);
                    drive(0, wi[1:0], 1, {20'h0, i[9:0], 2'b00} + off, 32'h0);
                    // top of memory
                    drive(0, wi[1:0], 0, 32'h0000_0ffc + off, 32'h0);
                    drive(0, wi[1:0], 1, 32'h0000_0ffc + off, 32'h0);
                    // bank boundary: word 511 (last of bank 0), 512 (first of bank 1)
                    drive(0, wi[1:0], 0, 32'h0000_07fc + off, 32'h0);
                    drive(0, wi[1:0], 1, 32'h0000_0800 + off, 32'h0);
                    // alternate banks on consecutive cycles: a load from bank 0
                    // immediately followed by an access in bank 1
                    drive(0, wi[1:0], 0, 32'h0000_0004 + off, 32'h0);
                    drive(0, wi[1:0], 0, 32'h0000_0804 + off, 32'h0);
                end
            end
        end

        // Sub-word stores at every offset, then read the whole bank back as words
        // so any disagreement about which lanes a masked store touched shows up.
        for (wi = 0; wi < 2; wi = wi + 1) begin
            for (i = 0; i < 16; i = i + 1) begin
                for (off = 0; off < 4; off = off + 1) begin
                    drive(1, wi[1:0], 0, 32'h0000_0040 + (i << 2) + off,
                          32'hDEAD_BEEF);
                    drive(0, 2'd2, 0, 32'h0000_0040 + (i << 2), 32'h0);
                end
            end
        end

        $display("data memory compared over %0d cycles: %0d divergences",
                 checks, errors);
        if (errors == 0) $display("MEMORIES AGREE");
        else             $display("MEMORIES DISAGREE");
        $finish;
    end
endmodule
