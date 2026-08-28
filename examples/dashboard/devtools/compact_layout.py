# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
r"""Build the geometry source PER SCENARIO -- from the scenario, not from an
earlier measurement.

    py devtools/compact_layout.py   -> writes devtools/ctte_view_<id>.drawio.svg
    py devtools/sync_arch_view.py   -> takes it into the dashboard

WHY THIS WAS REWRITTEN. The first version derived the set of blocks from
`devtools/measured/geo_<id>.json` -- that is, from a measurement of the already
rendered view. By construction it could therefore produce nothing for a
scenario that had never existed: `cva6_linux64` and `rocket64` stayed without a
drawing, `sync_arch_view.py` bailed out on them with "no geometry source" --
and because its write step sits BEHIND the loop, it then wrote nothing at all.
In the dashboard `rebuildArch()` silently fell back for those scenarios to the
last geometry that had been set, and that was the TRIO's: three rows, two of
them hidden. That is exactly where the orphaned "Kria PS" boxes, the
unconnected memory blocks and the empty third came from.

The set of blocks now comes from `scenarios.json` (cores, `features`, `sinks`)
plus one RTL fact per scenario (`ETRACE`, below), not from a measurement.
Adding a scenario therefore gets you its drawing automatically.

THE GRID (drawing units; 1 unit = 1 rendered pixel at the reference width, see
`--u` in index.html):

    cpu        20        190x138     the observed core
    ingress   236         92x 46     TIP adapter / ITI shim / TCI shim / H2E
    [ encoder container 352 .. 916 ]
    preproc   372         84x 46
    fifo      476         84x 62
    msggen    580         84x 46  \
    nexusfmt  684         92x 46   >  N-Trace chain (upper lane)
    mseomdo   796        100x 46  /
    teinst    580         84x 46  \  E-Trace chain (lower lane), only where
    tepktz    684         92x 46  /   the build carries it
    funnel    940         78x(span)       only from two encoders upwards
    sinks     1050/960   112x 54          uram/ddr/pib, depending on scenario

The chain follows the RTL: core -> shim -> ct_L23_preproc -> TIP FIFO ->
{ct_L2_msg_gen -> ct_L2_nexus_formatter -> ct_L2_mseo_mdo_formatter} or
{ct_L2_te_inst_gen -> ct_L2_te_packetizer} -> (ct_L1_funnel) -> sinks.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

# ROOT is this script's own directory (devtools/, the former gui/); see
# export_drawio.py for why the old ROOT/"tools"/"ctrace_dashboard" path
# collapses to ROOT.parent in this repository's layout.
ROOT = Path(__file__).resolve().parent
GUI = ROOT
SCEN = ROOT.parent / "scenarios.json"

# ---------------------------------------------------------------- Raster ----
X_CPU, W_CPU, H_CPU = 20, 190, 138
X_ING, W_ING = 236, 92
X_CT = 352
X_PRE, W_PRE = 372, 84
X_FIFO, W_FIFO, H_FIFO = 476, 84, 62
X_MSG, W_MSG = 580, 84
X_NEX, W_NEX = 684, 92
X_MSEO, W_MSEO = 796, 100
X_TEI, W_TEI = 580, 84
X_TEP, W_TEP = 684, 92
H_SM = 46
CT_PAD_R = 20                       # air between the last block and the container edge
W_CT = (X_MSEO + W_MSEO + CT_PAD_R) - X_CT          # 564

W_FUNNEL = 78
W_SINK, H_SINK, GAP_SINK = 112, 54, 20

# AXIS sits BELOW THE PREPROCESSOR, not below the FIFO: the ACT-CAP tap comes
# out of ct_L23_preproc (that is where the ACT-CAP/ACT-ST dispatch lives), and
# the edge in the model is preproc->axis. Drawn below the FIFO, the edge
# endpoint sat 62 units away from its target block, and sync_arch_view.py
# dropped the edge silently (tolerance 40) -- the arrow was missing from the
# picture.
X_AXIS, W_AXIS, H_AXIS = 372, 84, 40
X_PS, W_PS = 236, 92                      # Kria PS side, flush left with the shim

# AXIS-WP chain (feature `axis_wp`): the encoder's 96-bit AXIS port feeds, per
# row, ct_axis_wp_shim -> wp_axi_fifo (axi_fifo_mm_s, 1024 records) -> Kria PS
# (the /dev/mem drain behind /wp.html). Like the ACT-CAP tap the chain hangs
# BELOW the row and starts at the preprocessor (the ACT-ST/WP dispatch sits
# there, edge preproc->wpshim); it reads left to right like the ATB chain above
# it, with the PS consumer at the end. The blocks are taller than the ACT-CAP
# tap (62 instead of 40): the shim carries a fill bar plus a counter line from
# the WPCTRL window.
# Widths of the WP chain, computed rather than guessed: the card font is
# --fs-s = 10 model units in monospace, so ~6 units per character, plus 5+5
# units of block border and 2 units of .cnt padding. The longest line of the
# shim card is "drop 4,294,967,294" = 18 characters -> 18*6 + 12 = 120 units.
# At 84 it did not fit and wrapped; the second line ("ovf YES") then slid below
# the block's overflow:hidden edge and was gone. 152 leaves room for the
# ten-digit value with separators.
# The space comes out of the arrow runs (124 units between the blocks before,
# 76/74 now) -- not from the right margin: the chain runs in row 0 next to the
# funnel (x 920) and must not touch it.
X_WPS, W_WPS = 372, 152                   # ct_axis_wp_shim, below preproc
X_WPF, W_WPF = 600, 116                   # wp_axi_fifo, below msggen
X_WPP, W_WPP = 790, 110                   # Kria PS (the A53 consumer)
H_AWP = 62

# Row heights: two lanes with E-Trace, only one without.
H_ROW_E, H_ROW_N = 158, 96
LANE_A_E, LANE_B_E = 26, 86               # dy of the lanes when there are two
LANE_A_N = 25
ROW_GAP = 34

# Arrowhead exactly as draw.io draws it: tip 1.9 before the block edge, base
# 7.7 behind it, half-width 3.85. sync_arch_view.rendered_paths() recognises
# the line by fill="none" and the head by having a fill; both are taken over
# (without the head an edge is left as a stub).
A_TIP, A_LEN, A_HALF = 1.9, 9.6, 3.85

WIRE = "#5b6b85"

# Which build carries the E-Trace chain? That is a synthesis parameter
# (EN_ETRACE), not a display detail -- and on the two-hart Rocket it is
# EXPLICITLY 0: the funnel recognises packet boundaries from the Nexus MSEO
# bits, while an E-Trace back end delivers raw bytes and would be merged
# silently wrong (rocket2_soc_top.sv header, item 4; the wrapper aborts
# elaboration at 1). Drawing two lanes here blindly would show blocks that do
# not exist in the bitstream.
ETRACE = {
    "mbv": True, "cva6_linux": True, "cva6_linux64": True,
    "rocket64": True, "trio": True, "rocket2": False,
    # cva6_2: EN_ETRACE=1'b0 (rtl/board_kv260/cva6_2_soc_top.sv:153, header
    # item 4 -- the funnel parses Nexus MSEO, the wrapper aborts at 1).
    "cva6_2_rv64": False, "cva6_2_rv32": False,
    # duo: NO sandbox copy of rtl/pkg as the trio has -- duo's
    # examples/kv260/duo/fpga/create_project_kv260.tcl resolves the encoder
    # sources unchanged through rtl/ct_encoder.abc, where
    # rtl/pkg/ct_pkg.sv:691 `localparam bit CT_EN_ETRACE = 0` applies. The
    # build is therefore N-Trace only; te_inst/tePktz blocks would be invented
    # in the picture.
    "duo": False,
    # tgc5b2_axis_wp: CT_EN_ETRACE=0 in BOTH encoder vintages of the scenario
    # (rtl/pkg/ct_pkg.sv:691 in either tree): N-Trace only, no te_inst/tePktz
    # blocks.
    "tgc5b2_axis_wp": False,
}

LABEL = {
    "cpu": "Core", "tip": "Trace ingress", "preproc": "Preproc", "fifo": "FIFO",
    "msggen": "MsgGen", "nexusfmt": "Nexus Fmt", "mseomdo": "MSEO/MDO",
    "teinst": "te_inst", "tepktz": "te Pktz", "funnel": "Trace Funnel",
    "uram": "Mem (URAM)", "ddr": "Mem (DDR4)", "pib": "PIB",
    "axis": "AXIS", "kriaps": "Kria PS",
    "wpshim": "AXIS WP shim", "wpfifo": "wp_axi_fifo",
}

NODE = ("rounded=0;whiteSpace=wrap;html=1;verticalAlign=top;align=left;"
        "spacing=4;fillColor=%s;strokeColor=%s;fontColor=#e8eef7;fontSize=12;")
CTST = ("rounded=1;dashed=1;whiteSpace=wrap;html=1;fillColor=none;"
        "strokeColor=#3c5270;fontColor=#C98500;verticalAlign=top;align=left;"
        "spacingLeft=6;fontSize=12;")
EDGE = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;strokeColor=#44536e;"
        "strokeWidth=1.7;endArrow=block;endFill=1;")


def attr(v):
    """Always delimit with double quotes.

    With many inner quotes quoteattr() picks single ones by itself -- but the
    sync looks for content="..." and then did not find the file (this really
    happened)."""
    return '"%s"' % (v.replace("&", "&amp;").replace("<", "&lt;")
                      .replace(">", "&gt;").replace('"', "&quot;"))


# -------------------------------------------------------------- geometry ----
def build(sc):
    """Blocks, containers and edges for exactly this scenario."""
    cores = sc.get("cores", [])
    feats = sc.get("features", [])
    sinks = sc.get("sinks", {}) or {}
    etr = ETRACE.get(sc["id"], True)
    has_axis = "axis" in feats
    has_awp = "axis_wp" in feats
    n = len(cores)

    h_row = H_ROW_E if etr else H_ROW_N
    # The AXIS tap hangs BELOW the row. Without this allowance it ran into
    # the container label of the next row ("…raceEncoder · ENC1 · TGC5B" was
    # half covered in the trio) -- the label sits on the container's top edge,
    # so it needs the space above.
    below = (H_AXIS + 8 + 14) if has_axis else \
            ((H_AWP + 8 + 14) if has_awp else 0)
    pitch = max(h_row + below, H_CPU) + ROW_GAP
    N = {}          # id -> dict
    conts = []
    E = []          # (src, dst, kind) -- the route is derived later from the boxes

    def put(nid, x, y, w, h):
        N[nid] = {"id": nid, "x": float(x), "y": float(y),
                  "w": float(w), "h": float(h)}

    for r in range(n):
        ry = r * pitch
        la = ry + (LANE_A_E if etr else LANE_A_N)
        lb = ry + LANE_B_E
        conts.append({"id": "ct%d" % r, "x": float(X_CT), "y": float(ry),
                      "w": float(W_CT), "h": float(h_row)})
        put("cpu%d" % r, X_CPU, ry + (h_row - H_CPU) / 2.0, W_CPU, H_CPU)
        # The trio's TGC5B has no ingress block of its own -- its H2E stage
        # sits inside the wrapper. That fact lives in the scenario, not here.
        # `ingress_block` on the core overrides the rule EXPLICITLY:
        # tgc5b2_axis_wp instantiates the H2E->TIP adapter visibly per core in
        # tgc5b_wp_synth_wrap, so the diagram shows it in BOTH rows; the trio
        # keeps the older rule.
        want_tip = cores[r].get("ingress_block")
        if want_tip is None:
            want_tip = cores[r].get("ingress") not in (None, "", "H2E->TIP")
        if want_tip:
            put("tip%d" % r, X_ING, ry + (h_row - H_SM) / 2.0, W_ING, H_SM)
        put("preproc%d" % r, X_PRE, ry + (h_row - H_SM) / 2.0, W_PRE, H_SM)
        put("fifo%d" % r, X_FIFO, ry + (h_row - H_FIFO) / 2.0, W_FIFO, H_FIFO)
        put("msggen%d" % r, X_MSG, la, W_MSG, H_SM)
        put("nexusfmt%d" % r, X_NEX, la, W_NEX, H_SM)
        put("mseomdo%d" % r, X_MSEO, la, W_MSEO, H_SM)
        if etr:
            put("teinst%d" % r, X_TEI, lb, W_TEI, H_SM)
            put("tepktz%d" % r, X_TEP, lb, W_TEP, H_SM)
        if has_axis:
            ay = ry + h_row + 8
            put("axis%d" % r, X_AXIS, ay, W_AXIS, H_AXIS)
            put("kriaps%d" % r, X_PS, ay, W_PS, H_AXIS)
        if has_awp:
            ay = ry + h_row + 8
            put("wpshim%d" % r, X_WPS, ay, W_WPS, H_AWP)
            put("wpfifo%d" % r, X_WPF, ay, W_WPF, H_AWP)
            put("kriaps%d" % r, X_WPP, ay, W_WPP, H_AWP)

        ing = "tip%d" % r
        if ing in N:
            E.append(("cpu%d" % r, ing, "h"))
            E.append((ing, "preproc%d" % r, "h"))
        else:
            E.append(("cpu%d" % r, "preproc%d" % r, "h"))
        E.append(("preproc%d" % r, "fifo%d" % r, "h"))
        # Middle of the vertical edge to middle of the vertical edge: both
        # protocol lanes leave the FIFO at the MIDPOINT of its right edge and
        # only fan out halfway along. Before, they started at 27 % and 73 % of
        # the block height and met their target at an angle.
        E.append(("fifo%d" % r, "msggen%d" % r, "h"))
        E.append(("msggen%d" % r, "nexusfmt%d" % r, "h"))
        E.append(("nexusfmt%d" % r, "mseomdo%d" % r, "h"))
        if etr:
            E.append(("fifo%d" % r, "teinst%d" % r, "h"))
            E.append(("teinst%d" % r, "tepktz%d" % r, "h"))
        if has_axis:
            E.append(("preproc%d" % r, "axis%d" % r, "down"))
            E.append(("axis%d" % r, "kriaps%d" % r, "left"))
        if has_awp:
            E.append(("preproc%d" % r, "wpshim%d" % r, "down"))
            E.append(("wpshim%d" % r, "wpfifo%d" % r, "h"))
            E.append(("wpfifo%d" % r, "kriaps%d" % r, "h"))

    top = 0.0
    bot = (n - 1) * pitch + h_row

    # Merging: only from two encoders upwards. With a single encoder the ATB
    # goes straight to the sinks -- a funnel with one channel would be drawn
    # hardware that does not exist in the bitstream.
    use_funnel = n >= 2
    if use_funnel:
        put("funnel", 940, top, W_FUNNEL, bot - top)
        x_sink = 940 + W_FUNNEL + 54
    else:
        x_sink = X_MSEO + W_MSEO + 64

    want = [s for s in ("ddr", "uram", "pib") if sinks.get(s)]
    if not want:
        want = ["uram"]
    span = len(want) * H_SINK + (len(want) - 1) * GAP_SINK
    y0 = (top + bot) / 2.0 - span / 2.0
    for i, sid in enumerate(want):
        put(sid, x_sink, y0 + i * (H_SINK + GAP_SINK), W_SINK, H_SINK)

    for r in range(n):
        ends = ["mseomdo%d" % r] + (["tepktz%d" % r] if etr else [])
        for e in ends:
            if use_funnel:
                # Every channel enters the funnel at ITS OWN height. Routing
                # them all to the middle looks like one channel and is exactly
                # what the drawing is meant to refute: the funnel has one
                # input per row (FUNNEL_CTRL b[1:0] / b[5:4] ...).
                E.append((e, "funnel", "chan%d" % r))
            else:
                for sid in want:
                    E.append((e, sid, "trunk"))
    if use_funnel:
        for sid in want:
            E.append(("funnel", sid, "h"))

    return N, conts, E


# ---------------------------------------------------------------- edges -----
def route(N, E, n_rows=1):
    """Turn (source, target, kind) into an orthogonal route with an
    arrowhead. The dashboard draws exclusively what is produced here:
    `layoutWires()` skips every edge without a `path` (index.html)."""
    out = []
    # A trunk line before the sinks (or before the funnel): all chain ends run
    # onto the SAME vertical line and only fan out there. Otherwise, with three
    # sinks, six lines cross in open space.
    trunk_x = {}
    for s, t, kind in E:
        if kind == "trunk" or kind.startswith("chan"):
            b = N[t]
            trunk_x.setdefault(t, b["x"] - 30.0)
            trunk_x[t] = min(trunk_x[t], b["x"] - 30.0)
    tx_common = min(trunk_x.values()) if trunk_x else 0.0

    for s, t, kind in E:
        a, b = N[s], N[t]
        ay, by = a["y"] + a["h"] / 2.0, b["y"] + b["h"] / 2.0
        if kind.startswith("chan"):
            # STRAIGHT into the funnel, at the height of the source. The
            # entry used to sit at (r+1)/(n+1) of the funnel height, which
            # forced a bend. The channels stay separate all the same: every
            # row arrives at its own height, because the chain ends already
            # sit at different heights.
            by = ay
            kind = "straight"
        if kind == "down":
            cx = a["x"] + a["w"] / 2.0
            p = [[cx, a["y"] + a["h"]], [cx, b["y"] - A_LEN]]
            head = [[cx, b["y"] - A_TIP], [cx - A_HALF, b["y"] - A_LEN],
                    [cx + A_HALF, b["y"] - A_LEN]]
        elif kind == "left":
            xe = b["x"] + b["w"]
            p = [[a["x"], ay], [xe + A_LEN, by]]
            head = [[xe + A_TIP, by], [xe + A_LEN, by - A_HALF],
                    [xe + A_LEN, by + A_HALF]]
        else:
            xs, xe = a["x"] + a["w"], b["x"]
            if kind == "trunk":
                cx = tx_common
            else:
                cx = xs + (xe - xs) / 2.0
            if abs(ay - by) < 0.6:
                p = [[xs, ay], [xe - A_LEN, ay]]
            else:
                p = [[xs, ay], [cx, ay], [cx, by], [xe - A_LEN, by]]
            head = [[xe - A_TIP, by], [xe - A_LEN, by - A_HALF],
                    [xe - A_LEN, by + A_HALF]]
        out.append({"s": s, "t": t, "path": p, "head": head})
    return out


# ------------------------------------------------------------------ SVG -----
def fill_of(base):
    return ("#20293a" if base == "cpu" else
            "#18202c" if base in ("uram", "ddr", "pib") else
            "#141b26" if base in ("axis", "kriaps", "wpshim", "wpfifo")
            else "#1c2532")


def stroke_of(base):
    return ("#C98500" if base == "cpu" else
            "#4a5a72" if base in ("axis", "kriaps", "wpshim", "wpfifo")
            else "#33445c")


def base_of(nid):
    return nid.rstrip("0123456789") or nid


def svg(sc, N, conts, edges):
    nodes = list(N.values())
    xs = [v["x"] for v in nodes + conts] + [p[0] for e in edges for p in e["path"]]
    ys = [v["y"] for v in nodes + conts] + [p[1] for e in edges for p in e["path"]]
    xe = [v["x"] + v["w"] for v in nodes + conts]
    ye = [v["y"] + v["h"] for v in nodes + conts]
    ox, oy = min(xs) - 30, min(ys) - 30
    W = int(max(xe) - ox + 30)
    H = int(max(ye) - oy + 30)

    def sh(v):
        return {"x": v["x"] - ox, "y": v["y"] - oy, "w": v["w"], "h": v["h"]}

    cells = []
    for c in conts:
        i = int(c["id"][2:])
        cap = "CEDARtools.TraceEncoder · ENC%d · %s" % (
            i, sc["cores"][i].get("name", ""))
        g = sh(c)
        cells.append('        <mxCell id=%s value=%s style="%s" vertex="1" '
                     'parent="1"><mxGeometry x="%g" y="%g" width="%g" '
                     'height="%g" as="geometry"/></mxCell>'
                     % (quoteattr(c["id"]), quoteattr(cap), CTST,
                        g["x"], g["y"], g["w"], g["h"]))
    for v in nodes:
        b = base_of(v["id"])
        g = sh(v)
        cells.append('        <mxCell id=%s value=%s style="%s" vertex="1" '
                     'parent="1"><mxGeometry x="%g" y="%g" width="%g" '
                     'height="%g" as="geometry"/></mxCell>'
                     % (quoteattr(v["id"]), quoteattr(LABEL.get(b, b)),
                        NODE % (fill_of(b), stroke_of(b)),
                        g["x"], g["y"], g["w"], g["h"]))
    for i, e in enumerate(edges):
        cells.append('        <mxCell id="%s_e%d" style="%s" edge="1" '
                     'parent="1" source=%s target=%s><mxGeometry relative="1" '
                     'as="geometry"/></mxCell>'
                     % (sc["id"], i, EDGE, quoteattr(e["s"]), quoteattr(e["t"])))

    model = ('<mxfile host="TraceEncoder" agent="devtools/compact_layout.py" '
             'version="24.7.5">\n  <diagram id=%s name=%s>\n'
             '    <mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" '
             'guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" '
             'pageScale="1" pageWidth="%d" pageHeight="%d" math="0" shadow="0" '
             'background="#0b0f17">\n      <root>\n'
             '        <mxCell id="0"/>\n        <mxCell id="1" parent="0"/>\n'
             % (quoteattr("arch-" + sc["id"]), quoteattr(sc["id"]), W, H)
             + "\n".join(cells)
             + "\n      </root>\n    </mxGraphModel>\n  </diagram>\n</mxfile>")

    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
         'viewBox="0 0 %d %d" content=%s>' % (W, H, W, H, attr(model)),
         '<rect width="100%" height="100%" fill="#0b0f17"/>']
    for c in conts:
        i = int(c["id"][2:])
        g = sh(c)
        o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="10" fill="none" '
                 'stroke="#3c5270" stroke-dasharray="5 4"/>'
                 % (g["x"], g["y"], g["w"], g["h"]))
        o.append('<text x="%g" y="%g" font-family="Segoe UI" font-size="12" '
                 'font-weight="600" fill="#C98500">%s</text>'
                 % (g["x"] + 10, g["y"] - 5,
                    escape("CEDARtools.TraceEncoder · ENC%d · %s"
                           % (i, sc["cores"][i].get("name", "")))))
    # Edges BEFORE the blocks -- otherwise a line lies on top of the box it
    # runs into. The order d= then fill= is mandatory: the sync recognises
    # line and head by exactly that pattern.
    for e in edges:
        d = "M" + " L".join("%g,%g" % (p[0] - ox, p[1] - oy) for p in e["path"])
        o.append('<path d="%s" fill="none" stroke="%s" stroke-width="1.7"/>'
                 % (d, WIRE))
        hd = ("M" + " L".join("%g,%g" % (p[0] - ox, p[1] - oy) for p in e["head"])
              + " Z")
        o.append('<path d="%s" fill="%s" stroke="none"/>' % (hd, WIRE))
    for v in nodes:
        b = base_of(v["id"])
        g = sh(v)
        o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="6" fill="%s" '
                 'stroke="%s"/>' % (g["x"], g["y"], g["w"], g["h"],
                                    fill_of(b), stroke_of(b)))
        o.append('<text x="%g" y="%g" font-family="Segoe UI" font-size="12" '
                 'font-weight="600" fill="#e8eef7">%s</text>'
                 % (g["x"] + 6, g["y"] + 17, escape(LABEL.get(b, b))))
    o.append("</svg>")
    return "\n".join(o)


def main() -> int:
    cat = json.loads(SCEN.read_text(encoding="utf-8"))
    for sc in cat["scenarios"]:
        N, conts, E = build(sc)
        edges = route(N, E, max(1, len(sc.get("cores", []))))
        f = GUI / ("ctte_view_%s.drawio.svg" % sc["id"])
        f.write_text(svg(sc, N, conts, edges), encoding="utf-8")
        print("  %-13s %2d blocks · %d containers · %2d edges%s -> %s"
              % (sc["id"], len(N), len(conts), len(edges),
                 "" if ETRACE.get(sc["id"], True) else "  (without E-Trace)",
                 f.name))
        stray = sorted(GUI.glob("ctte_view_%s_aw*.drawio.svg" % sc["id"]))
        if stray:
            print("     ATTENTION: %s takes precedence in the sync and "
                  "shadows this file" % stray[-1].name)
    print("Next: py devtools/sync_arch_view.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
