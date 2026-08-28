#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# extract_tlrom.py - extract the TLROM boot-ROM content from the vendored
# Rocket netlist (examples/kv260/third_party/rocket_ref/system-nexys-video.v,
# module TLROM, lines 94440-98554) into a 32 KiB binary (base 0x10000).
#
#   py examples/kv260/common/tools/extract_tlrom.py out.bin [--patch-hart0]
#       [--patch-verilog-out <dst.v>]
#
# In the netlist the ROM is a mux chain `12'h<idx> == index ? 64'h<val> : ...`
# with index = addr[14:3]; indices that are not listed read the chain default
# (= the value of index 0, which itself never appears as a comparison);
# addr[15]=1 (upper 32 KiB of the 64 KiB window) reads 0 (`|high ? 64'h0`).
#
# --patch-hart0 applies the one-word bring-up patch: word index 0xb, lower
# half-word @0x10058 `jal zero,0x10016` (0xfbfff06f, the hart-0 branch into
# the SD-card bootloader -- a dead path in simulation: it polls SDC/UART MMIO
# and overwrites word 0 of the workload on the way) -> `jal zero,0x10000`
# (0xfa9ff06f, direct ROM entry: c.jr s0 to 0x8000_0000). The patched binary
# is the oracle base (rom.dis) for the Rocket TCI check -- disassembly ==
# the code actually executed.
#
# --patch-verilog-out additionally writes a WORK-LOCAL copy of the whole
# netlist with exactly this one ROM word patched (the line is self-verified;
# the vendored file stays untouched). Background: the first attempt, forcing
# the word onto the TLROM data bus conditionally, did not take effect under
# XSIM 2026.1 (the commit log still showed 0xfbfff06f) -- the compile-time
# patch is simulator-independent and deterministic.
import argparse
import os
import re

SRC = os.path.join(os.path.dirname(__file__), "..", "..",
                   "third_party", "rocket_ref", "system-nexys-video.v")
# Line window of the single-hart netlist. For a different netlist (--gen,
# e.g. rocket64t2) TLROM sits elsewhere -- the bounds are then searched for
# instead of guessed; for the default file they remain the counter-check.
ROM_FIRST, ROM_LAST = 94440, 98554   # module TLROM ... endmodule
INDEX0_DEFAULT = 0x597F1402573       # else branch of _GEN_1 (= word 0)
PATCH_IDX = 0xB
PATCH_VAL = 0x30541073FA9FF06F       # upper half-word unchanged (csrw mtvec)


ORIG_LINE = "12'hb == index ? 64'h30541073fbfff06f"
PATCH_LINE = "12'hb == index ? 64'h30541073fa9ff06f"


def find_rom_bounds(path):
    """Find the line window from `module TLROM` to `endmodule` in the netlist."""
    first = last = None
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            if first is None:
                if line.startswith("module TLROM("):
                    first = lineno
            elif line.startswith("endmodule"):
                last = lineno
                break
    assert first and last, "module TLROM not found in %s" % path
    return first, last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--patch-hart0", action="store_true")
    ap.add_argument("--patch-verilog-out", default=None,
                    help="work-local netlist copy with the patched ROM word")
    ap.add_argument("--gen", default=SRC,
                    help="netlist file (default: the single-hart netlist; the "
                         "two-hart build uses "
                         "third_party/rocket_ref/rocket64t2/system-nexys-video.v)")
    args = ap.parse_args()
    src = args.gen
    rom_first, rom_last = find_rom_bounds(src)
    if os.path.abspath(src) == os.path.abspath(SRC):
        # Counter-check: for the default netlist the search must find exactly
        # the known window -- otherwise the netlist has moved.
        assert (rom_first, rom_last) == (ROM_FIRST, ROM_LAST),             "TLROM window moved: %d..%d instead of %d..%d" % (
                rom_first, rom_last, ROM_FIRST, ROM_LAST)

    pat = re.compile(r"12'h([0-9a-f]+) == index \? 64'h([0-9a-f]+)")
    words = {}
    with open(src) as fh:
        for lineno, line in enumerate(fh, 1):
            if lineno < rom_first:
                continue
            if lineno > rom_last:
                break
            m = pat.search(line)
            if m:
                idx = int(m.group(1), 16)
                assert idx not in words, "duplicate index %#x line %d" % (idx, lineno)
                words[idx] = int(m.group(2), 16)

    assert 0 not in words and len(words) == 4095, \
        "unexpected ROM structure (%d entries)" % len(words)
    words[0] = INDEX0_DEFAULT
    if args.patch_hart0:
        assert words[PATCH_IDX] == 0x30541073FBFFF06F, \
            "patch base @idx 0xb differs: %#x" % words[PATCH_IDX]
        words[PATCH_IDX] = PATCH_VAL

    buf = bytearray(32 * 1024)
    for idx in range(4096):
        buf[idx * 8:idx * 8 + 8] = words[idx].to_bytes(8, "little")
    with open(args.out, "wb") as fh:
        fh.write(buf)
    print("OK: TLROM -> %s (32768 B%s)" %
          (args.out, ", hart0 patch" if args.patch_hart0 else ""))

    if args.patch_verilog_out:
        assert args.patch_hart0, "--patch-verilog-out only together with --patch-hart0"
        with open(src) as fh:
            text = fh.read()
        assert text.count(ORIG_LINE) == 1, "ROM patch line is not unique"
        with open(args.patch_verilog_out, "w") as fh:
            fh.write(text.replace(ORIG_LINE, PATCH_LINE))
        print("OK: patched netlist copy -> %s" % args.patch_verilog_out)


if __name__ == "__main__":
    main()
