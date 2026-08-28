#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Every file reference in scenarios.json points at a file that exists.

WHY THIS TEST EXISTS. A scenario whose `pcinfo` is missing cannot be spotted
as an error in the dashboard: the server falls back silently to a generic
stream (`server.py`: `demo/demo_trace_<id>.bin`, else `demo/demo_trace.bin`)
and the symbol table stays empty -- the page looks as it always does, but
shows addresses instead of names and decodes against a foreign program. That
is exactly how the `mbv` scenario passed as "present" for months although it
never had a recording of its own (field report 2026-08-18), and exactly how
`tgc5b2_axis_wp` pointed at paths that never existed here after the migration
into the TraceEncoder repository.

The test makes that state VISIBLE without colouring the stage permanently red:
known, named gaps sit in KNOWN_GAPS with a reason. It goes red on a NEW gap --
and equally when a gap has been closed without removing the entry (an allowlist
nobody maintains is a lie with an expiry date).

    py test_demo_assets.py

Exit 0 = as expected, 1 = a new gap or a stale KNOWN_GAPS entry.
"""
from __future__ import annotations

import json
import sys
import pathlib
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Known gaps: reference -> reason. Every entry is a promise that the gap is
# NAMED, not that it does not matter.
KNOWN_GAPS = {
    # Closed 2026-08-19: cva6_linux64, rocket64, rocket2 and cva6_2_rv64 were
    # recorded on kria-kv260 at pl_clk0 = 68.181818 MHz and their listings
    # built from the OpenSBI images that actually ran. See demo/README.md for
    # the per-dataset provenance and decode verdicts.
    # Updated 2026-08-19 22:20 with what was actually measured, because the
    # previous text ("no board recording yet") stopped being true that
    # evening and a gap description that lags reality is worse than none.
    "cva6_2_rv32_src0.pcinfo": "RV32 AMP variant: the guest images build (sw/build_payload_cva6_2.sh) and BOTH cores run on the board -- ~105 million retires in 3 s, ring full. But the capture does not decode: it aborts at message 7 with a decoder desynchronisation, and it does so for each source SEPARATELY, so it is not a source-splitting problem. Shipping a listing here would promise a decode that does not happen. Note also that the RV32 image is 44.8 MiB in a 32 MiB window (decision E7), so core 1's write overlaps core 0",
    "cva6_2_rv32_src1.pcinfo": "see cva6_2_rv32_src0.pcinfo",
    "cva6.pcinfo": "trio target 2 (CVA6 branch): the RV32 OpenSBI payload was staged into its DDR window on 2026-08-19 and the branch runs, but with the CVA6 encoder active the merged stream is no longer pure N-Trace -- a decode aborts at the framing (MSEO=10). The third encoder's protocol select is its own work package; until then a listing here would promise a decode that does not happen",
}

# Fields that point at files. Resolution as in the server: relative to HERE and
# to HERE/demo (server.py `pcinfo_path`), symbols/sites relative to HERE
# (`load_symbol_files`), wp_set relative to HERE (`wp_view.py`).
def candidates(value: str) -> list[Path]:
    return [HERE / value, HERE / "demo" / value]


def preload_inside_tree(scen: dict) -> list[str]:
    """Every preload path must lie INSIDE the dashboard directory.

    Why this is a check of its own: the board rollout copies this directory
    and nothing else. A preload path with `../` points nowhere on the board,
    and the error is silent -- the cores then run with whatever the fabric
    left behind. Measured 2026-08-19: `hello_trace.hex` sat outside, and a
    trio run delivered 40 bytes of trace instead of 7.5 million.
    """
    bad = []
    for target, value in (scen.get("preload") or {}).items():
        if not isinstance(value, str):
            continue
        if value.startswith("/") or ".." in pathlib.PurePosixPath(value).parts:
            bad.append("%-16s preload.%-5s %s" % (scen.get("id", "?"), target, value))
    return bad


def collect(scen: dict) -> list[tuple[str, str]]:
    """(field, value) per file reference of a scenario."""
    out: list[tuple[str, str]] = []
    for key in ("symbols", "sites"):
        if scen.get(key):
            out.append((key, scen[key]))
    pre = scen.get("preload") or {}
    for k, v in pre.items():
        if isinstance(v, str):
            out.append(("preload.%s" % k, v))
    dec = scen.get("decode") or {}
    for t in dec.get("targets", []):
        for key in ("pcinfo", "live_pcinfo"):
            if t.get(key):
                out.append(("decode.%s" % key, t[key]))
    wp = scen.get("wp") or {}
    for key in ("set", "wp_set"):
        if isinstance(wp.get(key), str):
            out.append(("wp.%s" % key, wp[key]))
    return out


def main() -> int:
    data = json.loads((HERE / "scenarios.json").read_text(encoding="utf-8"))
    missing: list[str] = []
    seen_gap: set[str] = set()
    checked = 0

    for scen in data["scenarios"]:
        sid = scen["id"]
        for field, value in collect(scen):
            checked += 1
            if any(c.is_file() for c in candidates(value)):
                continue
            base = value.rsplit("/", 1)[-1]
            if base in KNOWN_GAPS:
                seen_gap.add(base)
                continue
            missing.append("%-16s %-18s %s" % (sid, field, value))

    # bitbin is deliberately NOT checked: the .bit.bin is a bootgen output that
    # never lives in the repository. The value is also set by scenario.py and
    # never read -- reported here so that this does not get forgotten.
    stale = sorted(set(KNOWN_GAPS) - seen_gap)
    outside = [b for scen in data["scenarios"] for b in preload_inside_tree(scen)]

    print("[test_demo_assets] %d references checked, %d known gaps, %d new"
          % (checked, len(seen_gap), len(missing)))
    for line in outside:
        print("  OUTSIDE  %s -- the board rollout copies only this"
              " directory" % line)
    for line in missing:
        print("  MISSING  %s" % line)
    for base in stale:
        print("  STALE  KNOWN_GAPS['%s'] -- the file is there, the entry has to go" % base)

    if missing or stale or outside:
        print("[test_demo_assets] FAIL")
        return 1
    print("[test_demo_assets] OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
