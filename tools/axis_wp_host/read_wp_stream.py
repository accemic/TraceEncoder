#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""read_wp_stream.py -- read, check, and report the watchpoint record stream.

    # offline (file with raw 32-bit LE words, e.g. sim/board dump):
    py read_wp_stream.py --source file --in stream.bin \
        --wp-set wp_set.txt --expected expected_hits.txt --core merge

    # on the board (root; base address is fixed by package D1, NEVER
    # hardcoded here):
    sudo python3 read_wp_stream.py --source fifo --base 0xA0010000 \
        --wp-set wp_set.txt --core 0

    # continuous run (10 ms poll, 30 s budget; Ctrl-C ends it cleanly):
    sudo python3 read_wp_stream.py --source fifo --base 0xA0010000 \
        --poll-ms 10 --duration-s 30

FIFO behavior (F1, findings G0 1a/1b):
  * Attaching is NON-DESTRUCTIVE -- already buffered records are kept;
    `--reset` explicitly resets the RX side beforehand (PG080 RDFR,
    discards the buffer!).
  * By default the loop reads ONCE until the first empty RDFO (a
    snapshot of the backlog). `--poll-ms`/`--duration-s` switch to
    continuous mode: empty windows do not end it, polling continues
    until the time budget (`--duration-s`), the record limit
    (`--max-records`), or Ctrl-C/SIGTERM (the last backlog is still
    drained, then the checks run) -- without any of the three, the
    continuous run goes on FOREVER.

Checks and exit code:
  * ALWAYS active: stream integrity (no invalid records, no malformed
    remainder).
  * TS monotonicity per core via `--ts-mode` (F1, finding G0 1c):
    `wrap` (default) = heuristic with 32-bit wrap (a wrap is NOT an
    error, it is counted), `strict` = numerically strictly increasing
    without wrap, `off` = no TS check (encoder state before C0a: W2 == 0).
  * `--wp-set`   enables the PC membership check.
  * `--expected` enables the sequence check -- PER CORE against the same
    file (both cores run the same walk in the demo; drop-tolerant cursor
    merge, see checks.py); `--expected-cycle` treats the sequence as
    periodic (endless walk, oracle file == one pass).
  * Exit code 0 only if ALL enabled checks are green.

`--core <n>` restricts checking+output to one core; `--core merge`
(default) checks all cores and prints the per-TS merged sequence
(tie: core 0 first).
"""
from __future__ import annotations

import argparse
import os
import signal
import sys

if __package__:
    from . import checks, fifo_mm_s, wp_records
else:                                    # direct invocation `py read_wp_stream.py`
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import checks
    import fifo_mm_s
    import wp_records


def _install_stop():
    """SIGINT/SIGTERM -> stop flag (clean continuous-run abort, F1).

    Returns (stop_callable, restore_callable). While the handler is
    installed, NO KeyboardInterrupt is raised -- drain_poll drains the
    last backlog and the checks run over what was already read.
    """
    flag = {"stop": False}
    olds = {}

    def _handler(signum, frame):
        flag["stop"] = True

    for signame in ("SIGINT", "SIGTERM"):
        signum = getattr(signal, signame, None)
        if signum is None:
            continue
        try:
            olds[signum] = signal.signal(signum, _handler)
        except (ValueError, OSError):        # e.g. not on the main thread
            pass

    def _restore():
        for signum, old in olds.items():
            signal.signal(signum, old)

    return (lambda: flag["stop"]), _restore


def _acquire_words(args):
    """Get a word list + (DrainStats | None) from file or FIFO."""
    if args.source == "file":
        if not getattr(args, "infile", None):
            raise SystemExit("--source file requires --in <file>")
        with open(args.infile, "rb") as f:
            return f.read(), None
    base = int(args.base, 16) if isinstance(args.base, str) else args.base
    if base is None:
        raise SystemExit("--source fifo requires --base <hex>")
    fifo = fifo_mm_s.open_devmem_fifo(base, reset_on_init=args.reset)
    fifo.init()
    if args.poll_ms is not None or args.duration_s is not None:
        poll_s = (args.poll_ms if args.poll_ms is not None else 10.0) / 1000.0
        stop, restore = _install_stop()
        try:
            words, stats = fifo.drain_poll(
                poll_s, duration_s=args.duration_s,
                max_records=args.max_records, stop=stop)
        finally:
            restore()
    else:
        words, stats = fifo.drain(max_packets=args.max_records)
    return words, stats


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="read_wp_stream.py",
        description="Read and check AXIS watchpoint records (F0/F1)")
    ap.add_argument("--source", choices=("file", "fifo"), default="file")
    ap.add_argument("--in", dest="infile", metavar="FILE",
                    help="raw file (32-bit LE words) for --source file")
    ap.add_argument("--base", metavar="HEX",
                    help="axi_fifo_mm_s base address for --source fifo")
    ap.add_argument("--reset", action="store_true",
                    help="FIFO: reset the RX side BEFORE reading "
                         "(PG080 RDFR -- DISCARDS buffered records; "
                         "default attaches non-destructively)")
    ap.add_argument("--wp-set", dest="wp_set", metavar="FILE",
                    help="expected address set (first 0x token per line)")
    ap.add_argument("--expected", metavar="FILE",
                    help="expected hit sequence (expected_hits.txt)")
    ap.add_argument("--expected-cycle", dest="expected_cycle",
                    action="store_true",
                    help="hit sequence is periodic (endless walk; "
                         "--expected describes ONE pass)")
    ap.add_argument("--ts-mode", dest="ts_mode", default="wrap",
                    choices=checks.TS_MODES,
                    help="TS monotonicity: wrap = 32-bit wrap heuristic "
                         "(default), strict = strictly increasing without "
                         "wrap, off = no TS check (W2==0 before C0a)")
    ap.add_argument("--core", default="merge", metavar="N|merge",
                    help="core filter, or merge (default)")
    ap.add_argument("--raw", action="store_true",
                    help="print every record individually")
    ap.add_argument("--max-records", "--max-packets", dest="max_records",
                    type=int, default=0, metavar="N",
                    help="FIFO: read at most N records (0 = no limit; "
                         "1 packet == 1 record)")
    ap.add_argument("--poll-ms", dest="poll_ms", type=float, default=None,
                    metavar="MS",
                    help="FIFO continuous run: poll interval; empty "
                         "windows then do NOT end it (end: --duration-s / "
                         "--max-records / Ctrl-C)")
    ap.add_argument("--duration-s", dest="duration_s", type=float,
                    default=None, metavar="S",
                    help="FIFO continuous run: time budget (implies "
                         "polling, default interval 10 ms)")
    return ap


def run(argv) -> int:
    args = build_parser().parse_args(argv)

    data, drain_stats = _acquire_words(args)
    res = (wp_records.parse_bytes(data) if isinstance(data, (bytes, bytearray))
           else wp_records.parse_words(data))
    by_core = wp_records.split_by_core(res.records)

    # -- core selection -------------------------------------------------------
    if args.core != "merge":
        try:
            core_sel = int(args.core, 0)
        except ValueError:
            raise SystemExit("--core expects a number or `merge`")
        by_core = {core_sel: by_core.get(core_sel, [])}
        view = by_core[core_sel]
    else:
        view = checks.merge_streams(by_core)

    fails = []

    # -- integrity (always active) -------------------------------------------
    if res.n_invalid:
        fails.append("invalid records: %d" % res.n_invalid)
        for r in res.records:
            if not r.valid:
                print("INVALID  %r" % r)
    if res.n_malformed_words or res.n_malformed_bytes:
        fails.append("malformed tail: %d words + %d bytes"
                     % (res.n_malformed_words, res.n_malformed_bytes))

    # -- TS monotonicity per core (mode via --ts-mode, off = no check) --------
    wraps = 0
    if args.ts_mode != "off":
        for core in sorted(by_core):
            ts_res = checks.check_ts_monotonic(by_core[core], mode=args.ts_mode)
            wraps += ts_res.wraps
            if not ts_res.ok:
                fails.append("core %d: %d TS violations"
                             % (core, len(ts_res.violations)))
                for v in ts_res.violations:
                    print("TS-FAIL  %s" % v)

    # -- PC membership (active with --wp-set) ---------------------------------
    misses = 0
    if args.wp_set:
        wp_set = set(checks.load_addr_file(args.wp_set))
        mem_res = checks.check_pc_membership(view, wp_set)
        misses = len(mem_res.misses)
        if not mem_res.ok:
            fails.append("PC membership: %d misses" % misses)
            for r in mem_res.misses:
                print("MISS     %r" % r)

    # -- sequence per core (active with --expected) ---------------------------
    unmatched = 0
    if args.expected:
        exp = checks.load_addr_file(args.expected)
        for core in sorted(by_core):
            seq_res = checks.check_sequence(by_core[core], exp,
                                            cycle=args.expected_cycle)
            unmatched += len(seq_res.unmatched)
            print("SEQ      core %d: matched=%d unmatched=%d "
                  "expected_consumed=%d/%d%s"
                  % (core, seq_res.matched, len(seq_res.unmatched),
                     seq_res.expected_consumed, seq_res.n_expected,
                     " cycles=%d" % seq_res.cycles
                     if args.expected_cycle else ""))
            if not seq_res.ok:
                fails.append("core %d: %d records not in expected sequence"
                             % (core, len(seq_res.unmatched)))
                for r, cur in seq_res.unmatched:
                    print("SEQ-FAIL core %d at expected[%d]: %r" % (core, cur, r))

    # -- output -----------------------------------------------------------
    if args.raw:
        for r in view:
            print("%r" % r)

    if drain_stats is not None:
        print("FIFO     packets=%d words=%d partial=%d zero_len=%d polls=%d"
              % (drain_stats.n_packets, drain_stats.n_words,
                 drain_stats.n_partial, drain_stats.n_zero_len,
                 drain_stats.n_polls))
    print("COUNTS   records=%d valid=%d invalid=%d malformed_words=%d "
          "malformed_bytes=%d wraps=%d misses=%d unmatched=%d cores=%s "
          "ts_mode=%s"
          % (res.n_records, res.n_valid, res.n_invalid,
             res.n_malformed_words, res.n_malformed_bytes, wraps, misses,
             unmatched, ",".join(str(c) for c in sorted(by_core)),
             args.ts_mode))
    if fails:
        print("RESULT   FAIL: " + " | ".join(fails))
        return 1
    print("RESULT   PASS")
    return 0


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
