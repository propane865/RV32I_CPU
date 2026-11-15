# =============================================================================
# RV32I core - build, lint, simulate, synthesise
#
#   make sim        simulate tb/core_tb.v (behavioural memories), print the transcript
#   make check      ALL FOUR golden-transcript gates: core_tb, directed, and both
#                   compliance runs. Per-suite: check-core, check-directed,
#                   check-compliance, check-compliance-sram.
#   make baseline   promote core_tb's current behaviour to regression/golden.txt
#                   (the other three: directed-baseline, compliance-baseline,
#                    compliance-sram-baseline; each refuses a failing run)
#   make directed   pipeline-control + instruction-sweep tests, gated
#   make compliance upstream riscv-tests rv32ui, 40 tests, behavioural memories
#   make compliance-sram                ... the same, against the sky130 macros
#   make test-images                    assemble + link + convert the suite only
#   make lint       verilator --lint-only -Wall, simulation filelist
#   make lint-asic  verilator --lint-only -Wall, sky130 filelist (+ power pins)
#   make synth      yosys elaboration + cell stats + structural check
#   make synth-asic the same over the build OpenLane would see
#   make mem-agree  behavioural vs sky130 data memory, cycle for cycle
#   make pipe-stats flops per pipeline stage register
#   make waves      simulate and leave build/core_tb.vcd behind
#   make all        lint + lint-asic + check (all four suites) + mem-agree + both
#                   syntheses + pipe-stats
#
#   riscv-tests (see vendor/riscv-tests/UPSTREAM.md and tb/env/README.md):
#   make test-images           assemble + link + convert every rv32ui test
#   make build/tests/rv32ui-p-add.imem.hex   one test, through the same rules
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

.PHONY: all sim check baseline directed directed-baseline lint lint-asic \
        synth synth-asic mem-agree pipe-stats waves dirs clean test-images \
        compliance compliance-sram compliance-baseline compliance-sram-baseline \
        check check-core check-directed check-compliance check-compliance-sram

# Everything, in the order that fails fastest: lint, then the four golden
# transcripts, then the memory-model equivalence, then the two syntheses.
#
# `check` is the four gates - core_tb, the directed suite, and both compliance runs -
# so `all` picks up directed and compliance through it rather than by naming them
# again. Naming them twice would not make the signoff stronger; it would run two
# 40-test suites and a 800-check directed run a second time, and a gate that takes
# twice as long for no extra coverage is a gate people skip.
all: lint lint-asic check mem-agree synth synth-asic pipe-stats

check: check-core check-directed check-compliance check-compliance-sram
	@echo "ALL GOLDEN TRANSCRIPTS MATCH"

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

# What a finished run of each suite looks like. Variables rather than literals in
# the calls below: a $(call ...) in a recipe has to fit on one recipe line, because
# make hands a backslash-newline to the shell rather than to the function, and a
# regex that has quietly grown a newline matches nothing - which then reports "the
# testbench did not run" about a testbench that ran perfectly.
CORE_VERDICT     := ALL TESTS PASSED|TEST\(S\) FAILED
DIRECTED_VERDICT := ALL DIRECTED TESTS PASSED|DIRECTED TEST\(S\) FAILED

# One golden-transcript gate, shared by every suite in this repo: run, insist the
# transcript contains a verdict, insist a golden exists, insist the two match byte
# for byte.
#
# The verdict check is not ceremony. A testbench that silently fails to run - an
# unopenable $dumpfile kills iverilog with exit status 0, which has happened here -
# produces an empty transcript, and an empty transcript diffs clean against nothing
# only until someone records an empty run as the golden. So a verdict-less log is a
# failure before it is ever a comparison.
#
# $(1) binary to run, $(2) transcript, $(3) golden, $(4) what a finished run looks
# like, $(5) the target that records the golden, $(6) name used in messages.
define golden_gate
	@$(VVP) $(1) | $(FILTER) > $(2)
	@if ! grep -qE "$(4)" $(2); then \
		echo "GATE FAIL: no verdict found in $(2) - the testbench did not run."; \
		tail -5 $(2); exit 1; \
	fi
	@if [ ! -f $(3) ]; then \
		echo "GATE FAIL: no $(3). Run 'make $(5)' once you intend to change behaviour."; exit 1; \
	fi
	@if diff -u $(3) $(2); then \
		echo "GATE PASS: $(6) matches $(3)"; \
	else \
		echo "GATE FAIL: $(6) differs from $(3)"; exit 1; \
	fi
endef

# Per-suite, so CI can say which one broke; `check` below is the one you type.
check-core: $(VVP_SIM) | dirs
	$(call golden_gate,$(VVP_SIM),$(SIM_LOG),$(GOLDEN),$(CORE_VERDICT),baseline,core_tb)

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

check-directed: $(DIRECTED_SIM) | dirs
	$(call golden_gate,$(DIRECTED_SIM),$(DIRECTED_LOG),$(DIRECTED_GOLDEN),$(DIRECTED_VERDICT),directed-baseline,directed)

# The name the plan, the README and muscle memory use.
directed: check-directed

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

# ---------------------------------------------------------------- riscv-tests --
#
# Upstream RV32I test bodies (vendor/riscv-tests, pinned in UPSTREAM.md) built
# against tb/env, the CSR-free environment this core can actually assemble.
#
# The naming follows riscv-tests' own convention, rv32ui-p-<test>, because that is
# the name a failure is reported under everywhere else; the source is the shorter
# <test>.S, which the pattern rule below maps.

RISCV_CC      ?= riscv64-unknown-elf-gcc
RISCV_READELF ?= riscv64-unknown-elf-readelf
PYTHON        ?= python3

RVTEST_ISA   := vendor/riscv-tests/isa
RVTEST_ENV   := tb/env
TEST_BUILD   := $(BUILD)/tests

# Tests that are not run, each with the reason written up in tb/env/README.md:
#   fence_i  needs the Zifencei extension (`fence.i` does not assemble for
#            -march=rv32i) and a memory that instructions can be written back
#            into, which a core with separate instruction and data memories
#            does not have.
#   ma_data  requires a misaligned load or store to complete rather than raise
#            load-address-misaligned / store-address-misaligned, which is the
#            opposite of what rtl/trap_unit.v does.
# Everything else in the suite builds, and `make compliance` is what proves it.
RVTEST_SKIP  := fence_i ma_data
RVTEST_TESTS := $(addprefix rv32ui-p-,\
                  $(filter-out $(RVTEST_SKIP),$(notdir $(basename $(wildcard $(RVTEST_ISA)/rv32ui/*.S)))))

# -mno-relax is not a workaround for a toolchain quirk: gp is TESTNUM here
# (tb/env/riscv_test.h), and linker relaxation is entitled to rewrite
# lui/addi pairs into gp-relative small-data accesses, which would quietly make
# the linker own a register the tests are using to report their own results.
RVTEST_CFLAGS := -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -static -O2 \
                 -mno-relax -I$(RVTEST_ENV) -I$(RVTEST_ISA)/macros/scalar \
                 -T$(RVTEST_ENV)/link.ld

$(TEST_BUILD):
	@mkdir -p $@

$(TEST_BUILD)/rv32ui-p-%.riscv: $(RVTEST_ISA)/rv32ui/%.S $(RVTEST_ENV)/riscv_test.h $(RVTEST_ENV)/link.ld | $(TEST_BUILD)
	@if ! command -v $(RISCV_CC) >/dev/null 2>&1; then \
		echo "compliance build SKIPPED: $(RISCV_CC) not installed"; exit 1; \
	fi
	$(RISCV_CC) $(RVTEST_CFLAGS) -o $@ $<

# One recipe, two outputs: the converter writes both hex images in a single pass
# over the ELF, and as separate targets they would either run it twice or let a
# half-converted pair look up to date. Grouped targets (`&:`) say what is really
# true, which is that the pair is one artefact.
#
# tb/elf2hex.py is also where the memory map is enforced - section and segment
# tables against the 8 KiB memories, no overlaps, room left for the stack - so a
# test that would wrap around an address range at run time fails here instead,
# with the section and the rule named.
# The ELF is built by one pattern rule and consumed by another, which makes it an
# intermediate as far as GNU make is concerned, and make deletes intermediates it
# believes nothing retains. It is kept on purpose: when a compliance test fails, the
# ELF is the thing you objdump, and re-downloading a deleted artefact to look at it
# is a bad way to spend a debugging session.
.PRECIOUS: $(TEST_BUILD)/rv32ui-p-%.riscv

$(TEST_BUILD)/rv32ui-p-%.imem.hex $(TEST_BUILD)/rv32ui-p-%.dmem.hex &: $(TEST_BUILD)/rv32ui-p-%.riscv tb/elf2hex.py | $(TEST_BUILD)
	# $* is the bare test name (`add`), the artefacts are the upstream-named pair
	# (`rv32ui-p-add`), and the testbench is given that name to report under.
	$(PYTHON) tb/elf2hex.py --elf $< --out $(TEST_BUILD)/rv32ui-p-$* \
		--readelf $(RISCV_READELF)

test-images: $(addsuffix .imem.hex,$(addprefix $(TEST_BUILD)/,$(RVTEST_TESTS)))
	@echo "$(words $(RVTEST_TESTS)) riscv-tests images built in $(TEST_BUILD)"

# ------------------------------------------------------------- compliance run --
#
# tb/compliance_tb.v runs ONE test per process - a riscv-test is a flat binary at
# address 0 with nothing in it that resets the machine, so two tests in one
# simulation would mean the second inheriting the first's registers and data -
# which is why the suite loop, and therefore the tally, lives here rather than in
# the testbench.
#
# The suite is compiled and simulated twice: once against the behavioural memories
# and once against the sky130 macros, from the same hex images, with the same
# expectations. That second run is what the memory work was for. A core that passes
# with a memory whose read data comes out when you ask for it, and fails with the
# macro that registers it, is a core that would have been taped out broken, and
# model-versus-model comparison alone (make mem-agree) cannot see it: the two
# models agree, the pipeline is what has to change.
#
# Like mem-agree, the testbench is compiled from an explicit iverilog line rather
# than being added to filelists/sim.f, because filelists describe the *design*, and
# a compliance testbench that reached into memory internals does not belong in the
# list that a synthesis script is derived from.
COMPLIANCE_TB        := tb/compliance_tb.v
COMPLIANCE_SIM       := $(BUILD)/compliance.vvp
COMPLIANCE_SIM_SRAM  := $(BUILD)/compliance-sram.vvp
COMPLIANCE_LOG       := $(BUILD)/compliance.log
COMPLIANCE_LOG_SRAM  := $(BUILD)/compliance-sram.log
COMPLIANCE_GOLDEN         := regression/golden-compliance.txt
COMPLIANCE_GOLDEN_SRAM    := regression/golden-compliance-sram.txt

$(COMPLIANCE_SIM): $(COMPLIANCE_TB) $(SIM_F) $(wildcard $(RTL_DIR)/*.v) $(wildcard $(RTL_DIR)/mem/*.v) | dirs
	$(IVERILOG) $(IV_FLAGS) -I$(RTL_DIR) -c $(SIM_F) -o $@ $(COMPLIANCE_TB) -s compliance_tb

# The tapeout configuration: macros, and the power-pin variant of the wrappers, so
# this exercises the same build lint-asic and synth-asic do.
$(COMPLIANCE_SIM_SRAM): $(COMPLIANCE_TB) $(ASIC_F) $(wildcard $(RTL_DIR)/*.v) $(wildcard $(RTL_DIR)/mem/*.v) vendor/sky130_sram_2kbyte_1rw1r_32x512_8.v | dirs
	# -D, not the +define+NAME form: iverilog reads `+define+USE_SRAM_MEMS' as a
	# file name to open, and the failure it reports is "No such file or directory"
	# for a define that looks perfectly well formed on the command line. The same
	# flag shape as the -DNODUMP above.
	$(IVERILOG) $(IV_FLAGS) -DUSE_SRAM_MEMS -DUSE_POWER_PINS \
		-I$(RTL_DIR) -c $(ASIC_F) -o $@ $(COMPLIANCE_TB) -s compliance_tb

# Run the suite into a log. $(1) binary, $(2) log, $(3) what to call it in messages.
#
# Two structural checks before anything is compared: one verdict line per test (a
# test whose process died mid-print would otherwise vanish from the transcript and
# the run would look shorter but clean), and a tally line at the end.
define compliance_run
	@rm -f $(2); \
	for t in $(RVTEST_TESTS); do \
		$(VVP) $(1) +TEST=$$t \
			+IMEM=$(TEST_BUILD)/$$t.imem.hex \
			+DMEM=$(TEST_BUILD)/$$t.dmem.hex | $(FILTER) >> $(2) \
			|| { echo "GATE FAIL: $(3): $$t did not finish"; exit 1; }; \
	done
	@n=$$(grep -cE '^(PASS|FAIL) ' $(2) 2>/dev/null || true); \
	if test "$$n" != "$(words $(RVTEST_TESTS))"; then \
		echo "GATE FAIL: $(3) produced $$n verdicts for $(words $(RVTEST_TESTS)) tests"; \
		exit 1; \
	fi
	@p=$$(grep -c '^PASS ' $(2)); f=$$(grep -c '^FAIL ' $(2) || true); \
	 echo "$$p PASSED / $$f FAILED" >> $(2)
endef

# Compare against the recorded transcript, refusing to compare against nothing.
# $(1) log, $(2) golden, $(3) label, $(4) promote target name
define compliance_gate
	@if ! grep -qE '^[0-9]+ PASSED / [0-9]+ FAILED$$' $(1); then \
		echo "GATE FAIL: no tally in $(1) - the suite did not run."; tail -3 $(1); exit 1; \
	fi
	@if [ ! -f $(2) ]; then \
		echo "GATE FAIL: no $(2). Run 'make $(4)' once you intend to change behaviour."; exit 1; \
	fi
	@if diff -u $(2) $(1); then \
		echo "GATE PASS: $(3) matches $(2)"; \
	else \
		echo "GATE FAIL: $(3) differs from $(2)"; exit 1; \
	fi
endef

# Both skip, rather than fail, when the riscv toolchain is missing, the same way
# synth skips for yosys: the gate is for the machine that can run it, and a build
# box without binutils should still be able to lint and simulate.
check-compliance: | dirs
	@if ! command -v $(RISCV_CC) >/dev/null 2>&1; then \
		echo "compliance SKIPPED: $(RISCV_CC) not installed"; exit 0; fi
	@$(MAKE) --no-print-directory test-images > /dev/null
	@$(MAKE) --no-print-directory $(COMPLIANCE_SIM) > /dev/null
	$(call compliance_run,$(COMPLIANCE_SIM),$(COMPLIANCE_LOG),compliance)
	$(call compliance_gate,$(COMPLIANCE_LOG),$(COMPLIANCE_GOLDEN),compliance,compliance-baseline)

check-compliance-sram: | dirs
	@if ! command -v $(RISCV_CC) >/dev/null 2>&1; then \
		echo "compliance-sram SKIPPED: $(RISCV_CC) not installed"; exit 0; fi
	@$(MAKE) --no-print-directory test-images > /dev/null
	@$(MAKE) --no-print-directory $(COMPLIANCE_SIM_SRAM) > /dev/null
	$(call compliance_run,$(COMPLIANCE_SIM_SRAM),$(COMPLIANCE_LOG_SRAM),compliance-sram)
	$(call compliance_gate,$(COMPLIANCE_LOG_SRAM),$(COMPLIANCE_GOLDEN_SRAM),compliance-sram,compliance-sram-baseline)

# Promoting a compliance transcript is only allowed from a run with nothing failing
# in it, behavioural or macro: recording "39 PASSED / 1 FAILED" as the expectation
# is how a broken core becomes the reference.
compliance: check-compliance
compliance-sram: check-compliance-sram

compliance-baseline: | dirs
	@if ! command -v $(RISCV_CC) >/dev/null 2>&1; then \
		echo "compliance-baseline SKIPPED: $(RISCV_CC) not installed"; exit 1; fi
	@$(MAKE) --no-print-directory test-images > /dev/null
	@$(MAKE) --no-print-directory $(COMPLIANCE_SIM) > /dev/null
	$(call compliance_run,$(COMPLIANCE_SIM),$(COMPLIANCE_LOG),compliance)
	@if grep -q '^FAIL ' $(COMPLIANCE_LOG); then \
		echo "REFUSING to record a failing compliance run as the golden:"; \
		grep '^FAIL ' $(COMPLIANCE_LOG); exit 1; fi
	@mkdir -p $(dir $(COMPLIANCE_GOLDEN))
	@cp $(COMPLIANCE_LOG) $(COMPLIANCE_GOLDEN)
	@echo "Compliance golden transcript recorded at $(COMPLIANCE_GOLDEN)"

compliance-sram-baseline: | dirs
	@if ! command -v $(RISCV_CC) >/dev/null 2>&1; then \
		echo "compliance-sram-baseline SKIPPED: $(RISCV_CC) not installed"; exit 1; fi
	@$(MAKE) --no-print-directory test-images > /dev/null
	@$(MAKE) --no-print-directory $(COMPLIANCE_SIM_SRAM) > /dev/null
	$(call compliance_run,$(COMPLIANCE_SIM_SRAM),$(COMPLIANCE_LOG_SRAM),compliance-sram)
	@if grep -q '^FAIL ' $(COMPLIANCE_LOG_SRAM); then \
		echo "REFUSING to record a failing compliance run as the golden:"; \
		grep '^FAIL ' $(COMPLIANCE_LOG_SRAM); exit 1; fi
	@mkdir -p $(dir $(COMPLIANCE_GOLDEN_SRAM))
	@cp $(COMPLIANCE_LOG_SRAM) $(COMPLIANCE_GOLDEN_SRAM)
	@echo "Compliance (sky130 macros) golden transcript recorded at $(COMPLIANCE_GOLDEN_SRAM)"


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
# `check -assert` after `synth`, in both builds.
#
# The pass looks for exactly three things - combinatorial loops, a wire with two
# conflicting drivers, and a used wire with no driver - and -assert turns any of them
# into a script error, so the failure is non-zero exit status rather than a line in a
# log nobody re-reads. None of the three shows up as a wrong simulation value in a
# way that is easy to attribute: an undriven net reads as a constant zero, a
# multi-driven wire reads as X, and a combinational loop is a simulation artefact
# that synthesis resolves in whichever order it happens to traverse things. So this
# is the only gate that would notice an unconnected port added to a module, which is
# the sort of edit every one of the refactors in this repo's history makes plausible.
#
# The plan asked for `check -all`. Yosys 0.23 has no -all; the plain form already
# covers the same three problems, so -assert is what makes it a gate here. A newer
# yosys accepts -all for the extra categories (-mapped, -noinit, -initdrv), and this
# line is where to add them once CI ships that version.
#
# Do not delete the problems count in the summary below on the grounds that -assert
# already fails the script. It does not always: an experiment that left comp32's `eq`
# undriven made yosys report "Found and reported 1 problems." part-way through
# synthesis, and the appended `check -assert` on the finished cell netlist then
# reported 0 and exited 0 - the problem had been optimised into a constant by then.
# Summing every problems count in the log catches the mid-run report, which is the
# one that still says what was wrong.
$(BUILD)/synth-sim.ys: $(BUILD)/srcs-sim.txt | dirs
	@{ while read -r f; do echo "read_verilog -I$(RTL_DIR) $$f"; done < $<; \
	   echo "synth -top rv32i_core"; echo "check -assert"; } > $@

$(BUILD)/synth-asic.ys: $(BUILD)/srcs-asic.txt | dirs
	@{ while read -r f; do \
	       echo "read_verilog -I$(RTL_DIR) -DUSE_SRAM_MEMS -DUSE_POWER_PINS $$f"; \
	   done < $<; echo "synth -top rv32i_core"; echo "check -assert"; } > $@

# Run yosys over a generated script and gate on inferred latches.
# $(1) = yosys script, $(2) = log suffix, $(3) = build name
 define yosys_synth
	@if ! command -v $(YOSYS) >/dev/null 2>&1; then \
		echo "synth$(2) SKIPPED: $(YOSYS) not installed"; exit 0; \
	fi
	@echo "== synth: $(3) build (elaboration + cell stats) =="
	@$(YOSYS) -s $(1) > $(BUILD)/synth$(2).log 2>&1 || { \
		echo "yosys exited non-zero; the relevant lines are:"; \
		grep -nE "ERROR:|Found and reported [1-9]|latch inferred for" \
			$(BUILD)/synth$(2).log | tail -10; exit 1; }
	@awk '/^ +Number of cells:/{c+=$$4} /DLATCH/{l+=$$2} /^[ ]+[^ ]*([Dd][Ff][Ff])[^ ]* +[0-9]+/{d+=$$2} /Found and reported/{p+=$$4} END{printf "  total cells : %d\n  total flops : %d\n  latches     : %d\n  check problems (any pass): %d\n", c, d, l, p}' $(BUILD)/synth$(2).log
	@if test "$$(awk '/Found and reported/{p+=$$4} END{print p+0}' $(BUILD)/synth$(2).log)" != "0"; then \
		echo "GATE FAIL: yosys check found structural problems in the $(3) build"; \
		grep -A4 "Executing CHECK" $(BUILD)/synth$(2).log | tail -20; exit 1; fi
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
