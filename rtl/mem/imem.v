`timescale 1ns/1ns
// Instruction memory - implementation selection
//
// The core needs 8 KiB of read-only instruction storage (defines.vh: IMEM_WORDS,
// 2048 words), which is what the riscv-tests images in tb/compliance_tb.v need and
// more than one 2 KiB macro can hold. There are two very different ways to provide
// it and they cannot both exist in one elaboration, because they would both be
// called `imem`:
//
//   imem_behav  a plain array, initialised from the testbench. Simulation only.
//   imem_sram   four sky130_sram_2kbyte_1rw1r_32x512_8 macros, banked on
//               pc[12:11] - the same 2 KiB macros and the same four-way split the
//               data memory uses, so the two memories differ in read port and
//               nothing else.
//
// `USE_SRAM_MEMS` picks the macro version; without it the behavioural model is
// used. filelists/sim.f and filelists/asic.f are the two mutually exclusive
// source lists that keep this consistent - building with both files present is a
// duplicate-module error, which is the fail-safe direction.
//
// The instance is named IMPL because the testbench reaches the memory array
// through it (DUT.DP.IMEM.IMPL.mem) to load programs. tb/compliance_tb.v reaches
// one level deeper still, to IMPL.sram0..sram3, to do the same thing in the macro
// build.
//
// Size matters here in a way it does not for a memory with a bus: an address
// outside 8 KiB does not fault, it is masked, so a program that overran this memory
// would fetch from its own beginning. tb/elf2hex.py is the thing that refuses such
// a build; nothing at run time could report one.
`include "defines.vh"

module imem(input [31:0] pc, output [31:0] instr
    `ifdef USE_POWER_PINS
            `PWR_PORTS
    `endif
            );
`ifdef USE_SRAM_MEMS
    // Power pins only pass through the macro build: the behavioural model has no
    // such pins, so the behavioural branch leaves them alone.
    imem_sram IMPL(
        `ifdef USE_POWER_PINS
        .VPWR(VPWR), .VGND(VGND),
        `endif
        .pc(pc), .instr(instr));
`else
    imem_behav IMPL(.pc(pc), .instr(instr));
`endif
endmodule
