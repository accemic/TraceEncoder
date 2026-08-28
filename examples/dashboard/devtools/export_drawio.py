# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Export the MEASURED dashboard geometry as .drawio -- 1:1, one page per
scenario.

    py server.py --demo --port 8142   (in one shell, from examples/dashboard/)
    py devtools/measure_geometry.py 8142
    py devtools/export_drawio.py
    ... rearrange in draw.io ...
    py devtools/sync_arch_view.py

WHAT "1:1" MEANS HERE -- and why the previous version was not (found
2026-07-29):

  * COORDINATES: 1 drawio unit = 1 rendered pixel. Before, the raw ARCH
    values were in there; but the page scales those at runtime (SCALE 1.78,
    not the 2.4 in the source) and CSS padding changes the block size on top
    of that.
  * FONT SIZES: taken from getComputedStyle (h3 12 px, sub-line 10 px).
    Before, everything ran on the drawio default.
  * ARROWS: the polylines actually drawn by layoutWires(), as waypoints plus
    exact exit/entry points. Before, every edge carried pts:[] -- drawio
    routed them itself and therefore drew different paths.

The edges stay ATTACHED to source and target (exitX/entryX as fractions) so
they follow when a block is moved -- otherwise the file would be worthless
for rearranging.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

# ROOT is this script's own directory (devtools/, the former gui/); the
# dashboard files it reads/writes alongside (scenarios.json etc.) are one
# level up, at ROOT.parent (examples/dashboard/) -- devtools/ moved from
# being a repo-root sibling of tools/ctrace_dashboard/ to living INSIDE the
# dashboard directory it serves (plan AP5), so both halves of the old path
# shifted by one level.
ROOT = Path(__file__).resolve().parent
MEAS = ROOT / "measured"
SCEN = ROOT.parent / "scenarios.json"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "ctte_view.drawio"

BASE = ("rounded=0;whiteSpace=wrap;html=1;verticalAlign=top;align=left;"
        "spacing=4;spacingTop=2;spacingLeft=4;")
FILL = {"cpu": "#20293a", "sink": "#18202c", "": "#1c2532"}
STROKE = {"cpu": "#C98500", "sink": "#3b4a63", "": "#33445c"}
CT_STYLE = ("rounded=1;dashed=1;whiteSpace=wrap;html=1;fillColor=none;"
            "strokeColor=#3c5270;fontColor=#C98500;verticalAlign=top;"
            "align=left;spacingLeft=6;spacingTop=2;fontSize=%d;")


def kind(nid):
    b = nid[:-1] if nid[-1].isdigit() else nid
    if b == "cpu":
        return "cpu"
    if b in ("uram", "ddr", "pib"):
        return "sink"
    return ""


def label(blk):
    """Label as rendered: heading plus sub-lines in their own size
    (html=1 carries that)."""
    parts = []
    for i, t in enumerate(blk["texts"]):
        txt = escape(" ".join(t["text"].split()))
        if i == 0:
            parts.append("<b>%s</b>" % txt)
        else:
            parts.append('<font style="font-size:%gpx" color="%s">%s</font>'
                         % (t["px"], "#8a99ad", txt))
    return "<br>".join(parts) or escape(blk["id"])


def frac(v, lo, span):
    if not span:
        return 0.5
    return max(0.0, min(1.0, (v - lo) / span))


def vertex(cid, lbl, style, x, y, w, h):
    return ('        <mxCell id=%s value=%s style="%s" vertex="1" parent="1">\n'
            '          <mxGeometry x="%g" y="%g" width="%g" height="%g" '
            'as="geometry"/>\n        </mxCell>'
            % (quoteattr(cid), quoteattr(lbl), style, x, y, w, h))


def edge_cell(eid, e, byid):
    """An edge with exact exit/entry points and the real waypoints."""
    pts = e["pts"]
    a, b = byid.get(e["s"]), byid.get(e["t"])
    if not a or not b or len(pts) < 2:
        return None
    p0, pn = pts[0], pts[-1]
    st = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;jettySize=auto;"
          "orthogonalLoop=1;strokeColor=%s;strokeWidth=%g;endArrow=block;"
          "endFill=1;exitX=%.4f;exitY=%.4f;exitDx=0;exitDy=0;"
          "entryX=%.4f;entryY=%.4f;entryDx=0;entryDy=0;"
          % (e.get("stroke") or "#44536e", e.get("width") or 1.7,
             frac(p0[0], a["x"], a["w"]), frac(p0[1], a["y"], a["h"]),
             frac(pn[0], b["x"], b["w"]), frac(pn[1], b["y"], b["h"])))
    mid = pts[1:-1]
    arr = ("<Array as=\"points\">%s</Array>"
           % "".join('<mxPoint x="%g" y="%g"/>' % (p[0], p[1]) for p in mid)
           ) if mid else ""
    return ('        <mxCell id=%s style="%s" edge="1" parent="1" '
            'source=%s target=%s>\n'
            '          <mxGeometry relative="1" as="geometry">%s</mxGeometry>\n'
            '        </mxCell>' % (quoteattr(eid), st, quoteattr(e["s"]),
                                   quoteattr(e["t"]), arr))


def page(g, name):
    cells, byid = [], {}
    for c in g["containers"]:
        cells.append(vertex(c["id"], escape(c["text"]),
                            CT_STYLE % round(c["px"] or 12),
                            c["x"], c["y"], c["w"], c["h"]))
    for b in g["blocks"]:
        byid[b["id"]] = b
        k = kind(b["id"])
        head = b["texts"][0]["px"] if b["texts"] else 12
        st = (BASE + "fillColor=%s;strokeColor=%s;fontColor=#e8eef7;"
              "fontSize=%d;fontFamily=%s;"
              % (FILL[k], STROKE[k], round(head),
                 (b["texts"][0]["family"] if b["texts"] else "Segoe UI")))
        cells.append(vertex(b["id"], label(b), st, b["x"], b["y"], b["w"], b["h"]))
    for i, e in enumerate(g["edges"]):
        c = edge_cell("%s_e%d" % (name, i), e, byid)
        if c:
            cells.append(c)
    w, h = g["stage"]["w"] + 60, g["stage"]["h"] + 60
    return ('  <diagram id=%s name=%s>\n'
            '    <mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" '
            'guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" '
            'pageScale="1" pageWidth="%d" pageHeight="%d" math="0" shadow="0" '
            'background="#0b0f17">\n      <root>\n'
            '        <mxCell id="0"/>\n        <mxCell id="1" parent="0"/>\n'
            + "\n".join(cells) + "\n      </root>\n    </mxGraphModel>\n"
            '  </diagram>\n') % (quoteattr("arch-" + name), quoteattr(name), w, h)


# ---------------------------------------------------------------- SVG ------
def svg_page(g, name, model_xml):
    """A .drawio.svg: viewable in a browser AND editable in draw.io.

    The image is drawn from the SAME measured values as the embedded model --
    so what the browser shows is exactly what the dashboard renders. The
    mxfile hangs uncompressed in the content attribute;
    sync_arch_view.py reads exactly this format.
    """
    W, H = g["stage"]["w"] + 40, g["stage"]["h"] + 40
    o = ['<svg xmlns="http://www.w3.org/2000/svg" '
         'xmlns:xlink="http://www.w3.org/1999/xlink" '
         'width="%d" height="%d" viewBox="0 0 %d %d" content=%s>'
         % (W, H, W, H, quoteattr(model_xml))]
    o.append('<defs><marker id="a" viewBox="0 0 10 10" refX="8.5" refY="5" '
             'markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse">'
             '<path d="M0,0 L10,5 L0,10 z" fill="#7186a4"/></marker></defs>')
    o.append('<rect width="100%" height="100%" fill="#0b0f17"/>')
    o.append('<g transform="translate(20,20)">')
    for c in g["containers"]:
        o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="6" fill="none" '
                 'stroke="#3c5270" stroke-dasharray="4 3"/>'
                 % (c["x"], c["y"], c["w"], c["h"]))
        o.append('<text x="%g" y="%g" font-family="Segoe UI" font-size="%g" '
                 'font-weight="600" fill="#C98500">%s</text>'
                 % (c["x"] + 8, c["y"] + (c["px"] or 12) + 3, c["px"] or 12,
                    escape(c["text"])))
    for e in g["edges"]:
        pts = " ".join("%g,%g" % (p[0], p[1]) for p in e["pts"])
        o.append('<polyline points="%s" fill="none" stroke="%s" '
                 'stroke-width="%g" marker-end="url(#a)"/>'
                 % (pts, e.get("stroke") or "#44536e", e.get("width") or 1.7))
    for b in g["blocks"]:
        k = kind(b["id"])
        o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="3" fill="%s" '
                 'stroke="%s"/>'
                 % (b["x"], b["y"], b["w"], b["h"], FILL[k], STROKE[k]))
        ty = b["y"]
        for i, t in enumerate(b["texts"]):
            ty += t["px"] + (3 if i == 0 else 2)
            o.append('<text x="%g" y="%g" font-family="%s" font-size="%g" '
                     'font-weight="%s" fill="%s">%s</text>'
                     % (b["x"] + 5, ty, t["family"], t["px"], t["weight"],
                        "#e8eef7" if i == 0 else "#8a99ad",
                        escape(" ".join(t["text"].split()))[:58]))
    o.append("</g></svg>")
    return "\n".join(o)



def refuse_overwrite(path):
    """An EXISTING .drawio.svg is NEVER overwritten -- full stop.

    The first attempt inspected the agent in the mxfile header ("from draw.io
    or from us?"). It failed twice and destroyed hand-drawn files: the second
    time because the newly saved files did not carry the expected marker at
    all. A heuristic that DELETES when it is unsure is the wrong shape -- in
    doubt it has to protect, not overwrite.

    So: if the file exists, it is skipped. Only what is missing gets created;
    replacing needs --force. Anyone who wants to regenerate deletes the file
    deliberately first.
    """
    return path.exists()


def main() -> int:
    cat = json.loads(SCEN.read_text(encoding="utf-8"))
    pages = []
    for sc in cat["scenarios"]:
        f = MEAS / ("geo_%s.json" % sc["id"])
        if not f.exists():
            raise SystemExit("missing: %s -- first run "
                             "'py devtools/measure_geometry.py'" % f)
        g = json.loads(f.read_text(encoding="utf-8"))
        pages.append(page(g, sc["id"]))
        print("  %-11s %2d blocks · %d containers · %2d edges"
              % (sc["id"], len(g["blocks"]), len(g["containers"]),
                 len(g["edges"])))
    OUT.write_text('<mxfile host="TraceEncoder" agent="devtools/export_drawio.py" '
                   'version="24.7.5">\n' + "".join(pages) + '</mxfile>\n',
                   encoding="utf-8")
    print("exported: %d page(s) -> %s" % (len(pages), OUT))

    # Additionally one .drawio.svg per scenario -- viewable in a browser AND
    # editable in draw.io. The image is drawn from the same measured values as
    # the embedded model.
    for sc, pg in zip(cat["scenarios"], pages):
        g = json.loads((MEAS / ("geo_%s.json" % sc["id"]))
                       .read_text(encoding="utf-8"))
        model = ('<mxfile host="TraceEncoder" agent="devtools/export_drawio.py" '
                 'version="24.7.5">\n' + pg + '</mxfile>')
        f = OUT.parent / ("ctte_view_%s.drawio.svg" % sc["id"])
        if refuse_overwrite(f) and "--force" not in sys.argv:
            print("  svg -- %s KEPT (already there; --force "
                  "overwrites)" % f.name)
            continue
        f.write_text(svg_page(g, sc["id"], model), encoding="utf-8")
        print("  svg -> %s" % f.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
