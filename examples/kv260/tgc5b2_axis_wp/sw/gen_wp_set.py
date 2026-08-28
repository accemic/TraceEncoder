#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""gen_wp_set.py — extract the watchpoint address set from the disassembly.

Reads axis_wp_demo.dis (objdump -d) and writes wp_set.txt: >= TARGET unique
instruction addresses, sorted ascending, one per line as

    0x<addr8> <label>

Label kinds (all three mixed, every address executes DETERMINISTICALLY —
see the whitelist rules below):

    entry:<fn>                     function entry (walk leaves + phase
                                   runners ONLY)
    call:<runner>+0x<off>-><fn>    direct-call site inside a phase runner
                                   (executes exactly once per phase run)
    body:<fn>+0x<off>              follow address inside a straight-line
                                   leaf body (executes exactly once per call)

Deliberately EXCLUDED (their execution order/count is not deterministic or
not part of the walk): _start/halt (reset/park path, spin loop), main
(spin-wait loop!), trap_handler and everything reached from it (async IRQ
pacer). This keeps the FULL hit stream of the loaded set predictable from
expected_walk.txt — the CFI pre-stage property.

Hard-fails (exit 1) if fewer than TARGET unique addresses are available.

Usage:  py gen_wp_set.py [--dis axis_wp_demo.dis] [--out wp_set.txt]
                         [--target 1023]
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

RE_SECTION = re.compile(r"^Disassembly of section (\S+):$")
RE_SYMBOL = re.compile(r"^([0-9a-f]+) <([^>]+)>:$")
RE_INSTR = re.compile(r"^\s+([0-9a-f]+):\s+[0-9a-f]+\s+(\S+)(.*)$")
RE_TARGET = re.compile(r"<([^>+]+)>\s*$")

RE_LEAF = re.compile(r"^f\d{3}$")
RE_RUNNER = re.compile(r"^run_phase_\d{2}$")


def parse_dis(path):
    """Return (symbols, instrs): symbols = list of (addr, name) in .text in
    address order; instrs = {sym_name: [(addr, mnemonic, operands), ...]}."""
    symbols = []
    instrs = {}
    section = None
    cur = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = RE_SECTION.match(line)
            if m:
                section = m.group(1)
                cur = None
                continue
            if section != ".text":
                continue
            m = RE_SYMBOL.match(line)
            if m:
                cur = m.group(2)
                symbols.append((int(m.group(1), 16), cur))
                instrs[cur] = []
                continue
            m = RE_INSTR.match(line)
            if m and cur is not None:
                instrs[cur].append(
                    (int(m.group(1), 16), m.group(2), m.group(3)))
    return symbols, instrs


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dis", default=os.path.join(HERE, "axis_wp_demo.dis"))
    ap.add_argument("--out", default=os.path.join(HERE, "wp_set.txt"))
    ap.add_argument("--target", type=int, default=1023,
                    help="exact number of watchpoints to emit (default 1023"
                         " = ACT-ST capacity at M0_DIM=10)")
    args = ap.parse_args(argv)

    symbols, instrs = parse_dis(args.dis)
    sym_names = {name for _, name in symbols}

    leaves = sorted(n for n in sym_names if RE_LEAF.match(n))
    runners = sorted(n for n in sym_names if RE_RUNNER.match(n))
    if not leaves or not runners:
        print("E0_FAIL gen_wp_set: no leaves/runners found in %s" % args.dis)
        return 1

    entry_of = {name: addr for addr, name in symbols}

    # Priority 1: all leaf + runner entries (the oracle addresses).
    picks = []           # (addr, label), insertion order = priority
    seen = set()

    def put(addr, label):
        if addr not in seen:
            seen.add(addr)
            picks.append((addr, label))

    for name in leaves + runners:
        put(entry_of[name], "entry:%s" % name)
    n_entry = len(picks)

    # Priority 2: one follow address per leaf body (straight-line => the
    # instruction after the entry executes exactly once per call).
    for name in leaves:
        body = instrs[name]
        if len(body) >= 2:
            put(body[1][0], "body:%s+0x%x" % (name, body[1][0] - entry_of[name]))
    n_body1 = len(picks) - n_entry

    # Priority 3: direct-call sites inside the phase runners.
    calls = []
    for name in runners:
        base = entry_of[name]
        for addr, mnem, ops in instrs[name]:
            if mnem in ("jal", "jalr"):
                m = RE_TARGET.search(ops)
                if m and RE_LEAF.match(m.group(1)):
                    calls.append((addr, "call:%s+0x%x->%s"
                                  % (name, addr - base, m.group(1))))
    # Deterministic spread: take every k-th callsite so the remaining quota
    # covers all runners evenly instead of only the low-address ones.
    quota = args.target - len(picks)
    if quota > 0 and calls:
        step = max(1, len(calls) // quota)
        for i in range(0, len(calls), step):
            if len(picks) >= args.target:
                break
            put(*calls[i])
    n_call = len(picks) - n_entry - n_body1

    # Priority 4 (fill, if ever needed): deeper leaf-body follow addresses.
    depth = 2
    while len(picks) < args.target:
        added = False
        for name in leaves:
            if len(picks) >= args.target:
                break
            body = instrs[name]
            if len(body) > depth:
                put(body[depth][0],
                    "body:%s+0x%x" % (name, body[depth][0] - entry_of[name]))
                added = True
        depth += 1
        if not added:
            break
    n_fill = len(picks) - n_entry - n_body1 - n_call

    if len(picks) < args.target:
        print("E0_FAIL gen_wp_set: only %d unique deterministic addresses "
              "available, need %d" % (len(picks), args.target))
        return 1

    picks = sorted(picks[:args.target])
    with open(args.out, "w", newline="\n", encoding="utf-8") as f:
        f.write("# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH\n")
        f.write("# SPDX-" + "License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial\n")
        f.write("# wp_set -- GENERATED by gen_wp_set.py from %s\n"
                % os.path.basename(args.dis))
        f.write("# target=%d entries=%d body=%d calls=%d fill=%d\n"
                % (args.target, n_entry, n_body1, n_call, n_fill))
        f.write("# every address is a deterministic instruction start; see\n")
        f.write("# gen_wp_set.py header for the whitelist/exclusion rules\n")
        for addr, label in picks:
            f.write("0x%08x %s\n" % (addr, label))

    print("[gen_wp_set] wrote %s: %d watchpoints "
          "(entry=%d body+4=%d call=%d fill=%d) from %d candidates"
          % (args.out, len(picks), n_entry, n_body1, n_call, n_fill,
             n_entry + n_body1 + len(calls) + n_fill))
    print("WP_SET_OK count=%d" % len(picks))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
