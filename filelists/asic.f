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
rtl/hazard_unit.v
rtl/forwarding_unit.v

# memories: sky130 macros
rtl/imem_sram.v
rtl/dmem_sram.v
vendor/sky130_sram_2kbyte_1rw1r_32x512_8.v
