#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""objdump listing (`.dis`) -> symbol table + call/return sites.

    py dis_to_symbols.py merged3.dis [more.dis ...] \\
        -o symbols_cva6_linux.map --sites sites_cva6_linux.map

Why from the LISTING and not from `nm vmlinux`: the listings the decoder needs
anyway already carry the RIGHT addresses. A Linux boot runs through three
address spaces (OpenSBI 0x6400_0000, kernel physical 0x6440_0000, kernel
virtual 0xC000_0000, see sw/cva6_linux/make_listing.sh), and
`make_listing.sh` relocates the physical copy with `objcopy
--change-addresses`. An `nm vmlinux` only knows the virtual addresses -- the
physical phase of the boot would stay unsymbolised.

**Why the sites file exists (a measured defect, not caution):** deriving call
depth from "a jump target is the start of a symbol" is WRONG. OpenSBI
assembler names local labels (`_try_lottery`, `_relocate_done`), so an
ordinary forward jump to one of them looked like a call that never returns --
over a single boot the depth ran away to 2972 frames (measured on lb3.pcout,
3,993,361 PCs). From the listing the question can be answered exactly, because
objdump makes rd=ra visible through the mnemonic:

    jal  <target>  rd=ra    -> call        j   <target>  rd=zero -> jump
    jalr <reg>     rd=ra    -> call        jr  <reg>     rd=zero -> jump
    ret                     -> return

Output:
    symbols  `64000000 T _fw_start`          (System.map format)
    sites    `C 6400000c` / `R 640003fc`     (call and return site)
"""
import argparse
import re
import sys
from pathlib import Path

LABEL = re.compile(r"^([0-9a-fA-F]{8,16})\s+<([^>]+)>:\s*$")
INSN = re.compile(r"^\s*([0-9a-fA-F]+):\s+[0-9a-fA-F]+\s+(\S+)")
CALL_MN = {"jal", "jalr"}      # rd=ra -- objdump shows this via the mnemonic
RET_MN = {"ret"}               # objdump already renders 'jr ra' as 'ret'


def extract(paths):
    syms, calls, rets = {}, set(), set()
    for p in paths:
        ns = nc = nr = 0
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = LABEL.match(line)
                if m:
                    a = int(m.group(1), 16)
                    if a not in syms:
                        syms[a] = m.group(2)
                        ns += 1
                    continue
                m = INSN.match(line)
                if not m:
                    continue
                mn = m.group(2)
                if mn in CALL_MN:
                    calls.add(int(m.group(1), 16))
                    nc += 1
                elif mn in RET_MN:
                    rets.add(int(m.group(1), 16))
                    nr += 1
        print("%-24s %7d symbols  %7d call sites  %7d return sites"
              % (Path(p).name, ns, nc, nr), file=sys.stderr)
    return syms, calls, rets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dis", nargs="+", help="objdump -d listing(s)")
    ap.add_argument("-o", "--out", default="-", help="symbol table (default: stdout)")
    ap.add_argument("--sites", default=None,
                    help="call/return sites; WITHOUT this file the call depth in "
                         "the dashboard stays deliberately empty")
    a = ap.parse_args()
    syms, calls, rets = extract(a.dis)
    if not syms:
        print("### NO symbol found -- is this really an 'objdump -d' listing?",
              file=sys.stderr)
        return 1
    body = "\n".join("%08x T %s" % (addr, syms[addr]) for addr in sorted(syms)) + "\n"
    if a.out == "-":
        sys.stdout.write(body)
    else:
        Path(a.out).write_text(body, encoding="utf-8")
    print("%d symbols -> %s" % (len(syms), a.out), file=sys.stderr)
    if a.sites:
        s = "".join("C %08x\n" % x for x in sorted(calls))
        s += "".join("R %08x\n" % x for x in sorted(rets))
        Path(a.sites).write_text(s, encoding="utf-8")
        print("%d call sites + %d return sites -> %s"
              % (len(calls), len(rets), a.sites), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
