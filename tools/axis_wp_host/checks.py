#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""checks.py -- checks on the watchpoint record stream (RV/CFI pre-stage).

Four checks (PLAN_axis_wp_testbed.md §3a B6):

(a) TS monotonicity per core ID, selectable mode (F1, G0 finding 1c):
      * "wrap"   (default) -- wrap heuristic as described below;
      * "strict" -- numerically strictly increasing, a wrap is a
                    violation (for short windows in which the counter
                    is certain not to wrap);
      * "off"    -- no check (the encoder state before C0a delivers no
                    TS element, W2 == 0 for all records -- strict
                    monotonicity is then necessarily violated).
    WRAP HEURISTIC (documented decision): the timestamp is a free-running
    32-bit counter (wraps every ~43 s at 100 MHz). For two consecutive
    records of the same core, the MODULAR forward distance
    d = (ts_new - ts_old) mod 2^32 is formed:
      * d == 0            -> violation (strict monotonicity required)
      * 0 < d < 2^31      -> forward, OK; if ts_new is numerically less
                             than ts_old in this case, a wrap has
                             occurred (counted)
      * d >= 2^31         -> backward step -> violation
    The difference window of 2^31 (half the counter range) is the usual
    sequence-number arithmetic (RFC-1982-style): true backward steps up
    to 2^31-1 are detected, true forward jumps >= 2^31 (>= ~21 s of
    silence in a row) would be falsely reported as a backward step --
    irrelevant for the demo walk (timer-IRQ cadence in the ms range).

(b) PC membership in an expected address set.
    FILE-FORMAT ASSUMPTION (the file is only produced in package E0,
    compatible with `sw/axis_wp_demo/wp_set.txt`): one address per line,
    first whitespace token = `0x<hex>` (rest of the line = comment/symbol
    name, ignored); blank lines and `#` lines are skipped.

(c) Sequence check against an expected hit sequence (`expected_hits.txt`,
    same line format as (b), order significant).
    DECISION: cursor merge (greedy) instead of full LCS. The shim may
    DROP records (drop counter, D0), but never reorder or invent them --
    so the observed sequence must be a SUBSEQUENCE of the expected one.
    The greedy cursor is exact for the subsequence test (unmatched == 0
    <=> observed is a subsequence of expected) and linear; if
    unmatched > 0, every record that cannot be placed is reported
    individually (the cursor stays put, i.e. a foreign record does not
    desynchronize the sequence check). Full LCS (O(n*m)) would only give
    sharper diagnostics on massively corrupted streams and is
    deliberately not built.
    `cycle=True` treats the oracle as periodic (endless walk; details in
    the check_sequence docstring, F1).

(d) Two-(N-)stream merge by TS: for each stream, the 32-bit TS is
    unrolled to a 64-bit value with the same wrap heuristic as (a) (each
    wrap adds 2^32), then a stable merge by (ts64, core_id) -- on a TS
    tie, the lower core (core 0) comes first. Precondition: both streams
    start in the same wrap epoch (shared fabric counter, PLAN §3a B3 --
    given on the board via synchronous start; documented assumption).
"""
from __future__ import annotations

TS_MOD = 1 << 32
TS_FWD_WINDOW = 1 << 31   # modular distance < 2^31 == forward step


# ---------------------------------------------------------------------------
# (a) TS monotonicity per core
# ---------------------------------------------------------------------------

class TsCheckResult:
    __slots__ = ("ok", "violations", "wraps_per_core", "n_checked")

    def __init__(self):
        self.ok = True
        self.violations: list[str] = []
        self.wraps_per_core: dict[int, int] = {}
        self.n_checked = 0

    @property
    def wraps(self) -> int:
        return sum(self.wraps_per_core.values())


TS_MODES = ("strict", "wrap", "off")


def check_ts_monotonic(records, mode: str = "wrap") -> TsCheckResult:
    """TS strictly monotonic per core; see module docstring (a) for `mode`.

    "off" checks nothing (ok=True, n_checked=0); an unknown mode is a
    tool error (ValueError), not a stream error.
    """
    if mode not in TS_MODES:
        raise ValueError("unknown ts mode: %r (use one of %s)"
                         % (mode, "/".join(TS_MODES)))
    res = TsCheckResult()
    if mode == "off":
        return res
    last: dict[int, tuple] = {}   # core -> (ts, record_index)
    for r in records:
        if not r.valid:
            continue
        prev = last.get(r.core_id)
        if prev is not None:
            res.n_checked += 1
            # "strict": purely numeric (no window, no wrap allowed);
            # "wrap":   modular forward distance with a 2^31 window.
            d = (r.ts - prev[0]) % TS_MOD
            backwards = (r.ts < prev[0]) if mode == "strict" \
                else (d != 0 and d >= TS_FWD_WINDOW)
            if d == 0:
                res.ok = False
                res.violations.append(
                    "core %d: TS not strictly monotonic (equal): "
                    "0x%08X at #%d == at #%d"
                    % (r.core_id, r.ts, r.index, prev[1]))
            elif backwards:
                res.ok = False
                res.violations.append(
                    "core %d: TS backwards: 0x%08X at #%d after 0x%08X at #%d"
                    % (r.core_id, r.ts, r.index, prev[0], prev[1]))
            elif mode == "wrap" and r.ts < prev[0]:
                # accepted forward step + numerically smaller == wrap
                res.wraps_per_core[r.core_id] = \
                    res.wraps_per_core.get(r.core_id, 0) + 1
        last[r.core_id] = (r.ts, r.index)
    return res


def unwrap_ts(records) -> list:
    """[(record, ts64)] -- TS per stream unrolled to 64 bit (wraps add 2^32).

    Expects records of ONE core in stream order. Backward steps
    (monotonicity violations) do not advance the epoch -- the merge stays
    best-effort ordered, and check_ts_monotonic reports the violations.
    """
    out = []
    epoch = 0
    prev_ts = None
    for r in records:
        if not r.valid:
            continue
        if prev_ts is not None:
            d = (r.ts - prev_ts) % TS_MOD
            if 0 < d < TS_FWD_WINDOW and r.ts < prev_ts:
                epoch += TS_MOD
        out.append((r, epoch + r.ts))
        prev_ts = r.ts
    return out


# ---------------------------------------------------------------------------
# (b) PC membership
# ---------------------------------------------------------------------------

def load_addr_file(path: str) -> list:
    """Load an address list; `#` lines and blank lines are ignored.

    Per line, the FIRST token starting with `0x` counts -- this covers
    both formats that actually exist (F1; the original F0 assumption
    "first token = address" did not match E0's delivery):
      * `sw/axis_wp_demo/wp_set.txt`:        `0x<addr8> <name>`
      * `sw/axis_wp_demo/expected_hits.txt`: `P<phase> <seq> 0x<addr8> <name>`
    Returns the addresses in file order (use as a set() for (b), while
    (c) relies on the order). Lines without a parsable `0x` token raise
    ValueError with the line number -- a broken reference file is a tool
    error, not a stream error.
    """
    addrs = []
    with open(path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            toks = [t for t in s.split() if t[:2].lower() == "0x"]
            if not toks:
                raise ValueError("%s:%d: no 0x address token: %r"
                                 % (path, lineno, s.split()[0]))
            try:
                addrs.append(int(toks[0], 16) & 0xFFFFFFFF)
            except ValueError:
                raise ValueError("%s:%d: not an address: %r"
                                 % (path, lineno, toks[0]))
    return addrs


class MembershipResult:
    __slots__ = ("ok", "misses", "n_checked")

    def __init__(self):
        self.ok = True
        self.misses: list = []      # records with PC outside the set
        self.n_checked = 0


def check_pc_membership(records, wp_set) -> MembershipResult:
    """The PC of every valid record must lie in the set `wp_set`."""
    wp_set = set(wp_set)
    res = MembershipResult()
    for r in records:
        if not r.valid:
            continue
        res.n_checked += 1
        if r.pc not in wp_set:
            res.ok = False
            res.misses.append(r)
    return res


# ---------------------------------------------------------------------------
# (c) Sequence check (cursor merge, drop-tolerant)
# ---------------------------------------------------------------------------

class SequenceResult:
    __slots__ = ("ok", "matched", "unmatched", "expected_consumed",
                 "n_expected", "cycles")

    def __init__(self, n_expected: int):
        self.ok = True
        self.matched = 0
        self.unmatched: list = []       # (record, expected_cursor) per miss
        self.expected_consumed = 0      # cursor position in the current pass
        self.n_expected = n_expected
        self.cycles = 0                 # oracle repeats (cycle=True only)


def check_sequence(records, expected, cycle: bool = False) -> SequenceResult:
    """The observed PC sequence must be a subsequence of the expected one.

    Greedy cursor (exact subsequence test, decision see module docstring):
    for every valid record, the cursor in `expected` is advanced until the
    PC hits; if it does not hit before the end, the record is reported as
    unmatched and the cursor is NOT moved (a foreign record does not
    desynchronize it). Dropped records (shim drops) show up as skipped
    expected entries and are NOT an error.

    `cycle=True` (F1): the oracle is PERIODIC (endless walk repeats the
    file from the first line -- the header of expected_hits.txt). If the
    cursor runs past the end, one further lap is searched from index 0 up
    to the old cursor position; a hit counts up `cycles`. Greedy stays
    exact even cyclically (the earliest embedding leaves the remainder
    maximum leeway); a foreign record then misses the entire cycle and
    still does not desynchronize.
    """
    expected = list(expected)
    res = SequenceResult(len(expected))
    cur = 0
    for r in records:
        if not r.valid:
            continue
        j = cur
        while j < len(expected) and expected[j] != r.pc:
            j += 1
        if j >= len(expected) and cycle and expected:
            j = 0
            while j < cur and expected[j] != r.pc:
                j += 1
            if j < cur:
                res.cycles += 1
                res.matched += 1
                cur = j + 1
                continue
            res.ok = False
            res.unmatched.append((r, cur))
            continue
        if j < len(expected):
            res.matched += 1
            cur = j + 1
        else:
            res.ok = False
            res.unmatched.append((r, cur))
    res.expected_consumed = cur
    return res


# ---------------------------------------------------------------------------
# (d) Merge of two (multiple) core streams by TS
# ---------------------------------------------------------------------------

def merge_streams(streams_by_core: dict) -> list:
    """Merge records of multiple cores by unrolled TS.

    `streams_by_core` = {core_id: [Record, ...]} (each core in stream
    order). Result: a list of records sorted by (ts64, core_id) -- on a
    TS tie, the lower core stably comes first (core 0 before core 1).
    Within one core the stream order is preserved (the sort is stable,
    and the key per core is strictly increasing except where a
    monotonicity violation was reported).
    """
    tagged = []
    for core in sorted(streams_by_core):
        for r, ts64 in unwrap_ts(streams_by_core[core]):
            tagged.append((ts64, core, r))
    tagged.sort(key=lambda t: (t[0], t[1]))
    return [t[2] for t in tagged]
