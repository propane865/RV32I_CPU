`timescale 1ns/1ns
// Instruction memory - implementation selection
//
// The core needs 4 KiB of read-only instruction storage. There are two very
// different ways to provide it and they cannot both exist in one elaboration,
// because they would both be called `imem`:
//
//   imem_behav  a plain array, initialised from the testbench. Simulation only.
//   imem_sram   two sky130_sram_2kbyte_1rw1r_32x512_8 macros. The real chip.
//
// `USE_SRAM_MEMS` picks the macro version; without it the behavioural model is
// used. filelists/sim.f and filelists/asic.f are the two mutually exclusive
// source lists that keep this consistent - building with both files present is a
// duplicate-module error, which is the fail-safe direction.
//
// The instance is named IMPL because the testbench reaches the memory array
// through it (DUT.DP.IMEM.IMPL.mem) to load programs.
module imem(input [31:0] pc, output [31:0] instr);
`ifdef USE_SRAM_MEMS
    imem_sram IMPL(.pc(pc), .instr(instr));
`else
    imem_behav IMPL(.pc(pc), .instr(instr));
`endif
endmodule
