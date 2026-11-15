# riscv-tests, vendored

Upstream: <https://github.com/riscv-software-src/riscv-tests>
Pinned commit: `3df703cd52d5f0d8224e3c50bf03c6cb70efff98` (`master`)
Fetched: 2026-11-15, `git clone --depth 1`, files copied out and this directory
committed in place of a submodule.
Licence: BSD-3-Clause, upstream `LICENSE` preserved verbatim alongside this file.

## What is here, and why only that

| Path | Files | Why |
| --- | --- | --- |
| `isa/rv32ui/*.S` | 42 | The RV32I user-mode suite. This is the test list `make compliance` runs. |
| `isa/rv64ui/*.S` | 42 | Every rv32ui test is three lines that `#include` its rv64ui twin, which holds the actual body: `isa/rv32ui/add.S` redefines `RVTEST_RV64U` to `RVTEST_RV32U` and includes `../rv64ui/add.S`. The 42 copied here are exactly the ones named by an `#include` in `isa/rv32ui`; upstream's other 12 rv64ui tests (`ld`, `sd`, `addiw`, `slli`-64 and friends) are RV64-only instructions and are not included by anything here. |
| `isa/macros/scalar/test_macros.h` | 1 | The `TEST_*` macros the bodies are written in. |
| `LICENSE` | 1 | Upstream licence text, unmodified. |

Nothing else from the repository is copied: no other test class (`rv32ua`,
`rv32um`, `rv32mi`, `rv64*`, …), no upstream `Makefile`, no `bench`, no `mt` or
`sv` environments. The core implements RV32I only, so the rest could only ever be
dead weight that still has to be audited against the licence on every review.

**The test bodies, the macros and the licence are byte-for-byte upstream.** No
test has been edited to make it pass. That is the point of the directory: a green
`make compliance` means the upstream RV32I suite passed, not a modified version of
it.

## What is deliberately missing: `env/`

Upstream keeps its test environments in a git submodule at `env/`
(`<https://github.com/riscv/riscv-test-env.git>`, recorded at
`6de71edb142be36319e380ce782c3d1830c65d68` by the pinned commit's `.gitmodules`).
It is not vendored, and `make compliance` does not need it.

The programmatic environment there, `env/p`, cannot be used with this core, and
not for a reason that patching would fix: it installs its trap vector with
`csrw mtvec`, it measures with `rdcycle`, and it ends a test by storing to a
`tohost` symbol that only exists because the simulator agrees to watch that
address. This core has no CSR block at all (plans/rv32i-compliance.md §1.2), so
those tests would fail to assemble against `env/p` — the error would come from the
first `csrw`, before any question about the core had been raised.

`tb/env/riscv_test.h` is the replacement, and it defines the nine
environment-provided names the suite actually references (grep over the 42 bodies
and `test_macros.h` says nine: `RVTEST_RV32U`, `RVTEST_RV64U`,
`RVTEST_CODE_BEGIN`, `RVTEST_CODE_END`, `RVTEST_DATA_BEGIN`, `RVTEST_DATA_END`,
`TESTNUM`, `RVTEST_PASS`, `RVTEST_FAIL`). Its exit protocol is upstream master's,
with the `tohost` store replaced by the ECALL that upstream also uses: exit code
0 for pass, `(testnum << 1) | 1` for fail. `tb/env/link.ld` is the memory map.
Both files explain their own choices where they were made.

## Re-fetching

```sh
git clone --depth 1 https://github.com/riscv-software-src/riscv-tests /tmp/rt
cd /tmp/rt && git rev-parse HEAD          # must match the pinned commit above
DEST=/workspace/vendor/riscv-tests
mkdir -p $DEST/isa/rv32ui $DEST/isa/rv64ui $DEST/isa/macros/scalar
cp isa/rv32ui/*.S                $DEST/isa/rv32ui/
# the rv64ui twins are named by the rv32ui includes; do not copy the rest
grep -h 'include "\.\./rv64ui/' isa/rv32ui/*.S | sed 's|.*/||;s/"//' | sort -u |
  while read -r f; do cp isa/rv64ui/$f $DEST/isa/rv64ui/; done
cp isa/macros/scalar/test_macros.h $DEST/isa/macros/scalar/
cp LICENSE $DEST/
```

Move to a new upstream commit only with `git diff` reviewed: a changed test body
changes what a green compliance run claims, and `regression/golden-compliance.txt`
is the record of what the old commit used to mean.
