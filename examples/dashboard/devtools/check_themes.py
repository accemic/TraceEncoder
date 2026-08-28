#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Measure colour themes on the RENDERED image, not by reading themes.json.

Why at all: a theme can sit correctly in the JSON, land on :root -- and still
have no effect, because the CSS rule in question does not use the value (that
is exactly how the wire colour and the flow dots used to sit in the
JavaScript as fixed numbers). This check loads every theme headless and reads
the colours back out of the finished, rendered blocks and wires.

Checked per theme:
  1. the ground actually changes (otherwise the theme never arrived),
  2. every visible block carries the theme's fill AND its border,
  3. wire and arrowhead follow the token (the old fixed value stands out),
  4. text-on-ground and border-on-ground as a WCAG contrast -- measured, so
     that "more contrast" is a number and not a claim.

Usage:  py devtools/check_themes.py [port]
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# ROOT is this script's own directory (devtools/, the former gui/); see
# export_drawio.py for why the old ROOT/"tools"/"ctrace_dashboard" path
# collapses to ROOT.parent in this repository's layout.
ROOT = Path(__file__).resolve().parent
EDGE = Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe")
THEMES = ROOT.parent / "themes.json"

# A theme has to stand out visibly from the default, otherwise it is not one.
MIN_TEXT_CONTRAST = 4.5     # WCAG AA for normal text
MIN_EDGE_CONTRAST = 3.0     # WCAG "non-text" for borders and wires
MIN_SIDE_CONTRAST = 2.0     # side paths may recede, but not disappear


def rgb(s: str):
    """Bring a colour from the browser onto the 0..255 scale.

    Careful -- this is where the first attempt went wrong: the browser does
    not resolve color-mix() to 'rgb(153, 125, 55)' but to
    'color(srgb 0.6 0.49 0.21)', i.e. 0..1 instead of 0..255. Parsing both
    forms the same way measures tinted blocks as nearly black and reports a
    contrast failure that does not exist.
    """
    s = s or ""
    m = re.findall(r"-?[\d.]+(?:e-?\d+)?", s)
    if len(m) < 3:
        return None
    v = [float(x) for x in m[:3]]
    if s.lstrip().startswith("color("):
        v = [x * 255.0 for x in v]
    return tuple(max(0.0, min(255.0, x)) for x in v)


def lum(c):
    def f(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (f(x) for x in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    if not a or not b:
        return None
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def dump(port, theme, scen, work):
    url = ("http://localhost:%s/?scen=%s&theme=%s&themedump=1"
           % (port, scen, theme))
    r = subprocess.run([str(EDGE), "--headless=new", "--disable-gpu",
                        "--user-data-dir=%s" % (work / ("p_" + theme)),
                        "--window-size=1700,1100",
                        "--virtual-time-budget=9000", "--dump-dom", url],
                       capture_output=True, timeout=180)
    dom = r.stdout.decode("utf-8", "replace")
    m = re.search(r'<pre id="themedump"[^>]*>(.*?)</pre>', dom, re.S)
    if not m:
        raise SystemExit("%s: no themedump in the DOM -- is the server "
                         "running on port %s?" % (theme, port))
    txt = m.group(1)
    for a, b in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"')]:
        txt = txt.replace(a, b)
    return json.loads(txt)


def main() -> int:
    port = sys.argv[1] if len(sys.argv) > 1 else "8142"
    scen = sys.argv[2] if len(sys.argv) > 2 else "trio"
    doc = json.loads(THEMES.read_text(encoding="utf-8"))
    ids = list(doc["themes"])

    work = Path(tempfile.mkdtemp(prefix="ctte_thm_"))
    seen_bg, fails = {}, []

    for tid in ids:
        d = dump(port, tid, scen, work)
        bg, txt = rgb(d["bodyBg"]), rgb(d["txt"])
        wire, head = rgb(d["wire"]), rgb(d["head"])
        blocks = d["blocks"]

        print("\n=== %s  (%s, %d blocks) ===" % (tid, d["mode"], len(blocks)))
        print("  ground %s · text %s · wire %s @ %s"
              % (d["bodyBg"], d["txt"], d["wire"], d["wireW"]))

        if d["theme"] != tid:
            fails.append("%s: page reports theme %r" % (tid, d["theme"]))

        # 1. Two themes must not look identical -- one of them would not have
        #    arrived. What is compared is the WHOLE impression, not just the
        #    ground: 'print' and 'mono' both sit on white and differ only in
        #    the role colours.
        fp = (d["bodyBg"], d["txt"], d["wire"],
              tuple(b["bc"] for b in blocks[:12]))
        if fp in seen_bg:
            fails.append("%s: looks like %s -- the theme has no effect"
                         % (tid, seen_bg[fp]))
        seen_bg[fp] = tid

        # 2. Text on ground
        ct = contrast(txt, bg)
        ok = ct and ct >= MIN_TEXT_CONTRAST
        print("  text/bg         %5.2f:1  %s" % (ct or 0, "ok" if ok else "TOO LOW"))
        if not ok:
            fails.append("%s: text/bg only %.2f:1" % (tid, ct or 0))

        # 3. Wire against the ground -- the old fixed value #7a8699 would
        #    come out the same in EVERY scheme and is noticed for that.
        cw = contrast(wire, bg)
        okw = cw and cw >= MIN_EDGE_CONTRAST
        print("  wire/bg         %5.2f:1  %s" % (cw or 0, "ok" if okw else "TOO LOW"))
        if not okw:
            fails.append("%s: wire/bg only %.2f:1" % (tid, cw or 0))
        if head and wire and head != wire:
            fails.append("%s: arrow head %s != wire %s" % (tid, head, wire))

        # 4. Every block carries the theme's fill and border.
        #    The side paths (k-side) are tracked SEPARATELY: they are meant to
        #    recede, so a lower value there is intent and not a defect -- their
        #    identity is carried by the label inside the block. Letting them
        #    disappear entirely is still not allowed, hence their own, lower
        #    threshold.
        worst, worst_id, flat = 99.0, None, []
        sworst, sworst_id = 99.0, None
        for b in blocks:
            bc, bbg = rgb(b["bc"]), rgb(b["bg"])
            c = contrast(bc, bg)
            side = "k-side" in (b.get("cls") or "")
            if c is not None:
                if side and c < sworst:
                    sworst, sworst_id = c, b["id"]
                elif not side and c < worst:
                    worst, worst_id = c, b["id"]
            if bbg and bg and bbg == bg:
                flat.append(b["id"])       # fill == ground: not tinted
        print("  border/bg       %5.2f:1  (weakest load-bearing role: %s)"
              % (worst, worst_id))
        if sworst_id:
            print("  secondary path  %5.2f:1  (%s -- meant to recede)"
                  % (sworst, sworst_id))
        if worst < MIN_EDGE_CONTRAST:
            fails.append("%s: block border %s only %.2f:1" % (tid, worst_id, worst))
        if sworst_id and sworst < MIN_SIDE_CONTRAST:
            fails.append("%s: secondary path %s practically invisible at %.2f:1"
                         % (tid, sworst_id, sworst))
        if flat:
            fails.append("%s: %d blocks without tint (%s)"
                         % (tid, len(flat), ", ".join(flat[:4])))

    print("\n" + "=" * 62)
    if fails:
        print("ERRORS (%d):" % len(fails))
        for f in fails:
            print("  - " + f)
        return 1
    print("All %d schemes: applied, tinted, contrast-checked." % len(ids))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
