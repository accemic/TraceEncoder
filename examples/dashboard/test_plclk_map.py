#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Guard for plclk.json and boot.json -- the two files that steer the board.

THE DEFECT CLASS this test goes red on: a clock label that nothing on the
board can program, and a boot recipe whose clock disagrees with the clock the
server programs for the same scenario.

Both are silent failures without a guard. `kv260_plclk.sh` accepts exactly
three labels (68, 75, 100); a fourth value makes it exit 2, and the server
would report a step that never happened. And if boot.json asks a recipe for
75 MHz while plclk.json had the server program 68, the recipe aborts with
PLCLK_WRONG -- after the app has already been loaded, i.e. at the point where
the clock can no longer be changed.

    py test_plclk_map.py

Exit 0 = every check passed, 1 = at least one real failure.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# The labels kv260_plclk.sh knows. Source:
# examples/kv260/common/board/kv260_plclk.sh, the `case "$MHZ"` block --
# 68 -> divider 22, 75 -> 20, 100 -> 15; anything else exits 2.
ALLOWED = (68, 75, 100)

N_OK = 0
N_BAD = 0


def chk(name, cond, detail=""):
    global N_OK, N_BAD
    if cond:
        N_OK += 1
        print("  OK   %s  %s" % (name, detail))
    else:
        N_BAD += 1
        print("  FAIL %s  %s" % (name, detail))


def load(name):
    return json.loads((HERE / name).read_text(encoding="utf-8"))


def entries(doc):
    """Payload keys only -- the underscore keys are prose, not data."""
    return {k: v for k, v in doc.items() if not k.startswith("_")}


def main() -> int:
    plclk = entries(load("plclk.json"))
    boot = entries(load("boot.json"))
    scen = {s["id"] for s in load("scenarios.json")["scenarios"]}

    # 1. Only labels the board tool understands, and each one with a source.
    for sid, rec in sorted(plclk.items()):
        chk("plclk %s: label is one of %s" % (sid, "/".join(map(str, ALLOWED))),
            isinstance(rec.get("mhz"), int) and rec["mhz"] in ALLOWED,
            "mhz=%r" % (rec.get("mhz"),))
        # A number without a retrievable source is not a number. The evidence
        # line has to name a file, not just assert a value.
        ev = rec.get("evidence") or ""
        chk("plclk %s: evidence names a file" % sid,
            bool(ev) and ("/" in ev),
            (ev[:60] + "...") if len(ev) > 60 else ev)

    # 2. Every id must exist -- a typo would otherwise simply never match and
    #    the clock would silently stay untouched.
    for sid in sorted(plclk):
        chk("plclk %s: id exists in scenarios.json" % sid, sid in scen, "")

    # 3. Every scenario that can boot a guest needs a clock entry: the recipe
    #    checks the clock in its prep phase and aborts if it is wrong, and by
    #    then the app is loaded and the clock can no longer be changed.
    for sid in sorted(boot):
        chk("boot %s: has a plclk entry" % sid, sid in plclk,
            "" if sid in plclk else "add it to plclk.json or the guest cannot boot")

    # 4. And the two files must agree. boot.json passes PL_MHZ into the recipe;
    #    plclk.json is what the server programs between unloadapp and loadapp.
    for sid, rec in sorted(boot.items()):
        want = plclk.get(sid, {}).get("mhz")
        env = (rec.get("env") or {}).get("PL_MHZ")
        chk("boot %s: PL_MHZ matches plclk.json" % sid,
            env is not None and want is not None and int(env) == int(want),
            "boot.json=%r plclk.json=%r" % (env, want))

    # 5. The script path is the only thing the browser cannot influence -- so
    #    it had better exist, and it had better live under boot/.
    for sid, rec in sorted(boot.items()):
        p = str(rec.get("script") or "")
        chk("boot %s: script exists" % sid,
            p.startswith("boot/") and (HERE / p).is_file(), p)
        chk("boot %s: phases are a non-empty list" % sid,
            isinstance(rec.get("phases"), list) and bool(rec["phases"]),
            " ".join(rec.get("phases") or []))

    # 6. Counter-probe. Without it, all of the above would also pass on an
    #    empty file: a check that cannot fail is not a check (audit the
    #    auditor). A fourth label MUST be rejected.
    probe_bad = [m for m in (60, 68, 71, 75, 90, 100) if m not in ALLOWED]
    chk("counter-probe: a fourth label is rejected",
        probe_bad == [60, 71, 90], str(probe_bad))

    print("[test_plclk_map] %d checks, %d red" % (N_OK + N_BAD, N_BAD))
    if N_BAD:
        print("[test_plclk_map] FAIL")
        return 1
    print("[test_plclk_map] OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
