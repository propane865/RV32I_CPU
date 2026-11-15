/* ============================================================================
 * Link map for the rv32ui compliance suite on this core.
 *
 * Two rules here come from the hardware rather than from taste, and both are
 * enforced independently by tb/elf2hex.py, which reads the section table of the
 * linked ELF and refuses the build. The linker script gets to be the first
 * line of defence, not the only one, because a map that only the linker
 * understands is a map that silently stops being true the day someone edits it.
 *
 * 1. Instruction fetch and data access go to two different memories
 *    (rtl/mem/imem.v, rtl/mem/dmem.v), and the load path only ever reaches the
 *    data one. So *all* readable content - .rodata and any literal pool
 *    included, not just .data - must be placed at or above 0x1000, where data
 *    memory lives. Placing .rodata next to .text because "it is read-only, so
 *    it goes with the code" is the classic way to get this wrong: the test would
 *    assemble, link, load, and then read zeroes from instruction memory, which
 *    is a wrong-value failure in whichever test happens to use a constant.
 *
 * 2. Both memories are 8 KiB (defines.vh: IMEM_WORDS/DMEM_BYTES) and the core
 *    decodes an address purely from its low 13 bits, so an out-of-range address
 *    does not fault - it wraps. A program that overran instruction memory would
 *    fetch from the start of the program. Nothing in the core can catch that, so
 *    the build has to.
 *
 * The gap between 0x400 and 0x1000 is deliberate slack: it keeps .text and
 * .data at addresses that cannot be confused with each other when a hex image or
 * a waveform is being read by eye.
 * ==========================================================================*/

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* Instruction memory: fetched from, never loaded to. */
    IMEM (rx!w)  : ORIGIN = 0x00000000, LENGTH = 8K
    /* Data memory spans 0x0..0x2000; the low 4 KiB is left unused so that no
       data address can be mistaken for a code address. */
    DMEM (rw!x)  : ORIGIN = 0x00001000, LENGTH = 4K
}

/* The stack grows down from the top of data memory and no section reserves it,
   so the only thing standing between a large .bss and silent corruption of the
   stack frame is this number and the check below it. 256 bytes is far more than
   the rv32ui bodies need - none of them calls, so none of them pushes - and the
   point is to fail the build rather than to run out mid-test. */
STACK_RESERVE = 256;

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text.entry)
        *(.text.unlikely)
        *(.text.*)
        *(.text)
        *(.gnu.linkonce.t.*)
    } > IMEM

    /* Read-only content belongs with the data, for the reason in rule 1. */
    .rodata : ALIGN(4) {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
    } > DMEM

    .data : ALIGN(4) {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        *(.gnu.linkonce.d.*)
    } > DMEM

    .sdata2 : ALIGN(4) {
        *(.sdata2)
        *(.sdata2.*)
    } > DMEM

    .bss : ALIGN(4) {
        PROVIDE(__bss_start = .);
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        PROVIDE(__bss_end = .);
    } > DMEM

    /* Plain assignments, not PROVIDE. PROVIDE emits a symbol only when something
       refers to it, so the PROVIDE(_end = .) this script used to have vanished from
       the image the moment the ASSERT below - its only reference - was edited out,
       and tb/elf2hex.py then complained that it could not find _end while the map
       was perfectly fine. These two symbols are part of the build's contract, so
       they are defined unconditionally; PROVIDE keeps the aliases available for
       anything that links C in later. */
    _end = .;
    PROVIDE(end = _end);
    _stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
    PROVIDE(stack_top = _stack_top);

    /* Checked here for a message at the moment the map stops fitting, and again
       in tb/elf2hex.py against the sections as actually linked. */
    ASSERT(_end <= _stack_top - STACK_RESERVE,
           "link map overflow: .bss ends within STACK_RESERVE of the top of data memory, so the stack would grow into it")

    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
        *(.note.GNU-stack)
    }
}
