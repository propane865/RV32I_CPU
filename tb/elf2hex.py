#!/usr/bin/env python3
"""Turn a linked riscv-test ELF into the two hex images this core loads.

    elf2hex.py --elf build/tests/rv32ui-p-add.riscv --out build/tests/rv32ui-p-add

Writes <out>.imem.hex (one 32-bit instruction word per line) and <out>.dmem.hex
(one byte per line). Both are the full size of the corresponding memory and both
are zero-padded, so tb/compliance_tb.v can $readmemh them into the memory arrays
and start from a known state rather than a partly cleared one. Whole memories
rather than just the parts with content, deliberately: whatever a test reads from
a data address the image never wrote reads as zero, which is what it reads on the
hardware. Zeroed instruction memory is not a NOP - 0x00000000 is an illegal
encoding here - so a program that runs off the end of itself takes an illegal
instruction exception, and the compliance testbench reports that as a failure with
a PC instead of watching it spin.

The checks are the reason this script exists; the formatting is incidental. The
core decodes an address from its low 13 bits and nothing else, so an out-of-range
address does not fault - it wraps, silently, to the bottom of the same memory. A
program that overran instruction memory would fetch from its own beginning, and
the visible symptom would be a wrong value in whichever test happened to get
there. Nothing at run time can catch that, so the build does, and it has to do it
from the linked ELF rather than from the linker script's own assurances: a map is
only true if someone checks the result.

So, per ELF:

  * every ALLOC section fits the memory it will be fetched or loaded from -
    instruction content below the data base, data content at or above it. That
    split is not cosmetic: loads only ever reach data memory, so a .rodata placed
    alongside .text would read back as zeroes rather than as the constant it was
    linked with, which is a wrong answer in whichever test uses it.
  * ALLOC sections do not overlap each other inside one memory.
  * the stack, which is not a section and is therefore the one region a linker
    script can size wrongly without the linker saying so, still has its reserve
    below the top of data memory.
  * loadable segments fit too, and do not straddle the data base. The section
    table and the program headers are checked separately on purpose: they are two
    accounts of the same map, and a linker script that has started lying about one
    of them is exactly the failure worth noticing early.

Bytes are taken straight from the ELF file at each PT_LOAD's File Offset, so no
objcopy blob and no gap arithmetic is involved: a segment's bytes go to the
address the segment says.

Exits non-zero with a message naming the section or segment, its range, and the
rule it broke.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

# The map, restated from tb/env/link.ld rather than read out of it: the value of
# this check is that it can disagree with the linker script.
IMEM_BYTES = 8192
DMEM_BYTES = 8192
DMEM_BASE = 0x1000
STACK_RESERVE = 256

# [Nr] Name Type Addr Off Size ES Flg Lk Inf Al, wide format. The name can be
# empty (the NULL section) and the flag column can be blank, so the row is matched
# from its fixed hex columns instead of being split into fields.
SECTION_RE = re.compile(
    r"^\s*\[\s*\d+\]\s+(\S*)\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)"
    r"\s+([0-9a-f]+)\s*([A-Za-z-]*)\s*(\d+)\s+(\d+)\s+(\d+)\s*$")


def find_tool(explicit, names, kind):
    if explicit:
        return explicit
    for name in names:
        path = shutil.which(name)
        if path:
            return path
    sys.exit("elf2hex: no %s found (tried %s). Install binutils for riscv, or pass"
             " --%s." % (kind, ", ".join(names), kind))


def readelf_rows(readelf, args, elf):
    p = subprocess.run([readelf] + args + [elf], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("elf2hex: %s %s %s failed: %s"
                 % (readelf, " ".join(args), elf, p.stderr.strip()))
    return p.stdout.splitlines()


def parse_sections(readelf, elf):
    out = []
    for line in readelf_rows(readelf, ["-SW"], elf):
        m = SECTION_RE.match(line)
        if not m:
            continue
        name, stype, addr, off, size, _es, flags = m.group(1), m.group(2), \
            int(m.group(3), 16), int(m.group(4), 16), int(m.group(5), 16), \
            int(m.group(6), 16), m.group(7)
        out.append({"name": name, "type": stype, "addr": addr, "off": off,
                    "size": size, "flags": flags})
    if not out:
        sys.exit("elf2hex: could not read a section table out of %s" % elf)
    return out


# 'LOAD 0x001000 0x00000000 0x00000000 0x000588 0x000588 R E 0x1000'. The flag
# column is the reason this is a regular expression and not a split: a readable
# executable segment prints "R E", which is two whitespace-separated fields, while
# a readable writable one prints "RW", which is one. Matching on the field count
# quietly drops whichever kind is in the minority, and a dropped data segment is a
# test that loads zeroes.
SEGMENT_RE = re.compile(
    r"^\s*LOAD\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)"
    r"\s+0x([0-9a-f]+)\s+(\S+)\s*(\S*)\s+0x([0-9a-f]+)\s*$")


def parse_segments(readelf, elf):
    """PT_LOAD rows: 'LOAD Offset VirtAddr PhysAddr FileSiz MemSiz Flg Align'."""
    out = []
    for line in readelf_rows(readelf, ["-lW"], elf):
        m = SEGMENT_RE.match(line)
        if not m:
            continue
        out.append({"off": int(m.group(1), 16), "vaddr": int(m.group(2), 16),
                    "filesz": int(m.group(4), 16), "memsz": int(m.group(5), 16),
                    "flags": m.group(6) + m.group(7)})
    return out


def parse_symbols(readelf, elf):
    syms = {}
    for line in readelf_rows(readelf, ["-sW"], elf):
        parts = line.split()
        if len(parts) >= 8 and parts[0].rstrip(":").isdigit():
            try:
                syms[parts[7]] = int(parts[1], 16)
            except ValueError:
                pass
    return syms


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--elf", required=True)
    ap.add_argument("--out", required=True, help="prefix for .imem.hex/.dmem.hex")
    ap.add_argument("--imem-bytes", type=lambda x: int(x, 0), default=IMEM_BYTES)
    ap.add_argument("--dmem-bytes", type=lambda x: int(x, 0), default=DMEM_BYTES)
    ap.add_argument("--dmem-base", type=lambda x: int(x, 0), default=DMEM_BASE)
    ap.add_argument("--stack-reserve", type=lambda x: int(x, 0),
                    default=STACK_RESERVE)
    ap.add_argument("--readelf", default=None)
    a = ap.parse_args()

    readelf = find_tool(a.readelf, ["riscv64-unknown-elf-readelf",
                                    "riscv64-linux-gnu-readelf", "llvm-readelf"],
                        "readelf")

    secs = parse_sections(readelf, a.elf)
    segs = parse_segments(readelf, a.elf)
    syms = parse_symbols(readelf, a.elf)
    alloc = [s for s in secs if "A" in s["flags"] and s["size"]]
    errors = []

    def rng(s):
        return "0x%04x..0x%04x" % (s["addr"], s["addr"] + s["size"])

    # --- content fits the memory it will be read from ------------------------
    for s in alloc:
        if "X" in s["flags"]:
            if s["addr"] >= a.dmem_base or s["addr"] + s["size"] > a.imem_bytes:
                errors.append(
                    "section %s %s is executable but does not fit instruction "
                    "memory, which is [0x0, 0x%x): the data base is 0x%x and the "
                    "memory ends at 0x%x. The core would wrap the address and "
                    "fetch from the start of the program."
                    % (s["name"] or "<unnamed>", rng(s), a.dmem_base, a.dmem_base,
                       a.imem_bytes))
        elif s["addr"] < a.dmem_base or s["addr"] + s["size"] > a.dmem_bytes:
            errors.append(
                "section %s %s is data but does not fit data memory, which is "
                "[0x%x, 0x%x). Read-only counts as data here: loads only reach "
                "data memory, so content below the data base reads back as zero "
                "instead of as the constant it was linked with."
                % (s["name"] or "<unnamed>", rng(s), a.dmem_base, a.dmem_bytes))

    # --- sections do not overlap each other inside a memory ------------------
    for mem, group in (("instruction", [s for s in alloc if "X" in s["flags"]]),
                       ("data", [s for s in alloc if "X" not in s["flags"]])):
        group = sorted(group, key=lambda s: s["addr"])
        for prev, nxt in zip(group, group[1:]):
            if nxt["addr"] < prev["addr"] + prev["size"]:
                errors.append("%s memory overlap: %s %s and %s %s"
                              % (mem, prev["name"], rng(prev), nxt["name"], rng(nxt)))

    # --- the stack still has its room ---------------------------------------
    #
    # The stack is the top of data memory growing down. It is not a section, and
    # nothing in the toolchain notices a .bss that has eaten it, which is the whole
    # reason this check exists.
    #
    # Where the program's data ends is taken from the section and segment tables,
    # not from the linker script's _end symbol: _end is one more claim about the
    # map, the same kind of claim the checks above exist to test, and a check that
    # trusted one claim to police another would check nothing. It is read
    # nevertheless and a disagreement is an error, because then the script and the
    # image it produced no longer describe the same program. Segments count as well,
    # since .bss is normally folded into a data segment with p_memsz > p_filesz, so
    # the last byte of .bss appears only in the segment table.
    has_data = any("X" not in s["flags"] for s in alloc)
    data_end = a.dmem_base if not has_data else max(
        [s["addr"] + s["size"] for s in alloc if "X" not in s["flags"]] +
        [g["vaddr"] + g["memsz"] for g in segs
         if "E" not in g["flags"] and g["vaddr"] >= a.dmem_base])

    claimed_end = syms.get("_end", syms.get("end"))
    if has_data and claimed_end is not None and claimed_end != data_end:
        errors.append(
            "the linker script says _end is 0x%x but the loaded content reaches "
            "0x%x: the map and the image disagree about where the program stops"
            % (claimed_end, data_end))

    # _stack_top is referenced by the test prologue (tb/env/riscv_test.h sets sp
    # from it), so it is in every test this build makes. The map's own top of data
    # memory is the fallback for an image that carries no such symbol.
    stack_top = syms.get("_stack_top", a.dmem_bytes)
    if stack_top > a.dmem_bytes:
        errors.append("_stack_top 0x%x is above the end of data memory 0x%x"
                      % (stack_top, a.dmem_bytes))
    if data_end + a.stack_reserve > stack_top:
        errors.append("stack does not fit: program data ends at 0x%x, the stack top "
                      "is 0x%x, and the reserve is %d bytes"
                      % (data_end, stack_top, a.stack_reserve))

    # --- segments fit, and each one is wholly in one memory ------------------
    if not segs:
        errors.append("%s has no PT_LOAD segment, so there is nothing to load"
                      % os.path.basename(a.elf))
    for g in segs:
        end = g["vaddr"] + g["memsz"]
        limit = a.imem_bytes if "E" in g["flags"] else a.dmem_bytes
        base = 0 if "E" in g["flags"] else a.dmem_base
        if g["vaddr"] < base or end > limit:
            errors.append("loadable segment at 0x%04x..0x%04x (flags %s) does not "
                          "fit [%x, %x)" % (g["vaddr"], end, g["flags"].strip(),
                                            base, limit))

    if errors:
        sys.stderr.write("elf2hex: %s does not fit this core's memory map:\n"
                         % a.elf)
        for e in errors:
            sys.stderr.write("  %s\n" % e)
        sys.exit(1)

    # --- place the bytes ----------------------------------------------------
    with open(a.elf, "rb") as f:
        elf_bytes = f.read()

    imem = bytearray(a.imem_bytes)
    dmem = bytearray(a.dmem_bytes)
    for g in segs:
        chunk = elf_bytes[g["off"]:g["off"] + g["filesz"]]
        if len(chunk) != g["filesz"]:
            sys.exit("elf2hex: segment at 0x%x claims %d file bytes at offset 0x%x,"
                     " the file has %d" % (g["vaddr"], g["filesz"], g["off"],
                                           len(chunk)))
        target = imem if "E" in g["flags"] else dmem
        # memsz > filesz is .bss: the difference stays zero, which it already is.
        target[g["vaddr"]:g["vaddr"] + g["filesz"]] = chunk

    with open(a.out + ".imem.hex", "w") as f:
        f.write("// %s: %d words, one instruction word per line, index = word "
                "address\n" % (os.path.basename(a.elf), a.imem_bytes // 4))
        for w in range(0, a.imem_bytes, 4):
            f.write("%08x\n" % int.from_bytes(imem[w:w + 4], "little"))
    with open(a.out + ".dmem.hex", "w") as f:
        f.write("// %s: %d bytes, one byte per line, index = byte address\n"
                % (os.path.basename(a.elf), a.dmem_bytes))
        for b in dmem:
            f.write("%02x\n" % b)

    text = [s for s in alloc if "X" in s["flags"]]
    print("elf2hex: %s -> %s.imem.hex, %s.dmem.hex"
          % (os.path.basename(a.elf), a.out, a.out))
    print("         code 0x%04x..0x%04x of %d KiB, %s, stack top 0x%04x (%d bytes"
          " of stack free)"
          % (text[0]["addr"] if text else 0,
             max((s["addr"] + s["size"] for s in text), default=0),
             a.imem_bytes // 1024,
             ("data ends 0x%04x" % data_end) if has_data else "no data content",
             stack_top, stack_top - data_end - a.stack_reserve))


if __name__ == "__main__":
    main()
