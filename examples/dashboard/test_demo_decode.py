#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Decode every shipped demo capture and check the verdict, not just the file.

    py test_demo_decode.py

`test_demo_assets.py` proves that the files a scenario names EXIST. That is a
different question from whether they still decode. A trace and a listing can
both be present and no longer belong together -- a rebuilt guest image, a
listing regenerated from a different ELF, a capture replaced by a shorter one.
Nothing in the repository would notice, and the dashboard would quietly show
fewer instructions.

So this test runs the real decoder over each shipped capture and requires:

  * the decoder says "Decoded OK",
  * it reports **zero** error messages,
  * and the instruction count is at least the floor recorded below.

THE FLOOR IS NOT A TARGET, IT IS A TRIPWIRE. The numbers are what the captures
produced on 2026-08-19 (see demo/README.md for their provenance), rounded down
to leave room for a decoder that legitimately gets better. A count that falls
BELOW means trace, listing and decoder no longer agree -- and that is the
failure this test exists to make loud.

A MISSING DECODER IS A FAILURE, NOT A SKIP. The lesson is paid for: a decode
check that "skips" when its tool is absent reports PASS in a warm tree,
because it compares against output an earlier run left behind. Run
`py scripts/fetch_cttd.py` (the pinned, sha256-verified build) first.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]

# scenario id -> (trace file, [(target, pcinfo)], srcbits, instruction floor)
CASES = {
    "mbv":          ("demo_trace_mbv.bin",          [(None, "mbv.pcinfo")],           0,       10_000),
    "duo":          ("demo_trace_duo.bin",          [(0, "mbv.pcinfo"),
                                                     (1, "tgc.pcinfo")],              2,    2_700_000),
    "trio":         ("demo_trace_trio.bin",         [(0, "mbv.pcinfo"),
                                                     (1, "tgc.pcinfo")],              2,    2_700_000),
    "cva6_linux":   ("demo_trace_cva6_linux.bin",   [(None, "cva6_linux.pcinfo")],    0,    1_200_000),
    "cva6_linux64": ("demo_trace_cva6_linux64.bin", [(None, "cva6_linux64.pcinfo")],  0,      270_000),
    "rocket64":     ("demo_trace_rocket64.bin",     [(None, "rocket64.pcinfo")],      0,      270_000),
    "rocket2":      ("demo_trace_rocket2.bin",      [(0, "rocket2.pcinfo"),
                                                     (1, "rocket2.pcinfo")],          2,    1_700_000),
    "cva6_2_rv64":  ("demo_trace_cva6_2_rv64.bin",  [(0, "cva6_linux64.pcinfo"),
                                                     (1, "cva6_linux64.pcinfo")],     2,      440_000),
}


def decoder() -> Path | None:
    names = ("cttd-windows-x64.exe", "cttd-linux-x86_64", "cttd-linux-arm64",
             "cttd.exe", "cttd")
    for base in (REPO / "bin", HERE / "bin"):
        for n in names:
            p = base / n
            if p.is_file():
                return p
    return None


def run_case(cttd: Path, sid: str, spec) -> tuple[bool, str]:
    trace_name, targets, srcbits, floor = spec
    trace = HERE / "demo" / trace_name
    if not trace.is_file():
        return False, "capture missing: %s" % trace_name
    cmd = [str(cttd), "-deco", str(trace)]
    with tempfile.TemporaryDirectory() as td:
        if srcbits:
            cmd += ["-src", str(srcbits)]
            for tgt, pci in targets:
                pcp = HERE / "demo" / pci
                if not pcp.is_file():
                    return False, "listing missing: %s" % pci
                cmd += ["-target", str(tgt), "-pcinfo", str(pcp),
                        "-pcout", str(Path(td) / ("t%d.pcout" % tgt))]
        else:
            pcp = HERE / "demo" / targets[0][1]
            if not pcp.is_file():
                return False, "listing missing: %s" % targets[0][1]
            cmd += ["-pcinfo", str(pcp), "-pcout", str(Path(td) / "t.pcout")]
        cmd += ["-stat"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        out = (r.stdout or "") + (r.stderr or "")

    if "Decoded OK" not in out:
        first = next((l for l in out.splitlines() if "ERROR" in l), "no ERROR line")
        return False, "decode did not report OK -- %s" % first.strip()

    errs = re.findall(r"(\d+) error messages", out)
    if errs and any(int(e) for e in errs):
        return False, "decoder reported %s error messages" % "/".join(errs)

    total = 0
    for m in re.finditer(r"target \d+: (\d+) instr", out):
        total += int(m.group(1))
    if total == 0:
        m = re.search(r"Decoded OK \((\d+) instructions\)", out)
        total = int(m.group(1)) if m else 0
    if total < floor:
        return False, "%d instructions, floor is %d" % (total, floor)
    return True, "%d instructions, 0 errors" % total


def main() -> int:
    cttd = decoder()
    if cttd is None:
        print("[test_demo_decode] FAIL -- no CTTD binary in bin/.")
        print("  A decode check without its decoder is not a skip, it is a")
        print("  false green: run `py scripts/fetch_cttd.py` first.")
        return 1

    data = json.loads((HERE / "scenarios.json").read_text(encoding="utf-8"))
    known = {s["id"] for s in data["scenarios"]}
    bad = 0
    print("[test_demo_decode] decoder: %s" % cttd.name)
    for sid, spec in CASES.items():
        if sid not in known:
            print("  FAIL  %-14s scenario id is not in scenarios.json" % sid)
            bad += 1
            continue
        ok, note = run_case(cttd, sid, spec)
        print("  %-5s %-14s %s" % ("PASS" if ok else "FAIL", sid, note))
        bad += 0 if ok else 1

    missing = sorted(
        s["id"] for s in data["scenarios"]
        if s["id"] not in CASES and (HERE / "demo" / ("demo_trace_%s.bin" % s["id"])).is_file())
    for sid in missing:
        print("  FAIL  %-14s has a capture but no entry here -- add one, or the"
              " capture is unverified" % sid)
        bad += 1

    print("[test_demo_decode] %s (%d of %d cases failed)"
          % ("OK" if not bad else "FAIL", bad, len(CASES) + len(missing)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
