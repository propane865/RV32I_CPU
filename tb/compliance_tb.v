`timescale 1ns/1ns
// =============================================================================
// tb/compliance_tb.v - run one riscv-tests program and report its verdict.
//
//     vvp build/compliance.vvp +TEST=rv32ui-p-add \
//         +IMEM=build/tests/rv32ui-p-add.imem.hex \
//         +DMEM=build/tests/rv32ui-p-add.dmem.hex
//
// One test per process. That is not a convenience: a riscv-test program is a
// flat binary starting at 0 with no way to reset the machine between tests, so
// running two in one simulation would mean the second inherits whatever the
// first left in the register file and the data memory - which is precisely the
// kind of cross-test contamination that makes a compliance result meaningless.
// make compliance loops over the suite and concatenates the verdicts.
//
// WHAT A VERDICT MEANS
//
// The test decides its own fate and tells us through the exit protocol
// (tb/env/riscv_test.h): a riscv-test ends in an ECALL whose argument is 0 for
// pass or (test_number << 1) | 1 for fail. This core has no OS and no tohost
// device, so the ECALL arrives here as an environment-call exception - the one
// exception the testbench is not allowed to treat as a failure. Hence:
//
//   trap && cause == ECALL && x10 == 0                  PASS
//   trap && cause == ECALL && x10 != 0                  FAIL, test x10>>1 failed
//   trap && cause != ECALL                              FAIL: the core took an
//                                                        exception the test did
//                                                        not ask for, and the
//                                                        cause plus the PC say
//                                                        what it was
//   no trap within CYCLE_CAP                            FAIL timeout
//
// The middle case is the one that makes this suite worth wiring up. An illegal
// encoding the decoder should have rejected, a misaligned access, an exception
// raised where there should be none: each shows up here attributed to a test and
// an address, not as a wrong value three instructions later.
//
// This testbench and the ECALL path check each other. If ECALL did not reach the
// exception report, every test would time out; if the halt did not hold, tests
// would run off the end of their own code and report an illegal-instruction trap.
//
// WHY THE IMAGES ARE LOADED HERE RATHER THAN BY THE CORE
//
// There is no loader, no bus and no boot ROM. The memories are arrays, so the
// testbench fills them the way every other testbench in this repo does -
// hierarchically - before releasing reset. Under USE_SRAM_MEMS the same two hex
// images are distributed across the four 2 KiB macros, bank by bank, which is the
// point of compiling this file twice: identical programs, identical images,
// different storage, and any disagreement between the two runs is a bug in the
// macro wrapper rather than in a test.
// =============================================================================

module compliance_tb;
    `include "defines.vh"

    // Generous, and deliberately not tuned: the largest test in the suite is a
    // little over 1 KiB of code, so reaching this count means the program is
    // looping rather than working. It has to be finite - without a cap a core that
    // mis-evaluates one backward branch hangs the simulation instead of reporting
    // a failure - and the cost of overshooting is only simulation time on the
    // failure path.
    localparam integer CYCLE_CAP = 100000;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    wire        trap;
    wire [3:0]  trap_cause;
    wire [31:0] trap_pc;
    wire [31:0] pc_out, dmem_addr, dmem_wdata, dmem_rdata;
    wire [1:0]  dmem_width;
    wire        dmem_w_ena;

    rv32i_core DUT (
        .clk         (clk),
        .rst         (rst),
        .pc_out      (pc_out),
        .dmem_addr   (dmem_addr),
        .dmem_wdata  (dmem_wdata),
        .dmem_rdata  (dmem_rdata),
        .dmem_width  (dmem_width),
        .dmem_w_ena  (dmem_w_ena),
        .trap        (trap),
        .trap_cause  (trap_cause),
        .trap_pc     (trap_pc)
    );

    // Plus-arg strings: wide enough for the longest path make passes, and the size
    // only has to be right because a truncated path shows up as a $readmemh error
    // naming a file that does not exist, which is unmistakable.
    reg [8*160-1:0] imem_file;
    reg [8*160-1:0] dmem_file;
    reg [8*40-1:0]  test_name;

    // Image staging, used by the macro build to spread one image over four banks.
    reg [31:0] imem_img [0:`IMEM_WORDS-1];
    reg [7:0]  dmem_img [0:`DMEM_BYTES-1];

    integer i;
    integer cycles;

    // Cycle cap, overridable with +CAP= for the sake of experiments: a run meant to
    // show what a core that never reports an exception looks like should not have to
    // sit through 100000 cycles times forty tests to show it.
    integer cap = CYCLE_CAP;

    task load_images;
        begin
`ifdef USE_SRAM_MEMS
            // Word images, 2 KiB per bank, bank = word_addr[10:9] - the same split
            // rtl/mem/imem_sram.v and rtl/mem/dmem_sram.v make at run time. Reading
            // into the local arrays first keeps the two builds loading from the same
            // files, so a difference between them cannot be blamed on the images.
            $readmemh(imem_file, imem_img);
            $readmemh(dmem_file, dmem_img);
            for (i = 0; i < `IMEM_WORDS / 4; i = i + 1) begin
                DUT.DP.IMEM.IMPL.sram0.mem[i] = imem_img[i];
                DUT.DP.IMEM.IMPL.sram1.mem[i] = imem_img[`IMEM_WORDS/4 + i];
                DUT.DP.IMEM.IMPL.sram2.mem[i] = imem_img[2 * (`IMEM_WORDS/4) + i];
                DUT.DP.IMEM.IMPL.sram3.mem[i] = imem_img[3 * (`IMEM_WORDS/4) + i];
                // The macros are 32-bit wide with the byte lanes resolved outside
                // them (rtl/mem/dmem_w_lanes.v), so the array holds little-endian
                // words and is loaded as such.
                DUT.DP.DMEM.IMPL.sram0.mem[i] = {dmem_img[4*i+3], dmem_img[4*i+2],
                                                 dmem_img[4*i+1], dmem_img[4*i]};
                DUT.DP.DMEM.IMPL.sram1.mem[i] =
                    {dmem_img[2048+4*i+3], dmem_img[2048+4*i+2],
                     dmem_img[2048+4*i+1], dmem_img[2048+4*i]};
                DUT.DP.DMEM.IMPL.sram2.mem[i] =
                    {dmem_img[4096+4*i+3], dmem_img[4096+4*i+2],
                     dmem_img[4096+4*i+1], dmem_img[4096+4*i]};
                DUT.DP.DMEM.IMPL.sram3.mem[i] =
                    {dmem_img[6144+4*i+3], dmem_img[6144+4*i+2],
                     dmem_img[6144+4*i+1], dmem_img[6144+4*i]};
            end
`else
            // Both behavioural arrays are already laid out the way the images are:
            // imem word-indexed, dmem byte-indexed, whole memory, zero padded.
            $readmemh(imem_file, DUT.DP.IMEM.IMPL.mem);
            $readmemh(dmem_file, DUT.DP.DMEM.IMPL.mem);
`endif
        end
    endtask

    initial begin
        if (!$value$plusargs("IMEM=%s", imem_file) ||
            !$value$plusargs("DMEM=%s", dmem_file)) begin
            $display("FAIL <no image> | usage: +TEST=<name> +IMEM=<file> +DMEM=<file>");
            $display("0 PASSED / 1 FAILED");
            $finish(1);
        end
        if (!$value$plusargs("TEST=%s", test_name))
            test_name = "rv32ui-p-<unknown>";

        load_images;

        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;

        if (!$value$plusargs("CAP=%d", cap) || cap <= 0)
            cap = CYCLE_CAP;

        cycles = 0;
        while (trap !== 1'b1 && cycles < cap) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        // The exit code is in a0, written by the instruction immediately before the
        // ECALL - which is still in the memory stage on the cycle the exception is
        // detected, because an exception is raised in execute 2. It reaches the
        // register file one cycle later: the halt stops the *front end*, and
        // everything older than the trapping instruction keeps retiring, which is
        // what makes the exception precise. So reading a0 here and now would report
        // the test that ran before this one. Two cycles is the minimum; four is what
        // leaves room for the drain without pretending to know the pipeline depth.
        repeat (4) @(posedge clk);

        if (trap !== 1'b1) begin
            $display("FAIL %-16s | timeout after %0d cycles, stuck at pc 0x%08h",
                     test_name, cap, pc_out);
        end else if (trap_cause !== `TRAP_ECALL_M) begin
            $display("FAIL %-16s | unexpected trap: cause %0d at 0x%08h",
                     test_name, trap_cause, trap_pc);
        end else if (DUT.DP.RF.regs[10] !== 32'h0) begin
            $display("FAIL %-16s | exit code 0x%08h: test %0d reported failure",
                     test_name, DUT.DP.RF.regs[10], DUT.DP.RF.regs[10] >> 1);
        end else begin
            $display("PASS %-16s | ecall with a0 = 0", test_name);
        end
        $finish;
    end

    // A run that never even reaches the verdict (a $finish above, or an
    // elaboration oddity) must not be able to look like a pass, so the per-test
    // line is all this prints; make adds up the lines and compares the whole thing
    // to regression/golden-compliance.txt.
endmodule
