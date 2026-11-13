# Simulation build: core + behavioural memory models.
#
# The behavioural memories and the sky130 SRAM wrappers declare the SAME module
# names, so exactly one pair may appear in any single compilation. Use
# filelists/asic.f for the SRAM build. Never glob rtl/**/*.v.
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

# behavioural memories
rtl/imem.v
rtl/dmem.v
