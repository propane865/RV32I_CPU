`timescale 1ns/1ns
// =============================================================================
// Behavioural stand-in for the sky130 high-density 2KB SRAM macro
//   sky130_sram_2kbyte_1rw1r_32x512_8
//   512 words x 32 bits, byte-masked write enable, one RW port + one R port.
//
// This exists so the ASIC filelist can be elaborated and linted in CI without
// pulling in the real PDK models. It is NOT a timing-accurate model.
//
// IMPORTANT - read latency. The real macro (and this stub) register their
// outputs, i.e. dout0/dout1 are valid only AFTER the clock edge that presents
// the address. Two in-tree wrappers assume otherwise:
//   * rtl/mem/dmem_sram.v reads the memory combinationally the way the
//     behavioural rtl/mem/dmem_behav.v does, so a load driven by the macro
//     lands in MEM/WB one cycle later than it does in simulation.
//   * rtl/mem/imem_sram.v ties clk1 to 1'b0 and therefore expects an
//     asynchronous read; a registered port-1 output never updates.
// Both are design-level issues (they need a pipeline change, not a model
// change) and are deliberately left out of this refactor. See the notes in the
// project report.
// =============================================================================

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
    output reg  [31:0] dout1
);
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

    always @(posedge clk1) begin
        if (!csb1) begin
            dout1 <= mem[addr1];
        end
    end

    // synthesis translate_off
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
            mem[init_i] = 32'h0;
        end
    end
    // synthesis translate_on
endmodule
