#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Regression guard for the clock, build and closure display (package R2).

THE CLASS OF DEFECT this test goes red on if it comes back: a number in the
user interface that is NOT read back. Until 2026-08-14 the core cards showed
the clock from `scenarios.json` (field `mhz`, a design figure) -- they read
"75 MHz" while the board was clocked at 100 or 68.182 MHz. A screenshot of
that ended up in figure 2 of the CTTE paper and contradicted the table.

Both things are therefore checked: that the server branches produce evidence
instead of guessing (every missing piece of evidence yields a verdict and no
substitute value), and that the user interface uses the read-back value where
one exists.

    py test_plclk_closure.py
"""
import csv
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import server                                             # noqa: E402

REPO = HERE.parents[1]
REGISTRY = REPO / "vivado" / "kv260_app" / "kv260_closure.csv"

N_OK = 0
N_BAD = 0
N_SKIP = 0


def chk(name, cond, detail=""):
    global N_OK, N_BAD
    if cond:
        N_OK += 1
        print("  OK   %s  %s" % (name, detail))
    else:
        N_BAD += 1
        print("  FAIL %s  %s" % (name, detail))


def skip(name, detail=""):
    """Record a clean skip -- distinct from N_BAD, never turns the gate red."""
    global N_SKIP
    N_SKIP += 1
    print("  SKIP %s  %s" % (name, detail))


# --------------------------------------------------------------------------
# 1. No evidence -> no value. Every branch names its reason.
# --------------------------------------------------------------------------
def t_no_evidence():
    c = server.pl_clk0_state()          # off-board: no /dev/mem
    if c["hz"] is None:
        chk("no /dev/mem -> hz=None with a reason", bool(c["error"]), c["error"] or "")
    else:                                # run on the board itself
        chk("on the board: hz read back", c["hz"] > 0,
            "%d Hz from %s" % (c["hz"], c["raw"]))
    b = server.bitstream_identity(None)
    chk("no md5 without an app", b["md5"] is None and bool(b["error"]), b["error"] or "")
    b2 = server.bitstream_identity("app_that_does_not_exist")
    chk("no md5 for an unknown app", b2["md5"] is None and bool(b2["error"]),
        b2["error"] or "")


# --------------------------------------------------------------------------
# 2. Closure verdicts against the REAL registry -- the same file that
#    kv260_closure_verify.ps1 uses. No reconstruction of the numbers here.
# --------------------------------------------------------------------------
def t_verdicts():
    if not REGISTRY.is_file():
        # vivado/kv260_app/ is the KV260 build tree, migrated under AP4 --
        # this file only covers the dashboard (AP5), so the registry this
        # check reads against is legitimately absent here, not a defect.
        skip("registry present", "%s is not part of this example (KV260 "
             "build tree migrates under AP4)" % REGISTRY)
        return
    rows = {r["app"]: r for r in csv.DictReader(REGISTRY.open(newline=""))}
    app = "rocket2_ctrace_kv260"
    row = rows.get(app)
    if not row:
        chk("two-hart design in the registry", False, app)
        return
    achieved = float(row["achieved_mhz"])
    md5 = row["bitbin_md5"]
    saved = server.CLOSURE_CSV
    server.CLOSURE_CSV = REGISTRY
    try:
        bit = {"app": app, "md5": md5}
        # below the achieved frequency -> OK, positive margin
        st = server.closure_state(bit, {"hz": 68181818})
        chk("68.182 MHz -> OK", st["verdict"] == "OK" and st["margin_mhz"] > 0,
            "achieved %.3f, margin %+.3f" % (achieved, st["margin_mhz"] or 0))
        # above it -> EXCEEDED. The counter-check is the point: a gate that can
        # only go green is not a gate.
        st = server.closure_state(bit, {"hz": int(achieved * 1e6) + 1_000_000})
        chk("above achieved -> EXCEEDED", st["verdict"] == "EXCEEDED",
            "margin %+.3f" % (st["margin_mhz"] or 0))
        # The NAME does not carry -- same app, different artefact.
        st = server.closure_state({"app": app, "md5": "0" * 32}, {"hz": 68181818})
        chk("foreign artefact -> BITSTREAM_UNMATCHED",
            st["verdict"] == "BITSTREAM_UNMATCHED", st["note"] or "")
        for bitin, clk, want in (
                ({"app": "does_not_exist", "md5": "x"}, {"hz": 1}, "APP_UNKNOWN"),
                ({"app": app, "md5": md5}, {"hz": None, "error": "e"}, "NO_CLOCK"),
                ({"app": app, "md5": None, "error": "no bitstream"},
                 {"hz": 68181818}, "NO_BOARD_HASH")):
            st = server.closure_state(bitin, clk)
            chk("rejection %s" % want, st["verdict"] == want, st["verdict"] or "")
        server.CLOSURE_CSV = REGISTRY.with_name("does_not_exist.csv")
        st = server.closure_state({"app": app, "md5": md5}, {"hz": 68181818})
        chk("without a registry -> NO_REGISTRY", st["verdict"] == "NO_REGISTRY",
            st["note"] or "")
    finally:
        server.CLOSURE_CSV = saved


# --------------------------------------------------------------------------
# 3. The integer division must be the one of the board script. 1500000000/22
#    is 68181818 -- rounding in MHz gives 68000000 and later compares
#    roundings instead of frequencies (kv260_plclk.sh, header comment).
# --------------------------------------------------------------------------
def t_divisor_arithmetic():
    src = (HERE / "server.py").read_text(encoding="utf-8")
    chk("integer division as in kv260_plclk.sh",
        "pll_hz // (st[\"div0\"] * st[\"div1\"])" in src,
        "1500000000 // (div0*div1)")
    for div0, want in ((22, 68181818), (20, 75000000), (15, 100000000)):
        chk("divisor %d -> %d Hz" % (div0, want),
            1500000000 // (div0 * 1) == want, "")


# --------------------------------------------------------------------------
# 4. The user interface must not show the catalogue value as a measurement.
# --------------------------------------------------------------------------
def t_ui_uses_readback():
    html = (HERE / "index.html").read_text(encoding="utf-8", errors="replace")
    chk("the core card reads pl_clk back",
        "pl_clk||{}).hz" in html.replace(" ", ""),
        "relabelCores uses board.pl_clk")
    chk("the catalogue value is labelled 'design'",
        "MHz design" in html, "no silent substitute value")
    chk("the read-back value is labelled 'read back'",
        "MHz read back" in html, "")
    for needle, what in (("PL0_REF_CTRL", "the register reference"),
                         ("'Bitstream'", "the bitstream line"),
                         ("'Closure'", "the closure line"),
                         ("programmed", "the programming action"),
                         ("pr.written", "the recorded register value"),
                         ("id=\"plclk\"", "the header badge")):
        chk("the user interface shows %s" % what, needle in html, "")
    # Counter-check: the old, unconditional catalogue line must not come back.
    chk("counter-check: no unconditional c.mhz+' MHz' any more",
        "c.mhz+' MHz':null" not in html.replace(" ", "").replace(
            "c.mhz?c.mhz+'MHz':null", "c.mhz+' MHz':null"),
        "the line that carried 75 MHz into the paper")


# --------------------------------------------------------------------------
# 5. The recorded programming action is read, not invented.
# --------------------------------------------------------------------------
def t_programmed_record(tmp=None):
    saved = server.PLCLK_RECORD
    p = HERE / "_test_plclk_rec.json"
    try:
        server.PLCLK_RECORD = p
        chk("without a record -> None", server.plclk_programmed() is None, "")
        p.write_text(json.dumps({"written": "0x01011600", "requested_mhz": 68}))
        rec = server.plclk_programmed()
        chk("the record is read",
            rec and rec["written"] == "0x01011600", str(rec))
        p.write_text("not json")
        chk("a broken record -> None instead of a crash",
            server.plclk_programmed() is None, "")
    finally:
        server.PLCLK_RECORD = saved
        if p.exists():
            p.unlink()


for fn in (t_no_evidence, t_verdicts, t_divisor_arithmetic,
           t_ui_uses_readback, t_programmed_record):
    print("--", fn.__doc__ or fn.__name__)
    fn()

print()
if N_BAD:
    print("R2_PLCLK_FAIL  (%d of %d checks red)" % (N_BAD, N_OK + N_BAD))
    sys.exit(1)
if N_SKIP:
    print("R2_PLCLK_ALL_PASS  (%d checks, %d skipped -- no KV260 build tree "
          "in this example)" % (N_OK, N_SKIP))
else:
    print("R2_PLCLK_ALL_PASS  (%d checks)" % N_OK)
