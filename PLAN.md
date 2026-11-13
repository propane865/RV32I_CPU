# Refactoring plan — RV32I pipelined core (`verilog/` → `rtl/`)

> Status: ready for review. Scope agreed: **implement** the refactors, **fix** the latent bugs,
> keep the design **synth-clean for sky130/OpenLane**, and add **Makefile + lint + CI**, a **`rtl/`
> layout**, a **shared `defines.vh`**, and a **split of `datapath.v` into stage modules**.

## Context

The repo is a hand-written 6-stage pipelined RV32I core (IF → ID → EX1 → EX2 → MEM → WB) in
Verilog-2001, ~1,470 lines of RTL + a 327-line self-checking testbench. It targets sky130/OpenLane
(`imem_sram.v` / `dmem_sram.v` wrap `sky130_sram_2kbyte_1rw1r_32x512_8`, with `USE_POWER_PINS` guards),
and also has behavioral memory models for simulation.

Nothing is broken structurally, but the code has the classic shape of a single-pass student/course
project: one 414-line `datapath.v` that contains all pipeline registers *and* stray control logic,
duplicated decode tables, magic constants duplicated across modules, four modules crammed into
`alu.v`, two mutually-exclusive definitions of `imem`/`dmem`, and no build/lint/repo infrastructure.
Reading it also surfaced three correctness findings (see **A**) that the current structure hides.

Intended outcome: RTL that is **lint-clean, single-source-of-truth for encodings, sky130-synthesizable
and reviewable**, with the behaviour-preserving refactors proven safe by a repeatable build/test loop —
followed by two deliberately behaviour-changing bug fixes, each covered by a new directed test.

## Target layout

```
rtl/
  defines.vh            # NEW: every encoding, exactly once
  rv32i_core.v          # top
  datapath.v            # 414 L -> ~150 L: only wires + instantiations
  pc.v decoder.v control.v imm_gen.v regfile.v
  alu.v  ks32.v  shifter.v  comp32.v        # alu.v split, one module per file
  hazard_unit.v forwarding_unit.v branch_unit.v   # branch_unit is NEW
  pipe_if_id.v pipe_id_ex.v pipe_ex1_ex2.v pipe_ex_mem.v pipe_mem_wb.v   # NEW
  mem/
    imem.v            dmem.v            # impl-selectable wrappers (single module name)
    imem_behav.v      dmem_behav.v      # sim models, translate_off-guarded init
    imem_sram.v       dmem_sram.v       # sky130 macro wrappers
vendor/
  sky130_sram_2kbyte_1rw1r_32x512_8.v   # NEW stub - the ASIC path cannot lint without it
tb/
  core_tb.v
filelists/sim.f  filelists/asic.f
Makefile  .github/workflows/signoff.yml
```

`verilog/` -> `rtl/` and `test/` -> `tb/` are `git mv` (one commit, no content change) so `git log
--follow` survives.

## Approach

Eight independently-shippable phases, ordered so each is verifiable before the next:

0. **Lock behaviour first** — fix only what blocks compilation, land the repo layout + tooling, capture
   a golden PASS/FAIL transcript. Nothing after this is allowed to change that transcript except the
   two explicitly-flagged bug-fix phases.
1. **Single source of truth for encodings** — one `defines.vh` included by `control.v`, `alu.v`,
   `imm_gen.v`, `datapath.v`.
2. **De-duplicate the control unit** — collapse the identical R-type/I-type decode arms.
3. **Decompose `datapath.v`** — one module per pipeline register; control logic out of the datapath
   into `branch_unit` / `hazard_unit`.
4. **ALU / comparator / adder cleanup** — one module per file; give the ALU an honest interface (one
   `invert` bit currently carries three unrelated meanings).
5. **Memory abstraction** — one module name per memory, sim and sky130 impls selected by define, with
   *identical* sub-word semantics.
6. **Dead code + naming sweep** — reach `verilator --lint-only -Wall` clean, including the ASIC
   filelist.
7. **Bug fixes** (behaviour-changing, each its own commit + new directed tests): signed branch
   comparison, then behavioral/SRAM memory agreement.

### Key design sketches

**`rtl/defines.vh`** — kills findings B6–B8 in one stroke:

```verilog
`define OP        7'b0110011
`define ALU_ADD   3'd3
`define IMM_I     3'd0
`define WB_ALU    2'd0
`define WB_MEM    2'd1
`define WB_PC4    2'd2
`define MEM_B     2'd0
`define MEM_H     2'd1
`define MEM_W     2'd2   // also the reset/bubble value for mem_width
`define FWD_NONE  2'd0
`define FWD_MEMWB 2'd1
`define FWD_EXMEM 2'd2
`define FWD_EX1   2'd3
```

**Pipeline register template** — removes the 25-line hand-written reset lists (`datapath.v:117-158`,
`222-253`, `302-311`, `344-349`) and makes "which fields a bubble clears" a single visible constant:

```verilog
localparam [W-1:0] BUBBLE = { `REG_W_ENA(1'b0), `MEM_W_ENA(1'b0), `MEM_WIDTH(`MEM_W), ... };
always @(posedge clk) q <= (rst || flush) ? BUBBLE : d;
```

Ports stay named (readable diffs); only the storage inside is packed.

**ALU interface** — replace the overloaded bits with the op enum deciding everything internally:

```verilog
// before: shifter sh(a, b[4:0], op[0], invert, a_shift);  <- positional, 3 meanings on 1 bit
// after:  named ports, alu_op selects {sub, shift_dir, shift_arith, cmp_sgn} internally
```

## Files to modify

| File | Change |
|---|---|
| `Makefile`, `filelists/sim.f`, `filelists/asic.f`, `.gitignore`, `.github/workflows/signoff.yml` | **new** — `make lint` / `make sim` / `make lint-asic` / `make synth` |
| `vendor/sky130_sram_2kbyte_1rw1r_32x512_8.v` | **new** — behavioural macro stub; the ASIC filelist cannot lint today because no model is in-tree |
| `rtl/defines.vh` | **new** — every encoding, defined once (incl. the `IMM_*` set currently duplicated in `control.v` **and** `imm_gen.v`) |
| `verilog/` → `rtl/`, `test/` → `tb/` | `git mv`, plus commit the pending `verilog/test/core_tb.v` → `tb/core_tb.v` move |
| `rtl/datapath.v` (414 L) | pipeline regs extracted; branch decode + load-detect + wb mux moved out; dead wires removed |
| `rtl/control.v` (362 L) | shared funct3 decode; `defines.vh`; delete redundant `alu_invert = 0`; explicit illegal-instruction default |
| `rtl/alu.v` (237 L) | split into `alu.v` / `ks32.v` / `shifter.v` / `comp32.v`; fix `eq` double declaration; drop dead `gr`/`le` + unreachable `3'b111` arm; named ports |
| `rtl/pipe_{if_id,id_ex,ex1_ex2,ex_mem,mem_wb}.v`, `rtl/branch_unit.v` | **new** |
| `rtl/hazard_unit.v` | absorb the load-detect expression currently inline at `datapath.v:382`; rename port `pc_src` → `pc_redirect` |
| `rtl/mem/*` | rename macro wrappers; one `imem`/`dmem` module name selected by define; align sub-word semantics |
| `rtl/pc.v` `regfile.v` `decoder.v` `imm_gen.v` `rv32i_core.v` | dead ports, write-through de-dup, `translate_off` init, stale header tables removed |
| `tb/core_tb.v` | register-file reset between tests, scoped `$dumpvars`, signed-branch + unaligned-access tests |

## Reuse (existing code to build on, not reimplement)

- `ks32` (`verilog/alu.v:64`) — already a working 32-bit Kogge-Stone adder; reuse for ALU/comp32 and
  keep it *only* where carry-out or timing demands it.
- `comp32` (`verilog/alu.v:200`) — already yields `gt/lt/eq` for both signed and unsigned via `u`;
  the branch path only needs the correct `u`, not a second comparator.
- `shifter` (`verilog/alu.v:160`) — already does left / right-logical / right-arithmetic; the
  barrel-shift structure should be kept, only the `arith`/`dir` argument plumbing renamed.
- `forwarding_unit` + `hazard_unit` already exist as standalone modules — the datapath refactor should
  move logic *into* them rather than adding new units where possible.
- Testbench helpers `check_reg` / `check_mem_word` / `clear_mem` / `release_reset`
  (`test/core_tb.v:26-83`) are already a good harness — extend, don't rewrite.

## Findings in detail

### A. Correctness / latent-bug findings (found by reading; to be confirmed by the Phase 0 baseline run)

1. **Signed branches compare unsigned.** `datapath.v:192` drives `BCOMP.u = ~ID_EX_alu_sgn`, but
   `control.v` never sets `alu_sgn` in the `BRANCH` arm (default `0`) ⇒ `u = 1` = **unsigned**.
   Additionally `ex_condition_met_r` maps `3'b100` (BLT) and `3'b110` (BLTU) to the *same* term
   `EX1_EX2_lt`, and `3'b101`/`3'b111` to the same `gt|eq`. Signedness information is therefore lost
   entirely: BLT ≡ BLTU and BGE ≡ BGEU. `test/core_tb.v` `test_branches` expects `BLT x6(-1), x1(1)`
   to be taken (signed) — unsigned `0xFFFFFFFF < 1` is false, so that check should fail.
   *Fix belongs to the same refactor as moving branch decode out of the datapath.*
2. **`alu` re-declares port `eq` as a wire** — `alu.v:23` declares `input gt, lt, eq` and `alu.v:25`
   declares `wire gr, le, eq;`. Illegal double declaration; most tools error out. `gr`/`le` are dead.
3. **Behavioral `dmem` ≠ SRAM `dmem`.** `dmem.v` ignores `addr[1:0]` for sub-word access (uses
   `addr[11:0]`, `+1`, `+2`, `+3`), while `dmem_sram.v` builds `wmask` from `byte_off = addr[1:0]`.
   Unaligned SB/SH/LB/LH behave differently in sim vs the ASIC build.
4. **`rst` does not clear the register file** (`regfile.v` only zeroes via `initial`), and
   `clear_mem` in the TB does not clear `RF.regs` ⇒ tests leak state across test boundaries.
5. **Unreachable ALU arm**: `ALU_EQ` (`3'b111`) is `localparam`-declared but never driven by `control.v`
   ⇒ `logic_out = {31'b0, eq ^ invert}` is dead hardware. `3'b100`/`3'b101` both select `a_shift`.

### B. Structural duplication

6. `control.v` `OP` and `OP_IMM` arms repeat the *entire* funct3 decode (XOR/OR/AND/SLL/SRL/SRA/SLT/
   SLTU + the `funct7[5]` sub-decode) — ~120 duplicated lines.
7. `IMM_I/S/B/U/J` encodings are `localparam`-ed **twice**, in `control.v` and `imm_gen.v`, and must be
   kept in sync by hand.
8. ALU-op encodings live in `control.v` (`localparam ALU_ADD = 3'b011`) and again as raw literals in
   `alu.v` (`3'b011: logic_out = a_b_add`). Same for `wb_sel`, `alu_src_a`, `mem_width`, branch-cond.
9. Write-through read logic is duplicated verbatim for `r_data1`/`r_data2` (`regfile.v:26-27`).
10. `forwarding_unit`'s 3-deep mux chain is written twice (`forward_a` / `forward_b`), and the matching
    datapath muxes `fwd_rs1`/`fwd_rs2` are a *third* copy of the same 2-bit encoding.

### C. Cohesion — control logic stranded in `datapath.v`

11. Load-detect expression inline at `datapath.v:382` (`ID_EX_reg_w_ena && !ID_EX_mem_w_ena && wb_sel==2'b01`).
12. Branch-condition decode + `pc_src` + the two target adders inline at `datapath.v:255-292`.
13. Writeback mux inline at `datapath.v:369-377` (`wb_data_r` + pointless `assign wb_data = wb_data_r`).
14. `hazard_unit` port `pc_src` is really "branch/jump taken" — misleading name.

### D. Dead code / synthesis waste

15. `pc_plus4` (`pc.v:23`) is wired in `datapath.v:38` and never used — the datapath re-derives
    `EX1_EX2_pc + 32'h4` at line 292 instead.
16. `ex_alu_cout`, `jalr_cout`, `branch_cout` are driven and never read.
17. `id_alu_dir` (`datapath.v:73`) is declared but driven by nothing — undriven net.
18. `EX1_EX2_rs1` / `EX1_EX2_rs2` are registered and never read downstream ⇒ two wasted flops.
19. `imem_sram.v`: `dout0_lo`/`dout0_hi` unused; `instr_lo`/`instr_hi` used *before* declaration
    (implicit-net inference); `PWR_PINS` macro defined but never used (both `_sram` files).
20. Two full 32-bit Kogge-Stone adders instantiated in the branch/jump path where only the sum is used.

### E. Readability / convention

21. `alu` takes `invert` which simultaneously means "bitwise-NOT for SUB", "shift direction" (via
    positional `shifter sh(a, b[4:0], op[0], invert, a_shift)`) and "result polarity for CMP" —
    three unrelated meanings on one bit, connected positionally.
22. Naming is inconsistent: `IF_ID_pc` / `ID_EX_rs1_data` / `EX1_EX2_*` / `EX_MEM_*` / `MEM_WB_*`, plus
    a `_r` suffix on two combinational regs and not the others.
23. Hand-maintained ASCII port tables at the top of almost every file have already drifted:
    `dmem.v:1` says "Instruction Memory" (copy-paste), `regfile.v:8-10` labels `rs2` as
    "Source Register 1 Address", `dmem.v:8` misaligned.
24. No `default:` in the `control.v` funct3 sub-cases (harmless today because defaults are pre-assigned,
    but it hides illegal-instruction handling).

### F. Repo / tooling

25. No `Makefile`, no filelist, no CI, no `.gitignore`, no README.
26. `verilog/test/core_tb.v` is deleted in the working tree and `test/core_tb.v` is untracked —
    an unfinished `git mv` that currently makes a clean checkout build with *no* testbench.
27. `imem.v`/`dmem.v` and `imem_sram.v`/`dmem_sram.v` define the **same module names** — a single
    compile of all files in the tree is a duplicate-module error. This is why a filelist is needed.
28. TB writes `$dumpfile("verification/core_tb.vcd")` but no `verification/` dir exists, and
    `$dumpvars(0, core_tb)` dumps the whole hierarchy including 4 KB of memory.

## Steps

- [x] **Phase 0 — make behaviour lockable**
  - [ ] Install tooling: `apt-get install -y iverilog verilator` (Debian bookworm has both; network verified)
  - [ ] Fix **only** the compile blocker: `alu.v:25` `wire gr, le, eq;` re-declares port `eq` → delete the
        declaration (and the dead `gr`/`le`). Nothing else changes in this step.
  - [ ] `git mv verilog rtl && git mv test tb && git add -A` (lands the unfinished `core_tb.v` move)
  - [ ] Add `filelists/sim.f` (behavioral mems) + `filelists/asic.f` (SRAM mems + `vendor/` stub) so the two
        memory impls are never compiled together — they define the **same module names** today
  - [ ] Add `vendor/sky130_sram_2kbyte_1rw1r_32x512_8.v` stub (ports: `clk0/csb0/web0/wmask0/addr0/din0/dout0`
        `clk1/csb1/addr1/dout1`, plus `vccd1/vssd1` under `USE_POWER_PINS`)
  - [ ] Add `Makefile` (`lint`, `lint-asic`, `sim`, `waves`, `synth`) + `.gitignore` + CI workflow
  - [ ] **Record `build/baseline.log`** — the exact PASS/FAIL transcript. Expect `test_branches`
        "BLT signed" to FAIL (finding A1); that failure is the acceptance target for Phase 7a.
- [x] **Phase 1 — encodings**: create `rtl/defines.vh`; replace literals in `control.v`, `alu.v`,
      `imm_gen.v`, `datapath.v`; delete the duplicate `IMM_*` localparams. Pure substitution.
- [x] **Phase 2 — control unit**: merge the `OP`/`OP_IMM` funct3 decode into one shared block differing
      only by `alu_src`; delete redundant `alu_invert = 0`; add explicit illegal-opcode/funct3 default.
- [x] **Phase 3 — datapath decomposition**: extract the five `pipe_*` modules (packed vector + one
      `BUBBLE` localparam each); move branch condition + `pc_src` + the two target adders
      (`datapath.v:255-292`) into `branch_unit.v`; move load-detect into `hazard_unit.v`; drop the
      `wb_data_r` → `wb_data` indirection; `datapath.v` ends up wires + instantiations only.
- [x] **Phase 4 — ALU cluster**: split `alu.v` into four files; remove the unreachable `3'b111` arm;
      replace the overloaded `invert`/`pass`/`op[0]` coupling with an internal decode of `alu_op`;
      named port connections everywhere.
- [x] **Phase 5 — memories**: `rtl/mem/` with `imem`/`dmem` wrappers selecting `*_behav` vs `*_sram` via
      one define; `translate_off`-guard every `initial` in the behav models; document which impl is golden.
- [x] **Phase 6 — dead code & naming**: remove `pc_plus4`, `ex_alu_cout`, `jalr_cout`, `branch_cout`,
      `id_alu_dir`, `EX1_EX2_rs1`, `EX1_EX2_rs2`, `dout0_lo/hi`, `cs_lo/hi`, `PWR_PINS`; rename
      `hazard_unit.pc_src` → `pc_redirect`; consistent lowercase `ifid_`/`idex_`/`ex1ex2_`/`exmem_`/`memwb_`
      prefixes; delete the drifted ASCII port tables. Gate: `-Wall` clean on **both** filelists.
- [ ] **Phase 7a — bug: signed branches** (behaviour-changing, own commit). Add a single
      "comparison signedness" control (`cmp_sgn`) asserted by `control.v` for SLT **and** for
      `funct3[2] == 0` branches, drive `BCOMP.u = ~cmp_sgn`, and let `branch_unit` use it so BLT ≠ BLTU
      and BGE ≠ BGEU. Add directed tests: `BLT`/`BGE` with negative operands, and a case where signed
      and unsigned verdicts differ.
- [ ] **Phase 7b — bug: memory agreement** (behaviour-changing, own commit). Make the two models agree
      on unaligned sub-word access (byte-lane/wmask semantics, as `dmem_sram.v` does). Add an unaligned
      `SB` then `LW` test and a word-store across a 4095/0 boundary case; pin the chosen golden
      behaviour in a comment.
- [ ] **Phase 8 — optional, only if time allows**: fold the duplicated `forward_a`/`forward_b` decode
      in `forwarding_unit.v` into one reusable function, and share it with the `fwd_rs1`/`fwd_rs2`
      muxes in the datapath.

## Verification

1. **Golden transcript diff.** `make sim > build/now.log; diff build/baseline.log build/now.log` must be
   empty. The TB is self-checking and prints deterministic `PASS`/`FAIL` lines, so this is the
   behaviour-preservation proof for Phases 1–6. (Register-file state is not reset by `rst` — finding
   A4 — so the TB must zero `RF.regs` between tests *before* this diff is trusted as stable; that TB
   change lands in Phase 0/6 and is itself re-baselined.)
2. **Lint gates**: `make lint` and `make lint-asic` (`+define+USE_POWER_PINS` + `vendor/` stub) both
   `-Wall` clean from Phase 6 onward; CI runs both filelists so the ASIC path can't silently rot.
3. **Synth gate (sky130 cleanliness)**: `make synth` = `yosys -p "read_verilog -Irtl -f filelists/sim.f; synth; stat"`.
   Must complete without unsupported constructs, and total `$_DFF*_` count must not increase across
   Phases 3–6 (it should drop by the flops removed in Phase 6). No latches inferred.
4. **New directed tests** land with Phase 7a (signed vs unsigned branch verdicts) and Phase 7b
   (unaligned `SB`/`LW`, boundary-crossing store); each must FAIL before its fix and PASS after.
5. **Fresh-clone check**: `git clone` → `make sim` with no missing-directory or duplicate-module errors
   (drives findings F26/F27), and `make waves` writes to a gitignored `build/`.

## Decisions & risks

- **Decided**: implement the refactor; fix the bugs (after a baseline); keep sky130 synth-cleanliness as
  a hard gate; add tooling, `rtl/` layout, `defines.vh`, and split `datapath.v`.
- **Phase 0 may surface a hard compile error** at `alu.v:25`. If a tool accepts the duplicate `eq`
  declaration, the fix is still made — it is a shadowing hazard either way.
- **Baseline may be red.** If `test_branches` fails as predicted, that is the expected starting state,
  not a regression; the diff-based gate is against the recorded baseline, not against "all green".
- **`ks32` is kept deliberately.** The branch/JALR target adders are timing choices for the ASIC path,
  so they are *not* replaced with `+`; only their unused `cout` outputs are tidied.
- **SRAM macro read is clockless** (`clk1(1'b0)` in `imem_sram.v`), so the fetch path is
  PC → SRAM → IF/ID combinationally. Out of scope to change, but worth a comment so nobody assumes the
  SRAM build is pipelined identically to the behavioural model.
- **Register file is 32×32 flops**, not a macro. Left as-is; noted as a follow-up if area matters.
