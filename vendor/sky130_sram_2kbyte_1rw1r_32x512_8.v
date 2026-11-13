`timescale 1ns/1ns
// =============================================================================
// Behavioural stand-in for the sky130 high-density 2KB SRAM macro
//   sky130_sram_2kbyte_1rw1r_32x512_8
//   512 words x 32 bits, byte-masked write enable, one RW port + one R port.
//
// This exists so the ASIC filelist can be elaborated, linted, synthesized and
// simulated in CI without pulling in the real PDK models. It models port
// behaviour, not delays - it is not timing accurate.
//
// PORT BEHAVIOUR
//
//   Port 0 (RW)  clocked. dout0 is valid only after the edge that presents the
//                address; a read during a write returns the pre-write contents
//                (real silicon leaves that undefined); a deselected macro keeps
//                the dout0 it already had.
//   Port 1 (R)   asynchronous. This is the extra read port that makes the part a
//                "1rw1r": it has no clock, and clk1 is a layout-only pin. A
//                deselected port drives x rather than holding, so reading the
//                wrong half of a banked pair cannot pass silently.
//
// An earlier version of this file clocked port 1. That was wrong, and it poisoned
// everything downstream: rtl/mem/imem_sram.v correctly ties clk1 low for an
// asynchronous fetch, and rather than the model being fixed, the wrappers grew
// comments describing a stale-read defect that only ever existed here.
//
// What each wrapper expects is stated in rtl/mem/dmem.v and rtl/mem/imem_sram.v;
// `make mem-agree` checks the behavioural and macro memories really do agree.
// =============================================================================

// clk1 exists to match the part's pin list; this macro flavour reads port 1
// asynchronously, so there is nothing for that clock to do.
/* verilator lint_off UNUSEDSIGNAL */
module sky130_sram_2kbyte_1rw1r_32x512_8 #(
    parameter DEPTH = 512
) (
`ifdef USE_POWER_PINS
    inout vccd1,
    inout vssd1,
`endif
    // Port 0: read / write
    input  wire        clk0,
    input  wire        csb0,
    input  wire        web0,
    input  wire [3:0]  wmask0,
    input  wire [8:0]  addr0,
    input  wire [31:0] din0,
    output reg  [31:0] dout0,
    // Port 1: read only
    input  wire        clk1,
    input  wire        csb1,
    input  wire [8:0]  addr1,
    output wire [31:0] dout1
);
/* verilator lint_on UNUSEDSIGNAL */
    reg [31:0] mem [0:DEPTH-1];

    always @(posedge clk0) begin
        if (!csb0) begin
            if (!web0) begin
                if (wmask0[0]) mem[addr0][7:0]   <= din0[7:0];
                if (wmask0[1]) mem[addr0][15:8]  <= din0[15:8];
                if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
                if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
            end
            dout0 <= mem[addr0];
        end
    end

    // Port 1 is the extra read port that makes this a "1rw1r" macro, and in the
    // real part it has no clock - it is an asynchronous read, which is the whole
    // point of having it. clk1 is a layout-only pin on this flavour.
    //
    // An earlier version of this stub clocked port 1 with `always @(posedge clk1)`,
    // which is wrong and poisoned everything downstream: a design that (correctly)
    // ties clk1 low looked like it was reading a stale word, and the wrappers grew
    // comments describing a bug that only existed here.
    //
    // A deselected port drives x, not a held value: real silicon tri-states, and
    // staying x is what makes a bank selected the wrong way show up as a mismatch
    // instead of quietly returning a neighbour's contents.
    assign dout1 = !csb1 ? mem[addr1] : 32'hx;

    // synthesis translate_off
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
            mem[init_i] = 32'h0;
        end
    end
    // synthesis translate_on
endmodule
