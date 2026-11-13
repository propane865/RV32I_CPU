# ASIC / sky130 build: core + SRAM macro wrappers + a behavioural macro stub.
#
# Mutually exclusive with filelists/sim.f: the SRAM wrappers and the behavioural
# memories declare the same module names (imem / dmem).
#
# Lint this build with +define+USE_POWER_PINS to check the power-pin variant of
# the macro wrappers.
#
# NOTE: this list is updated by the phases that add or split files.

+incdir+rtl

# core
rtl/rv32i_core.v
rtl/datapath.v
rtl/pc.v
rtl/decoder.v
rtl/control.v
rtl/imm_gen.v
rtl/regfile.v
rtl/alu.v
rtl/ks32.v
rtl/shifter.v
rtl/comp32.v
rtl/branch_unit.v
rtl/hazard_unit.v
rtl/forwarding_unit.v
rtl/pipe_if_id.v
rtl/pipe_id_ex.v
rtl/pipe_ex1_ex2.v
rtl/pipe_ex_mem.v
rtl/pipe_mem_wb.v

# memories: sky130 macro wrappers (rtl/mem/*.v select these via USE_SRAM_MEMS,
# which the Makefile defines for this build)
rtl/mem/imem.v
rtl/mem/imem_sram.v
rtl/mem/dmem.v
rtl/mem/dmem_sram.v
vendor/sky130_sram_2kbyte_1rw1r_32x512_8.v
