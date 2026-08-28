#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Gate B1-1: `parse_elf` against `readelf -l` -- for ELF32 AND ELF64.

The yardstick is NOT "it runs through" but the segment list of a foreign
tool: for every PT_LOAD segment, p_paddr and the lengths (FileSiz/MemSiz)
must agree byte for byte with `readelf -l` -- and the extracted content with
the file excerpt that readelf names by its offset.

COUNTER-CHECK (otherwise the gate is blind): the same file is additionally
put through the OLD `<6I` parser. On ELF64 that one must deliver WRONG
addresses (or bail out) -- if it does not, the gate is not checking what it
claims to check, and reports itself red.

SKIP-clean when the RISC-V toolchain is missing AND when the fixture corpus
is missing: this gate needs both `riscv64-unknown-elf-readelf` and the
prebuilt ELF files listed below (`sw/`, `bld/`) -- both live only in the
predecessor-repository work tree (characterisation software/build artefacts,
not part of this example, see examples/dashboard/README.md "Testing").
Without the toolchain OR without the corpus, `main()` reports SKIP and exit 0
-- never FAIL, because a FAIL here would be a false statement about
server.py, not about the missing environment.

Invocation (Windows):
    py test_elf_load.py

RISC-V toolchain resolution (no hard-coded path any more): `RISCV_READELF`
(explicit path) > `RISCV_BIN` (directory, the same convention as
scripts/ct_env.sh in the main repository) > PATH.
"""
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import server  # noqa: E402  (the path insert has to come first)

PT_LOAD_T = 1


def find_readelf():
    """Find the RISC-V readelf without guessing a machine path.

    Search order: RISCV_READELF (explicit file) > RISCV_BIN (directory,
    ct_env.sh convention) > PATH, trying both the rv32 and rv64
    unknown-elf toolchain name. Returns None if nothing is found -- that
    is a normal outcome on a machine without a RISC-V toolchain, not an
    error.
    """
    explicit = os.environ.get("RISCV_READELF")
    if explicit and Path(explicit).is_file():
        return Path(explicit)
    names = ["riscv64-unknown-elf-readelf", "riscv32-unknown-elf-readelf"]
    exe = ".exe" if os.name == "nt" else ""
    riscv_bin = os.environ.get("RISCV_BIN")
    if riscv_bin:
        for name in names:
            cand = Path(riscv_bin) / (name + exe)
            if cand.is_file():
                return cand
    for name in names:
        found = shutil.which(name)
        if found:
            return Path(found)
    return None


READELF = None   # resolved in main(); readelf_loads() reads this global

# (path, expected class). Deliberately both core families and both extremes:
# the RV32 path is in service and must stay unchanged, the RV64 payloads are
# the real OpenSBI+Linux images of packages L2/L3.
CASES = [
    ("sw/microblaze_v_ctrace_demo/build/branch_test.elf", "ELF32"),
    ("sw/cva6_char/char_test.elf",                        "ELF32"),
    ("sw/cva6_char/e2e_test.elf",                         "ELF32"),
    ("sw/cva6_char/char_test64.elf",                      "ELF64"),
    ("sw/cva6_char/char_test_hi64.elf",                   "ELF64"),
    ("sw/cva6_char/ctx_test64.elf",                       "ELF64"),
    ("bld/l3_cv64a6_soc/fw_payload.elf",                  "ELF64"),
    ("bld/l2_rocket_linux/fw_payload.elf",                "ELF64"),
]


def readelf_loads(path):
    """[(p_offset, p_paddr, p_filesz, p_memsz)] of the PT_LOAD segments per readelf."""
    out = subprocess.run([str(READELF), "-l", "--wide", str(path)],
                         capture_output=True, text=True, check=True).stdout
    lines = out.splitlines()
    segs = []
    for i, ln in enumerate(lines):
        f = ln.split()
        if not f or f[0] != "LOAD":
            continue
        # ELF64 wraps the line: LOAD off vaddr paddr / filesz memsz flags align
        # ELF32 (--wide) keeps everything on one line.
        hexes = re.findall(r"0x[0-9a-fA-F]+", ln)
        if len(hexes) >= 6:
            off, _va, paddr, filesz, memsz = (int(hexes[0], 16), int(hexes[1], 16),
                                              int(hexes[2], 16), int(hexes[3], 16),
                                              int(hexes[4], 16))
        else:
            nxt = re.findall(r"0x[0-9a-fA-F]+", lines[i + 1])
            off, _va, paddr = (int(hexes[0], 16), int(hexes[1], 16), int(hexes[2], 16))
            filesz, memsz = int(nxt[0], 16), int(nxt[1], 16)
        segs.append((off, paddr, filesz, memsz))
    return segs


def old_parse_elf32(data):
    """The state BEFORE B1 (server.py:860, verbatim) -- for the counter-check only."""
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if data[4] != 1 or data[5] != 1:
        raise ValueError("need ELF32 little-endian")
    e_phoff, = struct.unpack_from("<I", data, 28)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 42)
    out = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        p_type, p_offset, _va, p_paddr, p_filesz, p_memsz = struct.unpack_from("<6I", data, o)
        if p_type != 1 or p_memsz == 0:
            continue
        out.append((p_paddr, p_filesz, p_memsz))
    return out


def main():
    global READELF
    READELF = find_readelf()
    if READELF is None:
        print("SKIP: no RISC-V readelf found (set RISCV_READELF or "
              "RISCV_BIN, or put riscv64-unknown-elf-readelf on PATH) -- "
              "this gate needs a RISC-V toolchain and is not part of the "
              "hardware-free demo mode")
        return 0
    fails = []
    missing = []
    print("%-52s %-6s %-4s %s" % ("file", "class", "seg", "verdict"))
    for rel, want_class in CASES:
        p = ROOT / rel
        if not p.is_file():
            missing.append(rel)
            print("%-52s %-6s %-4s SKIP (fixture not in this repo)"
                  % (rel, want_class, "-"))
            continue
        data = p.read_bytes()
        got_class = server.elf_class(data)
        if got_class != want_class:
            fails.append("%s: class %s instead of %s" % (rel, got_class, want_class))
        ref = readelf_loads(p)
        mine = list(server.parse_elf(data))
        if len(mine) != len(ref):
            fails.append("%s: %d segments instead of %d" % (rel, len(mine), len(ref)))
            print("%-52s %-6s %-4d COUNT != %d" % (rel, got_class, len(mine), len(ref)))
            continue
        ok = True
        for n, ((off, paddr, filesz, memsz), (my_paddr, my_seg)) in enumerate(zip(ref, mine)):
            if my_paddr != paddr:
                fails.append("%s seg%d: paddr 0x%x instead of 0x%x" % (rel, n, my_paddr, paddr))
                ok = False
            if len(my_seg) != memsz:
                fails.append("%s seg%d: len %d instead of memsz %d" % (rel, n, len(my_seg), memsz))
                ok = False
            # Content: the file excerpt that readelf names by its offset.
            if my_seg[:filesz] != data[off:off + filesz]:
                fails.append("%s seg%d: content != file[0x%x:+0x%x]" % (rel, n, off, filesz))
                ok = False
            if any(my_seg[filesz:]):
                fails.append("%s seg%d: .bss part not zeroed" % (rel, n))
                ok = False
        # --- counter-check: the old parser MUST be wrong on ELF64 ------------
        try:
            old = old_parse_elf32(data)
            old_err = None
        except ValueError as e:
            old, old_err = None, str(e)
        if want_class == "ELF64":
            old_same = (old is not None and
                        [(a, len(s)) for a, s in mine] == [(a, m) for a, _f, m in old])
            if old_same:
                fails.append("%s: COUNTER-CHECK BLIND -- the old <6I parser delivers "
                             "the same segments, the gate checks nothing" % rel)
            # Second, sharper counter-check: imagine the class check away. If the
            # fix had only been "allow data[4]!=1", the ELF64 layout would still
            # be wrong. This SHOWS that instead of claiming it in a comment.
            relaxed = old_parse_elf32(b"\x7fELF\x01" + data[5:])
            mine_pa = sorted(a for a, _s in mine)
            if sorted(a for a, _f, _m in relaxed) == mine_pa:
                fails.append("%s: COUNTER-CHECK BLIND -- on ELF64 <6I delivers the same "
                             "paddr as the correct layout" % rel)
            # And a third stage: even at the RIGHT e_phoff the ELF32 layout is
            # wrong. Without this line the counter-check would only prove that
            # e_phoff/e_phnum sit in the wrong place.
            phoff, = struct.unpack_from("<Q", data, 32)
            ent, num = struct.unpack_from("<HH", data, 54)
            at_right = [struct.unpack_from("<6I", data, phoff + k * ent)
                        for k in range(num)]
            good = [(t, pa, ms) for (t, _o, _v, pa, _fs, ms) in at_right
                    if t == PT_LOAD_T and ms and pa in mine_pa]
            if good:
                fails.append("%s: COUNTER-CHECK BLIND -- at the right e_phoff <6I does "
                             "hit the real paddr %r" % (rel, good))
            e32 = struct.unpack_from("<I", data, 28)[0], struct.unpack_from("<HH", data, 44)[0]
            note = ("old: %s; ELF32 reading e_phoff=0x%x e_phnum=%d (really 0x%x/%d); "
                    "<6I@e_phoff: %d load segments"
                    % (old_err or "ran through", e32[0], e32[1], phoff, num, len(good)))
        else:
            # RV32 counter-check: the old and the new parser MUST be identical --
            # this path is in service, a deviation would be the regression.
            old_same = (old is not None and
                        [(a, len(s)) for a, s in mine] == [(a, m) for a, _f, m in old])
            if not old_same:
                fails.append("%s: REGRESSION -- on ELF32 the new parser deviates from "
                             "the old one (old %r, new %r)"
                             % (rel, old, [(a, len(s)) for a, s in mine]))
                ok = False
            note = "old == new (no RV32 drift)"
        print("%-52s %-6s %-4d %s  [%s]" % (rel, got_class, len(mine),
                                            "OK" if ok else "FAIL", note))
    print()
    if fails:
        print("GATE B1-1: FAIL (%d findings)" % len(fails))
        for f in fails:
            print("  - %s" % f)
        return 1
    if len(missing) == len(CASES):
        print("SKIP: none of the %d fixture ELFs are present (sw/, bld/ are "
              "the predecessor repository build artifacts, not part of this example) -- "
              "nothing to verify server.py's ELF loader against" % len(CASES))
        return 0
    if missing:
        print("GATE B1-1: PASS -- %d/%d fixture ELFs present and identical "
              "to readelf -l (%d skipped, not part of this example), "
              "ELF64 counter-check red, ELF32 free of drift"
              % (len(CASES) - len(missing), len(CASES), len(missing)))
        return 0
    print("GATE B1-1: PASS -- %d files, segments identical to readelf -l, "
          "ELF64 counter-check red, ELF32 free of drift" % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
