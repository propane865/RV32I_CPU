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
rtl/branch_unit.v
rtl/hazard_unit.v
rtl/forwarding_unit.v
rtl/pipe_if_id.v
rtl/pipe_id_ex.v
rtl/pipe_ex1_ex2.v
rtl/pipe_ex_mem.v
rtl/pipe_mem_wb.v

# behavioural memories
rtl/imem.v
rtl/dmem.v
