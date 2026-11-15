# See LICENSE for license details.

// ============================================================================
// Test environment for the rv32ui compliance suite on this core.
//
// This replaces upstream riscv-tests' `env/p`. It is not that file with pieces
// taken out, because the pieces taken out are not incidental: the stock
// programmatic env installs a trap vector with `csrw mtvec`, counts cycles with
// `rdcycle`, and ends the test by writing a `tohost` symbol through a device the
// simulator happens to model. This core has no CSR block at all (plans/
// rv32i-compliance.md §1.2), so a test assembled against `env/p` cannot run here
// even in principle - the assembly would fail on the first `csrw`, long before
// anything about the core came into question.
//
// What the test bodies actually need from an environment is much smaller than
// what `env/p` provides, and grep says so: across all 42 rv32ui tests and
// test_macros.h, the environment-provided names used are RVTEST_RV32U,
// RVTEST_RV64U, RVTEST_CODE_BEGIN, RVTEST_CODE_END, RVTEST_DATA_BEGIN,
// RVTEST_DATA_END, TESTNUM, RVTEST_PASS and RVTEST_FAIL. Nothing else. So this
// file is those nine, and each one says what it does.
//
// Exit protocol: unchanged from upstream master, and this is the part that is
// load-bearing rather than cosmetic. A test finishes with
//
//     PASS:  fence; li a7, 93; li a0, 0;        ecall
//     FAIL:  fence; a0 = (TESTNUM << 1) | 1; li a7, 93; ecall
//
// i.e. the ECALL carries the verdict in a0, which is upstream's convention
// translated out of the `tohost` store. tb/compliance_tb.v is the simulator on
// the other side of that ECALL: it stops on the exception this core reports for
// it, reads a0, and calls the test passed only when a0 is 0. Two consequences
// worth stating plainly. The first is that `make compliance` and the ECALL path
// check each other - if ECALL did not reach the exception report, every test
// would time out rather than quietly pass. The second is that a test which
// *crashes* is reported as what it is: a trap with some other cause, with the
// PC it happened at, not as a timeout.
//
// The `fence` before the ECALL is upstream's, and it is kept even though this
// core cannot reorder anything: FENCE is a legal instruction that must decode as
// a no-op (rtl/control.v), so keeping it costs one instruction and buys a
// standing check on that decode in all 40 tests.
// ============================================================================

#ifndef _RV32I_COMPLIANCE_RISCV_TEST_H
#define _RV32I_COMPLIANCE_RISCV_TEST_H

// Each definition is guarded separately, not by the file guard above, and the
// reason is the shape of the rv32ui tests: isa/rv32ui/add.S is three lines that
// include this file, then `#undef RVTEST_RV64U` and `#define RVTEST_RV64U
// RVTEST_RV32U`, then include isa/rv64ui/add.S - which includes this file again.
// Without the per-macro guards the second include would put RVTEST_RV64U back,
// the wrapper's redefinition would be silently undone, and every rv32ui test
// would assemble as its rv64ui twin.

// ---------------------------------------------------------------------------
// RVTEST_ISA: documentation only, as upstream. The ISA this suite is built for
// is fixed by the compiler flags (-march=rv32i -mabi=ilp32), not by the test.
// ---------------------------------------------------------------------------
#define RVTEST_ISA(_ISA)

// ---------------------------------------------------------------------------
// TESTNUM: the register holding the number of the test currently running, which
// is what a failure reports. gp (x3) is upstream's choice; the macros in
// test_macros.h use x1 and x5..x31 as scratch and leave x3 alone, and we build
// with -mno-relax so that the linker cannot turn gp into the base of a
// small-data addressing mode underneath us.
// ---------------------------------------------------------------------------
#define TESTNUM gp

// ---------------------------------------------------------------------------
// RVTEST_RV32U: the test-class banner. Upstream emits the reset vector here; we
// put the whole prologue in RVTEST_CODE_BEGIN instead, because the bodies place
// these two macros adjacent with nothing between them, and one place that says
// "this is where the machine starts" beats two that each hold half of it.
//
// RVTEST_RV64U is defined as this, which is what makes a single rv64ui test body
// serve as both tests: the class macro is the only thing that differs.
// ---------------------------------------------------------------------------
#define RVTEST_RV32U                                                          \
        .p2align 2

#ifndef RVTEST_RV64U
#define RVTEST_RV64U RVTEST_RV32U
#endif

// ---------------------------------------------------------------------------
// RVTEST_CODE_BEGIN: the reset vector.
//
// The core resets every register to 0 (rtl/rf.v), so zeroing x1..x31 here is
// already true on reset. It is done anyway, and paid for in 31 instructions
// across 40 tests, because it is the property the tests rely on: they were
// written against an environment that guarantees it, and a test that reads a
// register it never wrote should fail for what it did rather than because a
// simulation happened to leave a register clear. The one register that must not
// be zeroed afterwards is TESTNUM, which the line after does set, to 0.
//
// sp is set to the top of data memory because upstream sets it and a body that
// pushed a register would otherwise write to address 0, which in this core is a
// perfectly good data-memory location - the store would succeed and corrupt
// nothing but itself, so the mistake would never surface. With sp pointing at
// real memory, a body that uses the stack simply works. tb/env/link.ld exports
// _stack_top, and tb/elf2hex.py checks the stack cannot have run into .bss.
// ---------------------------------------------------------------------------
#define RVTEST_CODE_BEGIN                                                     \
        .text;                                                                \
        .p2align 2;                                                           \
        .globl _start;                                                        \
_start:;                                                                      \
        li x1,  0; li x2,  0; li x4,  0; li x5,  0;                           \
        li x6,  0; li x7,  0; li x8,  0; li x9,  0;                           \
        li x10, 0; li x11, 0; li x12, 0; li x13, 0;                           \
        li x14, 0; li x15, 0; li x16, 0; li x17, 0;                           \
        li x18, 0; li x19, 0; li x20, 0; li x21, 0;                           \
        li x22, 0; li x23, 0; li x24, 0; li x25, 0;                           \
        li x26, 0; li x27, 0; li x28, 0; li x29, 0;                           \
        li x30, 0; li x31, 0;                                                 \
        la x2, _stack_top;                                                    \
        li TESTNUM, 0

// ---------------------------------------------------------------------------
// RVTEST_PASS / RVTEST_FAIL: the exit protocol, described at the top of the file.
//
// a7 = 93 is the Linux exit_group number, which upstream reuses as its exit-code
// selector; the value is arbitrary but it is not arbitrary *here*, and both sides
// of the protocol have to agree on it. tb/compliance_tb.v reads a7 the same way.
//
// TEST_PASSFAIL in test_macros.h emits `bne x0, TESTNUM, pass` and then both
// paths, with a semicolon after RVTEST_FAIL and none after RVTEST_PASS - so
// RVTEST_FAIL must be written to be usable with a trailing `;` and RVTEST_PASS
// to be usable with none. Neither ends in a bare label, for the same reason.
// ---------------------------------------------------------------------------
#define RVTEST_PASS                                                           \
        fence;                                                                \
        li a7, 93;                                                            \
        li a0, 0;                                                             \
        ecall

#define RVTEST_FAIL                                                           \
        fence;                                                                \
        slli a0, TESTNUM, 1;                                                  \
        ori a0, a0, 1;                                                        \
        li a7, 93;                                                            \
        ecall

// ---------------------------------------------------------------------------
// RVTEST_CODE_END / RVTEST_DATA_BEGIN / RVTEST_DATA_END.
//
// Nothing has to follow the test body: both exit paths end in an ECALL, which
// this core reports and stops on, so there is no fall-off-the-end case to
// handle. The labels are emitted because they are cheap and make a disassembly
// readable.
//
// DATA_BEGIN aligns to 4 because the data blocks declare .word objects, and the
// core raises a load-address-misaligned exception rather than quietly truncating
// (rtl/trap_unit.v) - an unaligned test datum would now be an exception, not a
// slow path.
// ---------------------------------------------------------------------------
#define RVTEST_CODE_END                                                       \
        .p2align 2;                                                           \
rvtest_code_end:

#define RVTEST_DATA_BEGIN                                                     \
        .p2align 2;                                                           \
rvtest_data_begin:

#define RVTEST_DATA_END                                                       \
rvtest_data_end:

#endif // _RV32I_COMPLIANCE_RISCV_TEST_H
