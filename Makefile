# =============================================================================
# RV32I core - build, lint, simulate, synthesise
#
#   make sim        simulate tb/core_tb.v (behavioural memories)
#   make check      simulate and diff against build/baseline.log
#   make baseline   promote the current behaviour to regression/golden.txt
#   make lint       verilator --lint-only -Wall, simulation filelist
#   make lint-asic  verilator --lint-only -Wall, sky130 filelist (+ power pins)
#   make synth      yosys elaboration + cell statistics (sky130 cleanliness gate)
#   make waves      simulate and leave build/core_tb.vcd behind
#   make all        lint + lint-asic + check + synth
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR ?= verilator
YOSYS    ?= yosys

RTL_DIR  := rtl
TB       := tb/core_tb.v
DIRECTED_TB := tb/directed_tb.v
SIM_F    := filelists/sim.f
ASIC_F   := filelists/asic.f

BUILD    := build
SIM_LOG  := $(BUILD)/sim.log
GOLDEN   := regression/golden.txt
DIRECTED_LOG     := $(BUILD)/directed.log
DIRECTED_GOLDEN  := regression/golden-directed.txt

# Verilator is expected to be silent; -Wall is a hard gate (no -Wno-fatal).
#
# The one rule switched off globally: an instance port deliberately left open
# (.cout()) is the idiomatic way to say "this output is not needed", and it is
# used that way consistently for discarded carries and unused macro read ports.
VL_FLAGS := --lint-only -Wall -Wno-PINCONNECTEMPTY --top-module rv32i_core
IV_FLAGS := -g2005 -Wall

# Simulator chatter that is not part of the test verdict must not reach the
# golden transcript:
#
#   VCD open/close notices  - otherwise `make check` disagrees with itself
#                             depending on whether dumping was enabled.
#   the $finish notice      - iverilog prints "file:line: $finish called at <t>"
#                             from 12.0 on, and not at all before that. Left in,
#                             the transcript is a function of the simulator
#                             version, so upgrading iverilog would fail the gate
#                             with no change in behaviour.
FILTER   := sed -e '/^VCD /d' -e '/$$finish called at /d'

# Whether the simulation dumps is a compile-time define, so it has to be part of
# the executable's name too. With a single shared name, `make sim NODUMP=1`
# followed by `make waves` considered the binary up to date and re-ran the
# no-dump build: no waveform, and no warning that one was expected.
#
# The name and the define are decided by the single test below, so they cannot
# disagree, and NODUMP is defaulted before the name is expanded. Both matter:
# `$(if $(NODUMP),nodump,dump)` reads NODUMP=0 as "no dump" - a make condition
# is true when the string is merely non-empty - so `make waves`, which passes
# NODUMP=0 down to the recursive sim, named its waveform binary core-nodump.vvp
# and reused a genuinely no-dump build sitting under that name.
NODUMP    ?= 0
ifeq ($(NODUMP),1)
  IV_DEFS   := -DNODUMP
  DUMP_MODE := nodump
else
  IV_DEFS   :=
  DUMP_MODE := dump
endif
VVP_SIM  := $(BUILD)/core-$(DUMP_MODE).vvp
DIRECTED_SIM := $(BUILD)/directed.vvp

.PHONY: all sim check baseline directed directed-baseline lint lint-asic synth synth-asic mem-agree pipe-stats waves dirs clean

all: lint lint-asic check mem-agree synth synth-asic pipe-stats

dirs:
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------- simulation --

$(VVP_SIM): $(TB) $(SIM_F) $(wildcard $(RTL_DIR)/*.v) $(wildcard $(RTL_DIR)/mem/*.v) | dirs
	$(IVERILOG) $(IV_FLAGS) $(IV_DEFS) -I$(RTL_DIR) -c $(SIM_F) -o $@ $(TB) -s core_tb

sim: $(VVP_SIM) | dirs
	@$(VVP) $< | $(FILTER) | tee $(SIM_LOG)

# Alias kept for clarity: same as sim, but the VCD is discarded.
waves: $(TB) $(SIM_F) | dirs
	@$(MAKE) --no-print-directory NODUMP=0 sim

# Regression gate: the transcript must match the recorded golden transcript byte for byte,
# AND it must actually contain a verdict. A testbench that silently fails to run
# (e.g. an unopenable $dumpfile kills iverilog with exit status 0) has happened
# here before, so a verdict-less log is treated as a failure.
check: $(VVP_SIM) | dirs
	@$(VVP) $< | $(FILTER) > $(SIM_LOG)
	@if ! grep -qE "ALL TESTS PASSED|TEST\(S\) FAILED" $(SIM_LOG); then \
		echo "GATE FAIL: no verdict found in $(SIM_LOG) - the testbench did not run."; \
		tail -5 $(SIM_LOG); exit 1; \
	fi
	@if [ ! -f $(GOLDEN) ]; then \
		echo "GATE FAIL: no $(GOLDEN). Run 'make baseline' once you intend to change behaviour."; exit 1; \
	fi
	@if diff -u $(GOLDEN) $(SIM_LOG); then \
		echo "GATE PASS: behaviour matches $(GOLDEN)"; \
	else \
		echo "GATE FAIL: behaviour differs from $(GOLDEN)"; exit 1; \
	fi

baseline: sim
	@mkdir -p $(dir $(GOLDEN))
	@cp $(SIM_LOG) $(GOLDEN)
	@echo "Golden transcript recorded at $(GOLDEN)"

# -------------------------------------------------------------- directed tests --
#
# Pipeline-control directed tests: same golden-transcript contract as `check`, in a
# separate binary because they ask a different question. core_tb asks whether an
# instruction computes the right value; these ask whether the right instructions
# execute at all when two control events land in the same cycle. They do not dump
# waves, so the binary name carries no dump mode.
$(DIRECTED_SIM): $(DIRECTED_TB) $(SIM_F) $(wildcard $(RTL_DIR)/*.v) $(wildcard $(RTL_DIR)/mem/*.v) | dirs
	$(IVERILOG) $(IV_FLAGS) -I$(RTL_DIR) -c $(SIM_F) -o $@ $(DIRECTED_TB) -s directed_tb

directed: $(DIRECTED_SIM) | dirs
	@$(VVP) $< | $(FILTER) > $(DIRECTED_LOG)
	@if ! grep -qE "ALL DIRECTED TESTS PASSED|DIRECTED TEST\(S\) FAILED" $(DIRECTED_LOG); then \
		echo "GATE FAIL: no verdict found in $(DIRECTED_LOG) - the testbench did not run."; \
		tail -5 $(DIRECTED_LOG); exit 1; \
	fi
	@if [ ! -f $(DIRECTED_GOLDEN) ]; then \
		echo "GATE FAIL: no $(DIRECTED_GOLDEN). Run 'make directed-baseline' once you intend to change behaviour."; exit 1; \
	fi
	@if diff -u $(DIRECTED_GOLDEN) $(DIRECTED_LOG); then \
		echo "GATE PASS: behaviour matches $(DIRECTED_GOLDEN)"; \
	else \
		echo "GATE FAIL: behaviour differs from $(DIRECTED_GOLDEN)"; exit 1; \
	fi

directed-baseline: $(DIRECTED_SIM) | dirs
	@$(VVP) $< | $(FILTER) > $(DIRECTED_LOG)
	@if ! grep -qE "ALL DIRECTED TESTS PASSED|DIRECTED TEST\(S\) FAILED" $(DIRECTED_LOG); then \
		echo "REFUSING to record a verdict-less transcript as the golden"; \
		tail -5 $(DIRECTED_LOG); exit 1; \
	fi
	@if grep -qE "FAILED" $(DIRECTED_LOG); then \
		echo "REFUSING to record a failing run as the golden baseline"; \
		grep -E "FAIL|FAILED" $(DIRECTED_LOG) | head -20; exit 1; \
	fi
	@mkdir -p $(dir $(DIRECTED_GOLDEN))
	@cp $(DIRECTED_LOG) $(DIRECTED_GOLDEN)
	@echo "Directed golden transcript recorded at $(DIRECTED_GOLDEN)"

# --------------------------------------------------------------------- lint --

lint: | dirs
	@echo "== lint (simulation build) =="
	$(VERILATOR) $(VL_FLAGS) -I$(RTL_DIR) -f $(SIM_F)
	@echo "lint OK"

# The sky130 build has to be elaborated twice over: USE_SRAM_MEMS swaps the
# behavioural memories for the macro wrappers, and USE_POWER_PINS adds the PDK
# power pins to the macro port list. Both are linted, and CI runs this so the
# tapeout path cannot rot unnoticed.
lint-asic: | dirs
	@echo "== lint (sky130 build, macros + power pins) =="
	$(VERILATOR) $(VL_FLAGS) +define+USE_SRAM_MEMS +define+USE_POWER_PINS -I$(RTL_DIR) -f $(ASIC_F)
	@echo "lint-asic OK"

# Direct model-vs-model comparison of the two memory implementations. The
# regression run can only ever exercise one of them, so this is the gate that
# checks the claim the other one is a stand-in for: same addresses, same stores,
# same loads, and the macro output - one cycle later, as it must be - identical.
# It covers every width at every byte offset, the top of memory, and the bank
# boundary in both directions.
mem-agree: | dirs
	$(IVERILOG) $(IV_FLAGS) -I$(RTL_DIR) -o $(BUILD)/mem_agree.vvp \
		$(RTL_DIR)/mem/dmem_w_lanes.v $(RTL_DIR)/mem/dmem_r_lanes.v \
		$(RTL_DIR)/mem/imem.v $(RTL_DIR)/mem/imem_behav.v $(RTL_DIR)/mem/imem_sram.v \
		$(RTL_DIR)/mem/dmem.v $(RTL_DIR)/mem/dmem_behav.v $(RTL_DIR)/mem/dmem_sram.v \
		vendor/sky130_sram_2kbyte_1rw1r_32x512_8.v \
		tb/mem_agree_tb.v -s agree_tb
	@$(VVP) $(BUILD)/mem_agree.vvp | tee $(BUILD)/mem_agree.log
	@grep -q "MEMORIES AGREE" $(BUILD)/mem_agree.log \
		|| { echo "GATE FAIL: behavioural and sky130 data memories disagree"; exit 1; }
	@echo "mem-agree OK"

# Pipeline storage, measured per stage register. The design-wide flop count above
# is dominated by the behavioural memories being mapped to flip-flops (~66k of
# it), which makes it far too noisy to notice an accidental extra field. These
# numbers are exact: each pipe_*.v must hold precisely its declared payload.
pipe-stats: | dirs
	@total=0; \
	for m in pipe_if_id pipe_id_ex pipe_ex1_ex2 pipe_ex_mem pipe_mem_wb; do \
		n=$$($(YOSYS) -p "read_verilog -I$(RTL_DIR) $(RTL_DIR)/$$m.v; synth -top $$m" 2>/dev/null \
		     | awk '/DFF/{d+=$$2} END{print d+0}'); \
		printf "  %-14s %5d flops\n" $$m $$n; total=$$((total+n)); \
	done; printf "  %-14s %5d flops (total pipeline storage)\n" TOTAL $$total

# ------------------------------------------------------------------ synth ---

# Elaboration + generic synthesis, purely as a "is this synthesizable at all"
# gate. Cell counts are printed so refactors can prove they did not add flops.
# yosys has no -f filelist option, so the checked-in filelists are expanded into
# scripts here rather than duplicated.

# Source list shared by the synth gates: a filelist minus comments/+incdir.
$(BUILD)/srcs-sim.txt: $(SIM_F) | dirs
	@grep -vE '^[[:space:]]*([#]|//|$$)' $(SIM_F) | grep -v '^+incdir' > $@

$(BUILD)/srcs-asic.txt: $(ASIC_F) | dirs
	@grep -vE '^[[:space:]]*([#]|//|$$)' $(ASIC_F) | grep -v '^+incdir' > $@

# The behavioural build maps its memories to flip-flops, so it is the one the
# testbench and the flop gates describe. The macro build is what OpenLane would
# see, and it needs its own gate: the SRAM wrappers are not exercised by the
# simulation filelist at all, and an elaboration error in them would otherwise
# only ever show up in a real tapeout flow.
$(BUILD)/synth-sim.ys: $(BUILD)/srcs-sim.txt | dirs
	@{ while read -r f; do echo "read_verilog -I$(RTL_DIR) $$f"; done < $<; \
	   echo "synth -top rv32i_core"; } > $@

$(BUILD)/synth-asic.ys: $(BUILD)/srcs-asic.txt | dirs
	@{ while read -r f; do \
	       echo "read_verilog -I$(RTL_DIR) -DUSE_SRAM_MEMS -DUSE_POWER_PINS $$f"; \
	   done < $<; echo "synth -top rv32i_core"; } > $@

# Run yosys over a generated script and gate on inferred latches.
# $(1) = yosys script, $(2) = log suffix, $(3) = build name
 define yosys_synth
	@if ! command -v $(YOSYS) >/dev/null 2>&1; then \
		echo "synth$(2) SKIPPED: $(YOSYS) not installed"; exit 0; \
	fi
	@echo "== synth: $(3) build (elaboration + cell stats) =="
	@$(YOSYS) -s $(1) > $(BUILD)/synth$(2).log 2>&1 \
		|| { tail -25 $(BUILD)/synth$(2).log; exit 1; }
	@awk '/^ +Number of cells:/{c+=$$4} /DLATCH/{l+=$$2} /^[ ]+[^ ]*([Dd][Ff][Ff])[^ ]* +[0-9]+/{d+=$$2} END{printf "  total cells : %d\n  total flops : %d\n  latches     : %d\n", c, d, l}' $(BUILD)/synth$(2).log
	@if test "$$(awk '/DLATCH/{d+=$$2} END{print d+0}' $(BUILD)/synth$(2).log)" != "0"; then \
		echo "GATE FAIL: yosys inferred at least one latch in the $(3) build"; exit 1; fi
	@echo "synth$(2) OK (full log: $(BUILD)/synth$(2).log)"
 endef

synth: $(BUILD)/synth-sim.ys | dirs
	$(call yosys_synth,$<,,behavioural)

# The macro build, with the sky130 macros instantiated as real cells: this is the
# elaboration OpenLane performs. It cannot check macro timing or the power grid,
# only that the RTL around them is synthesizable and latch free.
#
# Read the flop count here with care: the macro models in vendor/ are themselves
# behavioural memories, so most of those "flops" are the 4 KiB of storage inside
# them, not core state. The number that matters as a gate is latches == 0.
synth-asic: $(BUILD)/synth-asic.ys | dirs
	$(call yosys_synth,$<,-asic,sky130)

clean:
	rm -rf $(BUILD) obj_dir
