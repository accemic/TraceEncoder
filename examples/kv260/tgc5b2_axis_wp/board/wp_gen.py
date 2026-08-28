#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""wp_gen.py -- derive the G1 host artifacts from sw/ (C1b rules).

Replicates build_oracle() from sim/axis_wp/tb_tgc5b2_axis_soc.sv's FULL_WP
branch: ALL distinct addresses from expected_hits.txt (expected 364, all
even), sorted strictly ascending into slots 0..n_real-1; above that, odd
filler entries (maxa&~3)+5+2j up to slot 1022 (PC[0]=0 => unmatchable). The
command word per slot follows wp_load_indirect.cmd_word (real (slot<<8)|0x41,
filler (slot<<8)|0x00). The FULL oracle (851 hits per pass) becomes the
reader's expectation: expected_full.txt (run A exact, run B --expected-cycle).

Ported from the predecessor repository's g1_gen.py (embedded in g1_board_run.ps1's `gen`
phase as a heredoc) -- algorithm, asserts and output format unchanged;
this is now a standalone checked-in file instead of a heredoc generated at
runtime by the driver script.

    py wp_gen.py <expected_hits.txt> <axis_wp_demo.hex> <outdir>

Writes <outdir>/{wp_table.txt,wp_real.txt,expected_full.txt,prog.hex}.
"""
import argparse
import os
import sys

# wp_load_indirect.py lives in tools/axis_wp_host/, not next to this file
# (unlike on the board, where wp_board_gate.sh's `deploy` phase scp's both
# into the same /tmp/wp_board_run/ directory) -- add both candidate
# locations so this script runs standalone from its checked-in path.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.normpath(
    os.path.join(_HERE, "..", "..", "..", "..", "tools", "axis_wp_host")))
import wp_load_indirect as wpi  # noqa: E402

N_SLOTS = 1023


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("hits", help="sw/expected_hits.txt")
    ap.add_argument("hexsrc", help="sw/axis_wp_demo.hex")
    ap.add_argument("outdir")
    a = ap.parse_args()

    hits = []
    with open(a.hits, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            p = s.split()
            if len(p) < 3 or not p[0].startswith("P"):
                continue
            hits.append(int(p[2], 16))
    assert 700 <= len(hits) <= 1000, "oracle implausible: %d hits" % len(hits)

    distinct = []
    seen = set()
    for h in hits:
        if h not in seen:
            seen.add(h)
            distinct.append(h)
    assert 300 <= len(distinct) <= N_SLOTS - 2, \
        "implausible distinct address count %d" % len(distinct)
    assert all(x % 2 == 0 for x in distinct), "a real address is odd?"
    n_real = len(distinct)
    tbl = sorted(distinct)
    maxa = tbl[-1]
    tbl += [(maxa & ~3) + 5 + 2 * j for j in range(N_SLOTS - n_real)]
    for i in range(1, N_SLOTS):
        assert tbl[i] > tbl[i - 1], "slots not strictly ascending"
    slot = {addr: i for i, addr in enumerate(tbl)}

    os.makedirs(a.outdir, exist_ok=True)

    def w(name, text):
        with open(os.path.join(a.outdir, name), "w", encoding="utf-8",
                  newline="\n") as f:
            f.write(text)

    w("wp_table.txt", "".join("%d 0x%08x 0x%08x\n"
                              % (i, addr, wpi.cmd_word(addr, i))
                              for i, addr in enumerate(tbl)))
    w("wp_real.txt", "".join("0x%08x slot=%d\n" % (addr, slot[addr])
                             for addr in tbl[:n_real]))
    w("expected_full.txt", "".join("0x%08x slot=%d\n" % (h, slot[h])
                                   for h in hits))

    with open(a.hexsrc, encoding="utf-8") as f:
        lines = [l.strip() for l in f if l.strip()]
    w("prog.hex", "\n".join(lines) + "\n")

    print("G1GEN hits=%d n_real=%d slots=%d fill=%d hexwords=%d"
          % (len(hits), n_real, N_SLOTS, N_SLOTS - n_real, len(lines)))
    print("G1GEN slot0=0x%08x slot%d=0x%08x slot1022=0x%08x"
          % (tbl[0], n_real - 1, tbl[n_real - 1], tbl[1022]))


if __name__ == "__main__":
    main()
