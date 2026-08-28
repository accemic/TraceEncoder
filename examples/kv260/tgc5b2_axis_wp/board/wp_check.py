#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""wp_check.py -- host-side checks on the G1 reader/board logs.

Checks what the F1 reader (read_wp_stream.py) does not cover on its own:

runa: (a) count equality records==851==len(expected) per core (the reader's
      own PASS only proves unmatched==0 -- a subsequence; only
      records==N turns that into full list equality), (b)
      W1(DirectData)==slot index of the hit address, tid==0x01,
      tstrb==0xFFF (AXIS-TS state, C0b build), core ID constant, (c) 0
      drops/overflows + SCRATCH phase==64 + the end-of-walk marker from the
      board log, (d) cross-core TS: |ts0[k]-ts1[k]| <= 64 per index (C1b
      tolerance; sim ideal is 0) + a two-pointer merge of both streams that
      is monotone non-decreasing (shared fabric_time).

runb: (a) reader PASS + unmatched==0 per leg (exact subsequence of the
      periodic oracle), (b) wrap counters documented, (c) balance per core:
      received(leg+rest) + drops(FINAL) == produced (SCRATCH
      phase/64 * 851, tolerance 1 pass) AND consistent between cores.

Ported from the predecessor repository's g1_check.py unchanged in logic/regexes/exit codes;
docstrings/comments translated to English. One real simplification: the
source's `open_text()` sniffed for a UTF-16LE BOM because PowerShell's
`Tee-Object -FilePath` writes UTF-16LE by default (a real gate failure the
source hit and fixed on 2026-08-13) -- the Bash port captures the same logs
through POSIX `tee`, which is always plain UTF-8/ASCII, so that BOM-sniffing
is now dead code for a tool that no longer exists in this path and has been
dropped rather than carried forward as an unused defensive shim.
"""
import argparse
import re
import sys

REC_RE = re.compile(
    r"Record\(#(\d+) core=(\d+) pc=0x([0-9A-Fa-f]+) direct=0x([0-9A-Fa-f]+)"
    r" ts=0x([0-9A-Fa-f]+) tid=0x([0-9A-Fa-f]+) tstrb=0x([0-9A-Fa-f]+)\)")


def open_text(path):
    return open(path, encoding="utf-8", errors="replace")


def parse_raw(path):
    recs = []
    with open_text(path) as f:
        for line in f:
            m = REC_RE.search(line)
            if m:
                recs.append(tuple(int(g, b) for g, b in
                                  zip(m.groups(), (10, 10, 16, 16, 16, 16, 16))))
    return recs                     # (idx, core, pc, direct, ts, tid, tstrb)


def grep1(path, pat):
    rx = re.compile(pat)
    with open_text(path) as f:
        for line in f:
            m = rx.search(line)
            if m:
                return m
    return None


def load_slots(path):
    slots = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            p = line.split()
            if len(p) >= 3:
                slots[int(p[1], 16)] = int(p[0])
    return slots


def counts_of(path):
    m = grep1(path, r"^COUNTS\s+records=(\d+) valid=(\d+) invalid=(\d+) "
                    r"malformed_words=(\d+) malformed_bytes=(\d+) "
                    r"wraps=(\d+) misses=(\d+) unmatched=(\d+)")
    if not m:
        return None
    keys = ("records", "valid", "invalid", "malformed_words",
            "malformed_bytes", "wraps", "misses", "unmatched")
    return dict(zip(keys, (int(x) for x in m.groups())))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", choices=("runa", "runb"))
    ap.add_argument("--work", required=True)
    a = ap.parse_args()
    W = a.work.rstrip("/\\")
    fails = []

    slots = load_slots(W + "/wp_table.txt")
    with open(W + "/expected_full.txt", encoding="utf-8") as f:
        nexp = sum(1 for line in f if line.strip())

    if a.mode == "runa":
        board = W + "/board_runA.log"
        m = grep1(board, r"RUN_STATE drops0=(\d+) drops1=(\d+) ovf0=(\d+) "
                         r"ovf1=(\d+) fill0=(\d+) fill1=(\d+) "
                         r"phase0=(\d+) phase1=(\d+)")
        if not m:
            fails.append("board_runA.log has no RUN_STATE")
        else:
            d0, d1, o0, o1, f0, f1, p0, p1 = (int(x) for x in m.groups())
            print("G1CHECK runA board: drops=%d/%d ovf=%d/%d fill=%d/%d "
                  "phase=%d/%d" % (d0, d1, o0, o1, f0, f1, p0, p1))
            if d0 or d1 or o0 or o1:
                fails.append("run A has drops/overflows (%d/%d/%d/%d)"
                             % (d0, d1, o0, o1))
            if p0 != 64 or p1 != 64:
                fails.append("SCRATCH phase != 64 (%d/%d)" % (p0, p1))
        for c in (0, 1):
            if not grep1(board, r"SCRATCH core%d .*end-of-walk marker" % c):
                fails.append("core%d has no end-of-walk marker" % c)

        streams = {}
        for c in (0, 1):
            log = W + "/runA_reader_fifo%d.log" % c
            cnt = counts_of(log)
            recs = parse_raw(log)
            streams[c] = recs
            if cnt is None:
                fails.append("fifo%d: COUNTS line missing" % c)
                continue
            print("G1CHECK runA fifo%d: records=%d (expected %d) raw=%d "
                  "invalid=%d malformed=%d+%dB wraps=%d misses=%d "
                  "unmatched=%d"
                  % (c, cnt["records"], nexp, len(recs), cnt["invalid"],
                     cnt["malformed_words"], cnt["malformed_bytes"],
                     cnt["wraps"], cnt["misses"], cnt["unmatched"]))
            if cnt["records"] != nexp or len(recs) != nexp:
                fails.append("fifo%d: count equality violated (%d/%d raw %d)"
                             % (c, cnt["records"], nexp, len(recs)))
            if (cnt["invalid"] or cnt["malformed_words"]
                    or cnt["malformed_bytes"] or cnt["misses"]
                    or cnt["unmatched"]):
                fails.append("fifo%d: reader counters not clean" % c)
            if not grep1(log, r"^RESULT\s+PASS"):
                fails.append("fifo%d: reader RESULT != PASS" % c)
            n_meta = 0
            for k, (_i, core, pc, direct, _ts, tid, tstrb) in enumerate(recs):
                s = slots.get(pc)
                if (core != c or s is None or direct != s or tid != 0x01
                        or tstrb != 0xFFF):
                    n_meta += 1
                    if n_meta <= 3:
                        print("G1CHECK runA fifo%d META-FAIL @%d: core=%d "
                              "pc=0x%08x direct=%s slot=%s tid=0x%02x "
                              "tstrb=0x%03x"
                              % (c, k, core, pc, direct, s, tid, tstrb))
            if n_meta:
                fails.append("fifo%d: %d W1/meta violations" % (c, n_meta))
            ts = [r[4] for r in recs]
            n_mono = sum(1 for k in range(1, len(ts)) if ts[k] <= ts[k - 1])
            if n_mono:
                fails.append("fifo%d: %d TS not strictly increasing" % (c, n_mono))

        if all(len(streams.get(c, [])) == nexp for c in (0, 1)):
            xmax = 0
            for k in range(nexp):
                d = abs(streams[0][k][4] - streams[1][k][4])
                xmax = max(xmax, d)
            print("G1CHECK runA cross-core: max|ts0[k]-ts1[k]| = %d "
                  "(tolerance 64, sim reference 0)" % xmax)
            if xmax > 64:
                fails.append("cross-core TS delta %d > 64" % xmax)
            i, j, prev, bad = 0, 0, -1, 0
            while i < nexp or j < nexp:
                if j >= nexp or (i < nexp
                                 and streams[0][i][4] <= streams[1][j][4]):
                    cur = streams[0][i][4]; i += 1
                else:
                    cur = streams[1][j][4]; j += 1
                if cur < prev:
                    bad += 1
                prev = cur
            print("G1CHECK runA merge: %d records, %d monotonicity violations"
                  % (2 * nexp, bad))
            if bad:
                fails.append("merge not monotone (%d violations)" % bad)

    else:  # runb
        board = W + "/board_runB.log"
        m = grep1(board, r"RUN_STATE drops0=(\d+) drops1=(\d+) ovf0=(\d+) "
                         r"ovf1=(\d+) fill0=(\d+) fill1=(\d+) "
                         r"phase0=(\d+) phase1=(\d+)")
        if not m:
            fails.append("board_runB.log has no RUN_STATE")
            print("G1CHECK FAIL: " + " | ".join(fails))
            sys.exit(1)
        d = [int(m.group(1)), int(m.group(2))]
        ovf = [int(m.group(3)), int(m.group(4))]
        ph = [int(m.group(7)), int(m.group(8))]
        tot = [0, 0]
        for c in (0, 1):
            # Flush = backlog pre-drain (see run_b.sh): its RESULT may be
            # FAIL (the era jump from stale backlog to fresh records reads
            # as "TS backwards" to the 32-bit wrap heuristic), its counters
            # and its record balance must still be clean.
            flush = counts_of(W + "/runB_flush_fifo%d.log" % c)
            leg = counts_of(W + "/runB_reader_fifo%d.log" % c)
            rest = counts_of(W + "/runB_rest_fifo%d.log" % c)
            if flush is None or leg is None or rest is None:
                fails.append("fifo%d: COUNTS missing (flush/leg/rest)" % c)
                continue
            for tag, cnt in (("flush", flush), ("leg", leg), ("rest", rest)):
                if (cnt["invalid"] or cnt["malformed_words"]
                        or cnt["malformed_bytes"] or cnt["misses"]
                        or cnt["unmatched"]):
                    fails.append("fifo%d %s: reader counters not clean"
                                 % (c, tag))
            for tag in ("runB_reader", "runB_rest"):
                if not grep1(W + "/%s_fifo%d.log" % (tag, c),
                             r"^RESULT\s+PASS"):
                    fails.append("fifo%d %s: RESULT != PASS" % (c, tag))
            recv = flush["records"] + leg["records"] + rest["records"]
            tot[c] = recv + d[c]
            prod = ph[c] * nexp / 64.0
            print("G1CHECK runB core%d: received=%d (flush %d + leg %d + "
                  "rest %d) drops=%d ovf=%d total=%d produced~%.0f "
                  "(phase=%d) wraps=%d+%d+%d"
                  % (c, recv, flush["records"], leg["records"],
                     rest["records"], d[c], ovf[c], tot[c], prod, ph[c],
                     flush["wraps"], leg["wraps"], rest["wraps"]))
            if abs(tot[c] - prod) > nexp:
                fails.append("core%d: balance |%d - %.0f| > %d"
                             % (c, tot[c], prod, nexp))
        if abs(tot[0] - tot[1]) > nexp:
            fails.append("balance inconsistent between cores (%d vs %d)"
                         % (tot[0], tot[1]))

    if fails:
        print("G1CHECK %s FAIL: %s" % (a.mode, " | ".join(fails)))
        sys.exit(1)
    print("G1CHECK %s PASS" % a.mode)


if __name__ == "__main__":
    main()
