#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""check_consistency.py -- the E0 gate.

Cross-checks the three artifacts against each other and derives the hit
oracle:

  (a) every address in wp_set.txt lies inside the .text section of the
      disassembly AND is a real instruction start (and every `entry:` label
      matches the symbol address it names);
  (b) every function named in expected_walk.txt exists in the disassembly;
  (c) derives expected_hits.txt: the expected sequence of function-ENTRY
      addresses per phase, filtered to the addresses actually present in
      wp_set.txt (call:/body: hits of the same phase interleave between
      these in the raw record stream -- the host reader filters on the
      `entry:` labels of wp_set.txt);
  (d) prints `E0_ALL_PASS funcs=... instrs=... wp=... hits=...` -- or
      `E0_FAIL <reasons>` and exit 1.

Usage:  py check_consistency.py [--dis axis_wp_demo.dis]
            [--walk expected_walk.txt] [--wp wp_set.txt]
            [--out expected_hits.txt]
"""

import argparse
import os
import sys

import gen_wp_set  # same directory: reuse the objdump parser

HERE = os.path.dirname(os.path.abspath(__file__))


def load_wp_set(path):
    """Return list of (addr, label) from wp_set.txt."""
    out = []
    with open(path, encoding="utf-8") as f:
        for ln, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            addr_s, label = line.split(None, 1)
            out.append((int(addr_s, 16), label))
    return out


def load_walk(path):
    """Return list of (phase, [names...]) from expected_walk.txt."""
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            toks = line.split()
            if not toks[0].startswith("P"):
                continue
            out.append((int(toks[0][1:]), toks[1:]))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dis", default=os.path.join(HERE, "axis_wp_demo.dis"))
    ap.add_argument("--walk", default=os.path.join(HERE, "expected_walk.txt"))
    ap.add_argument("--wp", default=os.path.join(HERE, "wp_set.txt"))
    ap.add_argument("--out", default=os.path.join(HERE, "expected_hits.txt"))
    args = ap.parse_args(argv)

    fails = []

    symbols, instrs = gen_wp_set.parse_dis(args.dis)
    entry_of = {name: addr for addr, name in symbols}
    instr_addrs = set()
    for body in instrs.values():
        for addr, _, _ in body:
            instr_addrs.add(addr)
    if not instr_addrs:
        print("E0_FAIL no .text instructions parsed from %s" % args.dis)
        return 1
    text_lo, text_hi = min(instr_addrs), max(instr_addrs)

    # ---- (a) wp_set: in .text, on instruction starts, labels consistent ----
    wp = load_wp_set(args.wp)
    wp_addrs = {addr for addr, _ in wp}
    if len(wp_addrs) != len(wp):
        fails.append("wp_set contains %d duplicate addresses"
                     % (len(wp) - len(wp_addrs)))
    for addr, label in wp:
        if not (text_lo <= addr <= text_hi):
            fails.append("wp 0x%08x (%s) outside .text [0x%x..0x%x]"
                         % (addr, label, text_lo, text_hi))
        elif addr not in instr_addrs:
            fails.append("wp 0x%08x (%s) is not an instruction start"
                         % (addr, label))
        if label.startswith("entry:"):
            name = label[len("entry:"):]
            if entry_of.get(name) != addr:
                have = entry_of.get(name)
                fails.append("wp entry label %s does not match symbol "
                             "address %s" % (label, "0x%08x" % have
                                             if have is not None else "<absent>"))

    # ---- (b) every walked function exists in the disassembly ---------------
    walk = load_walk(args.walk)
    walked_names = set()
    for _, names in walk:
        walked_names.update(names)
    for name in sorted(walked_names):
        if name not in entry_of:
            fails.append("walk function %s not found in %s"
                         % (name, os.path.basename(args.dis)))

    if fails:
        for msg in fails[:20]:
            print("E0_FAIL " + msg)
        if len(fails) > 20:
            print("E0_FAIL ... and %d more" % (len(fails) - 20))
        return 1

    # ---- (c) expected_hits.txt: entry-address sequence per phase, filtered
    #          to wp_set membership ------------------------------------------
    n_hits = 0
    with open(args.out, "w", newline="\n", encoding="utf-8") as f:
        f.write("# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH\n")
        f.write("# SPDX-" + "License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial\n")
        f.write("# expected_hits -- derived by check_consistency.py from %s"
                " + %s\n" % (os.path.basename(args.walk),
                             os.path.basename(args.wp)))
        f.write("# format: P<phase> <seq> 0x<addr8> <name>\n")
        f.write("# Only function-ENTRY hits are listed; call:/body:"
                " watchpoint hits of the\n")
        f.write("# same phase interleave between these in the raw record"
                " stream (filter on\n")
        f.write("# the entry: labels of wp_set.txt). With the endless walk"
                " the whole file\n")
        f.write("# repeats from P0 after the last phase.\n")
        for phase, names in walk:
            seq = 0
            for name in names:
                addr = entry_of[name]
                if addr in wp_addrs:
                    f.write("P%d %d 0x%08x %s\n" % (phase, seq, addr, name))
                    seq += 1
                    n_hits += 1

    print("E0_ALL_PASS funcs=%d instrs=%d wp=%d hits=%d"
          % (len(walked_names), len(instr_addrs), len(wp), n_hits))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
