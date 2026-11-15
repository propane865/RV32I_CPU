# `tb/env` — the test environment for `make compliance`

Two files, both small, both specific to *this* core:

| File | What it is |
| --- | --- |
| `riscv_test.h` | Replacement for upstream riscv-tests' `env/p`: the nine macros a test body needs, and the exit protocol. The reasoning is in its own header comment. |
| `link.ld` | The memory map: `.text` at 0, everything else at or above `0x1000`, stack growing down from the top of data memory. |

They exist because the upstream environment cannot be used here. `env/p` installs
its trap vector with `csrw mtvec` and finishes a test by storing to a `tohost`
symbol that only means something to a simulator that watches that address; this
core has no CSR block and no such device, so the tests do not misbehave against it,
they fail to assemble. `vendor/riscv-tests/UPSTREAM.md` records that the `env/`
submodule is deliberately not vendored, and why.

## How a test gets run

```sh
make test-images            # assemble + link + convert all 40, into build/tests
make compliance             # same suite against the behavioural memories
make compliance-sram        # same suite, same images, against the sky130 macros
```

Each test is built with

```sh
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -static \
    -O2 -mno-relax -Itb/env -Ivendor/riscv-tests/isa/macros/scalar \
    -Ttb/env/link.ld -o build/tests/rv32ui-p-<name>.riscv \
    vendor/riscv-tests/isa/rv32ui/<name>.S
```

`-mno-relax` because `gp` is `TESTNUM` here: linker relaxation may rewrite
`lui/addi` pairs into gp-relative small-data accesses, which would give the linker
a register the tests use to report their own test numbers.

`tb/elf2hex.py` then turns the ELF into two full-memory hex images and refuses the
build if the program does not fit the map - which matters because the core decodes
an address from its low 13 bits, so an out-of-range address *wraps* rather than
faulting, and the build is the only place that can notice.

One test runs per `vvp` process (`tb/compliance_tb.v`), because a riscv-test is a
flat binary at address 0 with no way to reset the machine between tests. The
verdict comes from the test itself: it ends in an ECALL carrying 0 for pass or
`(testnum << 1) | 1` for fail, which reaches the testbench as the
environment-call exception this core reports. So a test that crashes is reported as
the exception it took, with the cause and the PC, rather than as a wrong value or a
timeout.

## The two tests that are not run

42 sources in `vendor/riscv-tests/isa/rv32ui`, 40 run. The exclusions live in the
Makefile as `RVTEST_SKIP`; each needs a reason here, not just a name there, because
"excluded" without a reason is how a permanent exclusion becomes invisible.

### `rv32ui-p-fence_i` — cannot be built, and has no meaning here

It is the one test in the suite that does not assemble:

```
isa/rv32ui/../rv64ui/fence_i.S:24: Error: unrecognized opcode `fence.i', extension `zifencei' required
isa/rv32ui/../rv64ui/fence_i.S:37: Error: unrecognized opcode `fence.i', extension `zifencei' required
```

(two sites: the test modifies code in two places, and both need the extension.)

That is only the surface reason. The test writes a new instruction encoding into
the memory it is executing from, executes `fence.i`, and expects the *fetch* path to
have noticed. This core has separate instruction and data memories with no path from
a store to a fetch and no `fence.i` at all (`rtl/control.v` does not decode it; the
encoding is illegal here). There is no behaviour to test, so there is nothing to
pass or fail. Excluding it states that, rather than leaving `fence.i` looking like a
bug waiting to be fixed.

### `rv32ui-p-ma_data` — tests the opposite of what this core does

The test requires a misaligned load or store to *complete*, returning and writing
the architecturally composed bytes. This core raises load-address-misaligned
(cause 4) or store-address-misaligned (cause 6) instead, which the RV32I spec
permits outright: misaligned access may be handled in hardware or by trap, and this
core has no mechanism to handle it in hardware and no handler to take the trap, so
trapping and halting is the only honest response available (rtl/trap_unit.v).

The consequence is that the test traps on its first misaligned access - run it and
this is the line:

```
FAIL rv32ui-p-ma_data | unexpected trap: cause 4 at 0x00000094
```

Reporting "40 passed, ma_data excluded" is accurate; recording the line above as the
expectation would enshrine a core doing exactly what it was designed to do as a
failure. Editing the test to expect
the trap would make it a different test, and the value of this directory is that its
bodies are byte-for-byte upstream.

What *is* covered is the behaviour itself, and more precisely than this test could:
`tb/directed_tb.v` D7 walks every offset each load and store width can name, checks
which ones trap and which are legal (byte accesses at odd addresses are legal, and a
halfword at an even address must not trap), and checks that a not-taken branch with a
misaligned offset does not trap and that a misaligned access on a flushed path does
not either.

## Adding an exclusion

Anything that fails to assemble for `-march=rv32i -mabi=ilp32`, or that requires
architecture this core does not implement (atomics, CSR, float, `fence.i`), joins
`RVTEST_SKIP` in the Makefile **with a section here**. The section has to say which
of those it is, because they are different claims: "cannot be built" says the tool
refuses, "requires architecture we do not have" says the core would have to change,
and "we chose the other legal behaviour" says a design decision is being asserted -
which is the kind of claim that should be checkable, and above each one is.
