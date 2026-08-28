# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Check the acceptance criterion: does the rendered view lie congruently
over the drawing?

    py devtools/measure_geometry.py 8142      (measures the rendering)
    py devtools/check_congruence.py

The rendering is uniformly scaled and translated with respect to the drawing
(fit factor, zoom, margin). "Congruent" therefore means: there is ONE
similarity transform (one factor, one translation) under which ALL blocks
coincide. The factor is derived from the overall extents, then the deviation
is measured block by block in drawing units -- not by eye, but as a number per
block.

Exit 0 = every block within tolerance, otherwise 1.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

# ROOT is this script's own directory (devtools/, the former gui/); see
# export_drawio.py for why the old ROOT/"tools"/"ctrace_dashboard" path
# collapses to ROOT.parent in this repository's layout.
ROOT = Path(__file__).resolve().parent
GUI = ROOT
SCEN = ROOT.parent / "scenarios.json"
TOL = 1.5          # drawing units; below this it is rounding, not an offset


def drawing(sid):
    """The expected geometry: what the sync read out of the drawing."""
    g = json.loads((GUI / "arch_geometry.json").read_text(encoding="utf-8"))
    if sid not in g:
        return None, None
    d = g[sid]
    boxes = {n["id"]: (n["x"], n["y"], n["w"], n["h"])
             for n in d["nodes"] + d["containers"]}
    return boxes, d.get("source", "?")


def rendered(sid):
    f = GUI / "measured" / ("geo_%s.json" % sid)
    if not f.exists():
        return None
    m = json.loads(f.read_text(encoding="utf-8"))
    return {b["id"]: (b["x"], b["y"], b["w"], b["h"])
            for b in m["blocks"] + m["containers"]}


def fit(a, b):
    """Factor and translation, from the overall extents of both sets."""
    ks = [k for k in a if k in b]
    if not ks:
        return None
    ax0 = min(a[k][0] for k in ks); ax1 = max(a[k][0] + a[k][2] for k in ks)
    ay0 = min(a[k][1] for k in ks); ay1 = max(a[k][1] + a[k][3] for k in ks)
    bx0 = min(b[k][0] for k in ks); bx1 = max(b[k][0] + b[k][2] for k in ks)
    by0 = min(b[k][1] for k in ks); by1 = max(b[k][1] + b[k][3] for k in ks)
    sx = (ax1 - ax0) / (bx1 - bx0) if bx1 > bx0 else 1.0
    sy = (ay1 - ay0) / (by1 - by0) if by1 > by0 else 1.0
    s = (sx + sy) / 2                      # ONE factor, no distortion
    return s, ax0 - bx0 * s, ay0 - by0 * s, ks


def main() -> int:
    cat = json.loads(SCEN.read_text(encoding="utf-8"))
    bad = 0
    for sc in cat["scenarios"]:
        sid = sc["id"]
        want, src = drawing(sid)
        have = rendered(sid)
        if not want or not have:
            print("  %-11s skipped (no measurement)" % sid)
            continue
        f = fit(want, have)
        if not f:
            print("  %-11s no blocks in common" % sid); bad += 1; continue
        s, dx, dy, ks = f
        worst, wid = 0.0, ""
        rows = []
        for k in sorted(ks):
            wx, wy, ww, wh = want[k]
            hx, hy, hw, hh = have[k]
            d = max(abs(hx * s + dx - wx), abs(hy * s + dy - wy),
                    abs(hw * s - ww), abs(hh * s - wh))
            rows.append((d, k))
            if d > worst:
                worst, wid = d, k
        # Check the EDGES as well -- the criterion is blocks AND arrows. The
        # first version compared blocks only and therefore reported "met"
        # while the arrows were visibly in the wrong place (2026-07-29).
        emax, eid = 0.0, ""
        gw = json.loads((GUI / "arch_geometry.json").read_text(encoding="utf-8"))
        want_e = {(e["s"], e["t"]): e.get("path")
                  for e in gw[sid]["edges"] if e.get("path")}
        mm = json.loads((GUI / "measured" / ("geo_%s.json" % sid))
                        .read_text(encoding="utf-8"))
        for e in mm["edges"]:
            wp = want_e.get((e["s"], e["t"]))
            if not wp or len(wp) != len(e["pts"]):
                continue
            # Since the rework the edges are ALREADY in model coordinates
            # (the wire SVG uses the model box as its viewBox) -- they must
            # NOT be converted back from pixels the way the blocks are.
            for (wx, wy), (hx, hy) in zip(wp, e["pts"]):
                d = max(abs(hx - wx), abs(hy - wy))
                if d > emax:
                    emax, eid = d, "%s->%s" % (e["s"], e["t"])
        worst = max(worst, emax)
        if emax > TOL:
            wid = eid + " (edge)"
        ok = worst <= TOL
        print("  %-11s %-2s factor %.4f · largest deviation %.2f at %s "
              "(%d blocks) <- %s"
              % (sid, "OK" if ok else "!!", s, worst, wid, len(ks), src))
        if not ok:
            bad += 1
            for d, k in sorted(rows, reverse=True)[:6]:
                if d > TOL:
                    print("        %-12s %.2f" % (k, d))
    print("\n%s" % ("CONGRUENT" if not bad
                    else "NOT congruent in %d view(s)" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
