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
SIM_F    := filelists/sim.f
ASIC_F   := filelists/asic.f

BUILD    := build
VVP_SIM  := $(BUILD)/core.vvp
SIM_LOG  := $(BUILD)/sim.log
GOLDEN   := regression/golden.txt

# Verilator is expected to be silent; -Wall is a hard gate (no -Wno-fatal).
VL_FLAGS := --lint-only -Wall --top-module rv32i_core
IV_FLAGS := -g2005 -Wall

# Simulator chatter that is not part of the test verdict (VCD open/close notices)
# must not reach the golden transcript, or `make check` would disagree with
# itself depending on whether dumping was enabled.
FILTER   := sed -e '/^VCD /d'

NODUMP   ?= 0
ifeq ($(NODUMP),1)
  IV_DEFS := -DNODUMP
else
  IV_DEFS :=
endif

.PHONY: all sim check baseline lint lint-asic synth pipe-stats waves dirs clean

all: lint lint-asic check synth pipe-stats

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

# --------------------------------------------------------------------- lint --

lint: | dirs
	@echo "== lint (simulation build) =="
	$(VERILATOR) $(VL_FLAGS) -I$(RTL_DIR) -f $(SIM_F)
	@echo "lint OK"

lint-asic: | dirs
	@echo "== lint (sky130 build, power pins on) =="
	$(VERILATOR) $(VL_FLAGS) +define+USE_POWER_PINS -I$(RTL_DIR) -f $(ASIC_F)
	@echo "lint-asic OK"

# ------------------------------------------------------------------ synth ---

# Elaboration + generic synthesis, purely as a "is this synthesizable at all"
# gate. Cell counts are printed so refactors can prove they did not add flops.
# yosys has no -f filelist option, so the checked-in filelist is expanded into a
# script here rather than duplicated.
synth: $(BUILD)/synth.ys | dirs
	@if ! command -v $(YOSYS) >/dev/null 2>&1; then \
		echo "synth SKIPPED: $(YOSYS) not installed"; exit 0; \
	fi
	@echo "== synth (elaboration + cell stats) =="
	@$(YOSYS) -s $(BUILD)/synth.ys > $(BUILD)/synth.log 2>&1 \
		|| { tail -25 $(BUILD)/synth.log; exit 1; }
	@awk '/^ +Number of cells:/{c+=$$4} /DLATCH/{l+=$$2} /^[ ]+[^ ]*([Dd][Ff][Ff])[^ ]* +[0-9]+/{d+=$$2} END{printf "  total cells : %d\n  total flops : %d\n  latches     : %d\n", c, d, l}' $(BUILD)/synth.log
	@if test "$$(awk '/DLATCH/{d+=$$2} END{print d+0}' $(BUILD)/synth.log)" != "0"; then \
		echo "GATE FAIL: yosys inferred at least one latch"; exit 1; fi
	@echo "synth OK (full log: $(BUILD)/synth.log)"

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

# Source list shared by the synth gate: the filelist minus comments/+incdir.
$(BUILD)/srcs.txt: $(SIM_F) | dirs
	@grep -vE '^[[:space:]]*([#]|//|$$)' $(SIM_F) | grep -v '^+incdir' > $@

$(BUILD)/synth.ys: $(BUILD)/srcs.txt | dirs
	@{ while read -r f; do echo "read_verilog -I$(RTL_DIR) $$f"; done < $(BUILD)/srcs.txt; \
	   echo "synth -top rv32i_core"; } > $@

clean:
	rm -rf $(BUILD) obj_dir
