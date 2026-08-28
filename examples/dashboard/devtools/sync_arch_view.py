# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Write the geometry rearranged in draw.io back into the dashboard, PER SCENARIO.

    py devtools/sync_arch_view.py

Sources per scenario, searched in this order:
    devtools/ctte_view_<scenario>.drawio.svg   rearranged by hand (preferred)
    devtools/ctte_view.drawio                  multi-page collection file
    devtools/measured/geo_<scenario>.json        the measured actual geometry

WHY PER SCENARIO: until 2026-07-29 all views shared ONE geometry. The
single-core scenarios thereby inherited the trio layout including its hidden
rows and their empty space -- precisely what compaction is meant to remove.
Every view now carries its own layout.

THE CELL ID IS THE KEY, not the label. Renaming a block changes nothing;
deleting it removes it from the view. A block the dashboard does not know is
REPORTED instead of silently adopted -- a typo in the drawio should stand out,
not damage the layout.
"""
from __future__ import annotations

import base64
import html
import json
import re
import sys
import urllib.parse
import zlib
from pathlib import Path
from xml.etree import ElementTree as ET

# ROOT is this script's own directory (devtools/, the former gui/); see
# export_drawio.py for why the old ROOT/"tools"/"ctrace_dashboard" path
# collapses to ROOT.parent in this repository's layout. GUI keeps its name
# for minimal diff below -- it now means "this devtools/ directory", not a
# repo-root-level gui/ sibling.
ROOT = Path(__file__).resolve().parent
GUI = ROOT
DASH = ROOT.parent
INDEX = DASH / "index.html"
SCEN = DASH / "scenarios.json"
GEOJSON = GUI / "arch_geometry.json"

BEGIN = "/* ARCH-GEOMETRY-BEGIN"
END = "/* ARCH-GEOMETRY-END */"


def model_of(path: Path) -> str:
    """Fetch the mxfile XML out of a .drawio or .drawio.svg."""
    src = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix.lower() == ".svg":
        # Allow both delimiters -- draw.io and our own generators
        # write content="..." or content='...' depending on the content.
        m = (re.search(r'content="([^"]*)"', src)
             or re.search(r"content='([^']*)'", src))
        if not m:
            raise SystemExit("no embedded mxfile in %s" % path)
        src = html.unescape(m.group(1))
    return src


def diagrams(mx: str):
    """(page name, mxGraphModel XML). draw.io stores either
    uncompressed or deflate+base64+urlencode -- both are accepted."""
    for m in re.finditer(r"<diagram([^>]*)>(.*?)</diagram>", mx, re.S):
        attrs, inner = m.group(1), m.group(2).strip()
        nm = re.search(r'name="([^"]*)"', attrs)
        if not inner.startswith("<"):
            inner = urllib.parse.unquote(
                zlib.decompress(base64.b64decode(inner), -15).decode("utf-8"))
        yield (nm.group(1) if nm else ""), inner


def parse_model(xml: str):
    root = ET.fromstring(xml)
    nodes, conts, edges = [], [], []
    for c in root.iter("mxCell"):
        cid, g = c.get("id"), c.find("mxGeometry")
        if not cid or cid in ("0", "1"):
            continue
        if c.get("vertex") == "1" and g is not None:
            st = c.get("style") or ""
            rr = re.search(r"rounded=(\d)", st)
            rec = {"id": cid, "label": c.get("value") or "",
                   "round": int(rr.group(1)) if rr else 0,
                   "x": float(g.get("x", 0)), "y": float(g.get("y", 0)),
                   "w": float(g.get("width", 0)), "h": float(g.get("height", 0))}
            (conts if cid.startswith("ct") else nodes).append(rec)
        elif c.get("edge") == "1" and c.get("source") and c.get("target"):
            pts = []
            arr = g.find("Array") if g is not None else None
            if arr is not None:
                for p in arr.findall("mxPoint"):
                    pts.append([float(p.get("x", 0)), float(p.get("y", 0))])
            edges.append({"s": c.get("source"), "t": c.get("target"), "pts": pts})
    return nodes, conts, edges


def from_measured(path: Path):
    g = json.loads(path.read_text(encoding="utf-8"))
    nodes = [{"id": b["id"], "x": b["x"], "y": b["y"], "w": b["w"], "h": b["h"]}
             for b in g["blocks"]]
    conts = [{"id": c["id"], "x": c["x"], "y": c["y"], "w": c["w"], "h": c["h"]}
             for c in g["containers"]]
    # The first and last point are the exit and entry at the block, which the
    # dashboard computes itself -- only the bends in between are waypoints.
    edges = [{"s": e["s"], "t": e["t"], "pts": e["pts"][1:-1]} for e in g["edges"]]
    return nodes, conts, edges



def rendered_paths(svg_text, nodes, conts):
    """Take the edges from the SVG -- the LINE **AND** the ARROWHEAD.

    Both paths are imported and later drawn VERBATIM -- `<path d=line
    fill=none stroke=..>` and `<path d=head fill=..>`. The head is not a
    marker definition but the triangle draw.io actually drew.

    The first attempt here THREW THE HEADS AWAY and set a marker-end of its
    own instead. The result was short stubs with arrows in the wrong places
    (marked up by hand on 2026-07-29). Hence they now come along.

    draw.io normalises the origin on export; the offset is derived from the
    SIZE (rendered rectangles against model nodes, majority wins).
    """
    body = re.sub(r'\scontent="[^"]*"', " ", svg_text)
    body = re.sub(r"\scontent='[^']*'", " ", body)

    rects = [(float(a), float(b), float(c), float(d)) for a, b, c, d in
             re.findall(r'<rect[^>]*\sx="([-\d.]+)"[^>]*\sy="([-\d.]+)"'
                        r'[^>]*\swidth="([\d.]+)"[^>]*\sheight="([\d.]+)"', body)]
    votes = {}
    for rx, ry, rw, rh in rects:
        for b in list(nodes) + list(conts):
            if abs(b["w"] - rw) < 0.6 and abs(b["h"] - rh) < 0.6:
                k = (round(b["x"] - rx), round(b["y"] - ry))
                votes[k] = votes.get(k, 0) + 1
    dx, dy = max(votes, key=votes.get) if votes else (0, 0)

    def pts_of(d):
        return [[float(a) + dx, float(b) + dy] for a, b in
                re.findall(r"[MLQCZ]?\s*(-?[\d.]+)[ ,]+(-?[\d.]+)", d)]

    # fill="none" = line, everything else with a fill = arrowhead
    raw = re.findall(r'<path\s+d="([^"]+)"\s+fill="([^"]+)"', body)
    lines = [pts_of(d) for d, f in raw if f.lower() == "none"]
    heads = [pts_of(d) for d, f in raw if f.lower() != "none"]

    boxes = {b["id"]: b for b in nodes}

    def nearest(pt):
        best, bd = None, 1e18
        for bid, b in boxes.items():
            cx = min(max(pt[0], b["x"]), b["x"] + b["w"])
            cy = min(max(pt[1], b["y"]), b["y"] + b["h"])
            d2 = (cx - pt[0]) ** 2 + (cy - pt[1]) ** 2
            if d2 < bd:
                best, bd = bid, d2
        return best, bd ** 0.5

    def closest_head(pt, tol=14):
        best, bd = None, tol
        for h in heads:
            d = min(((q[0] - pt[0]) ** 2 + (q[1] - pt[1]) ** 2) ** 0.5 for q in h)
            if d < bd:
                bd, best = d, h
        return best

    out, dropped = [], []
    for P in lines:
        if len(P) < 2:
            continue
        s_id, sd = nearest(P[0])
        t_id, td = nearest(P[-1])
        if s_id is None or t_id is None or s_id == t_id or max(sd, td) > 40:
            # Do NOT drop silently. An edge whose endpoint sits too far from
            # any block otherwise vanishes from the picture without a trace --
            # which really happened for preproc->axis, whose target block was
            # 62 units off. A missing arrow in a drawing with 38 edges catches
            # nobody's eye; a message does.
            dropped.append("%s->%s (%.0f/%.0f units from the block)"
                           % (s_id, t_id, sd, td))
            continue
        out.append({"s": s_id, "t": t_id, "pts": P[1:-1],
                    "path": P, "head": closest_head(P[-1])})
    for d in dropped:
        print("  DISCARDED: edge %s -- endpoint hits no block" % d)
    return out


def norm(v):
    """Bring a label to a comparison key."""
    v = re.sub(r"<[^>]+>", " ", v or "")
    return " ".join(html.unescape(v).split()).lower()


def resolve_ids(nodes, conts, edges, meas_path):
    """Map cell ids onto the dashboard blocks -- by ID, else by LABEL.

    On a redraw (copy/paste instead of move) draw.io hands out NEW ids:
    cpu0/tip0/preproc0 become 3/4/5. Pure id matching then finds nothing at
    all. The labels stay, however, and they are unique enough -- the measured
    block text (h3) is the key.

    Ambiguous names (three times "Preproc" in the trio) are assigned in order
    of their y position: topmost in the drawing -> row 0.
    """
    meas = json.loads(meas_path.read_text(encoding="utf-8"))
    want = {}
    for b in meas["blocks"]:
        head = norm(b["texts"][0]["text"]) if b["texts"] else ""
        want.setdefault(head, []).append(b["id"])
    for k in want:
        want[k].sort(key=lambda i: (i[:-1] if i[-1].isdigit() else i,
                                    int(i[-1]) if i[-1].isdigit() else 0))

    if all(any(n["id"] == b["id"] for b in meas["blocks"]) for n in nodes):
        return nodes, conts, edges, 0        # the ids already match

    # Containers are otherwise recognised by the id prefix "ct" -- which no
    # longer exists after a redraw. They do carry the encoder label, though.
    moved = [n for n in nodes if norm(n.get("label")).startswith("cedartools")]
    if moved:
        nodes = [n for n in nodes if n not in moved]
        conts = list(conts) + moved

    # The ingress stage has a different name per scenario (TIP adapter / ITI
    # shim / H2E->TIP). Whoever puts "ITI shim" above the MicroBlaze in the
    # drawing still means the ingress block -- hence an alias onto tip*.
    INGRESS = ("tip adapter", "iti shim", "h2e->tip", "h2e -> tip")
    tips = sorted([b["id"] for b in meas["blocks"] if b["id"].startswith("tip")])

    # Blocks the dashboard does not know YET (someone drew in a "Kria PS")
    # get a derived id instead of being discarded.
    NEW = {"kria ps": "kriaps"}

    used, ren, tipn, newn = {k: 0 for k in want}, {}, 0, {}
    for n in sorted(nodes, key=lambda n: (n["y"], n["x"])):
        lbl = norm(n.get("label"))
        hit = next((k for k in want if lbl.startswith(k) and k), None)
        if hit and used[hit] < len(want[hit]):
            ren[n["id"]] = want[hit][used[hit]]
            used[hit] += 1
            continue
        if any(lbl.startswith(i) for i in INGRESS) and tipn < len(tips):
            ren[n["id"]] = tips[tipn]; tipn += 1
            continue
        base = next((v for k, v in NEW.items() if lbl.startswith(k)), None)
        if base:
            i = newn.get(base, 0); newn[base] = i + 1
            ren[n["id"]] = "%s%d" % (base, i)
    for i, c in enumerate(sorted(conts, key=lambda c: (c["y"], c["x"]))):
        ren[c["id"]] = "ct%d" % i

    for n in nodes + conts:
        n["id"] = ren.get(n["id"], n["id"])
    keep = []
    for e in edges:
        e["s"], e["t"] = ren.get(e["s"], e["s"]), ren.get(e["t"], e["t"])
        if not e["s"][:1].isdigit() and not e["t"][:1].isdigit():
            keep.append(e)
    unresolved = sum(1 for n in nodes if n["id"][:1].isdigit())
    return [n for n in nodes if not n["id"][:1].isdigit()], conts, keep, unresolved


def geometry_for(sid):
    # Hand-drawn variants carry their own name suffix and therefore lie
    # outside every path the exporter writes to -- they cannot be steamrolled.
    # They take precedence over everything else.
    aw = sorted(GUI.glob("ctte_view_%s_aw*.drawio.svg" % sid))
    svg = aw[-1] if aw else GUI / ("ctte_view_%s.drawio.svg" % sid)
    if svg.exists():
        txt = svg.read_text(encoding="utf-8", errors="replace")
        mx_src = model_of(svg)
        for name, xml in diagrams(mx_src):
            if name in ("", sid):
                nodes, conts, edges = parse_model(xml)
                meas = GUI / "measured" / ("geo_%s.json" % sid)
                # Drawings from compact_layout.py ALREADY carry the canonical
                # ids -- sending them through resolve_ids() would mean guessing
                # correct ids afresh from labels. That is genuinely dangerous:
                # a block the older measurement did not know yet (axis0 in the
                # MBV build) makes the all() shortcut fail, and after that the
                # label matching reassigns ids by y position. The generator
                # states in the mxfile that it was the author -- and BOTH marks
                # are recognised: "devtools/..." is the current one (this
                # repo), "gui/..." the one from the predecessor repository that
                # every already-committed .drawio.svg still carries (they were
                # copied, not regenerated -- a blind rename would have
                # misclassified them here as hand-edited).
                if ('agent="devtools/compact_layout.py"' in mx_src
                        or 'agent="gui/compact_layout.py"' in mx_src):
                    meas = None
                if meas is not None and meas.exists():
                    nodes, conts, edges, un = resolve_ids(nodes, conts, edges, meas)
                    if un:
                        print("  NOTE %s: %d cell(s) without a mapping "
                              "(the label matches no block)" % (sid, un))
                drawn = rendered_paths(txt, nodes, conts)
                if drawn:
                    # Drawn routes beat the ones derived from the model --
                    # they ARE what was visible in the drawio.
                    by = {(e["s"], e["t"]): e for e in drawn}
                    for e in edges:
                        d = by.get((e["s"], e["t"]))
                        if d:
                            # Take the head ALONG -- without the arrowhead an
                            # edge is left as a stub (really measured: 1 of 10
                            # heads made it through).
                            e["pts"], e["path"] = d["pts"], d["path"]
                            e["head"] = d.get("head")
                    have = {(e["s"], e["t"]) for e in edges}
                    edges += [d for d in drawn
                              if (d["s"], d["t"]) not in have]
                return nodes, conts, edges, svg.name
    multi = GUI / "ctte_view.drawio"
    if multi.exists():
        for name, xml in diagrams(model_of(multi)):
            if name == sid:
                return parse_model(xml) + (multi.name,)
    meas = GUI / "measured" / ("geo_%s.json" % sid)
    if meas.exists():
        return from_measured(meas) + (meas.name,)
    raise SystemExit("no geometry source for scenario %r" % sid)


def main() -> int:
    cat = json.loads(SCEN.read_text(encoding="utf-8"))
    src = INDEX.read_text(encoding="utf-8")
    # Known blocks = the keys of NODE_TPL. A regex over the whole file raised
    # false alarms for perfectly valid ids (34 warnings on correct geometry)
    # -- a check that shouts at correct content gets ignored instead of read.
    m = re.search(r"const NODE_TPL\s*=\s*\{(.*?)\n\};", src, re.S)
    known = set()
    if m:
        for k in re.findall(r"(?m)^\s*([a-z][a-z0-9]*)\s*:", m.group(1)):
            known.add(k[:-1] if k[-1].isdigit() else k)

    out, total, warned = {}, 0, 0
    for sc in cat["scenarios"]:
        sid = sc["id"]
        nodes, conts, edges, origin = geometry_for(sid)
        for n in nodes:
            base = n["id"][:-1] if n["id"][-1].isdigit() else n["id"]
            if known and base not in known:
                print("  WARNING %s: unknown block id %r -- taken over, "
                      "but the dashboard has no template for it"
                      % (sid, n["id"]))
                warned += 1
        allv = nodes + conts
        ox = min([v["x"] for v in allv] or [0])
        oy = min([v["y"] for v in allv] or [0])
        # Only the matching here needs the labels, the runtime does not.
        # Writing them out would carry core names back into the front-end
        # code -- exactly what the corresponding test prevents.
        for v in nodes + conts:
            v.pop("label", None)
        out[sid] = {"source": origin, "ox": ox, "oy": oy,
                    "containers": conts, "nodes": nodes, "edges": edges}
        total += len(nodes)
        print("  %-11s %2d nodes · %d containers · %2d edges   <- %s"
              % (sid, len(nodes), len(conts), len(edges), origin))

    blob = "const ARCH_BY_SCEN=" + json.dumps(out, separators=(",", ":")) + ";"
    i, j = src.index(BEGIN), src.index(END)
    head = src[:i] + (
        "/* ARCH-GEOMETRY-BEGIN (generated by devtools/sync_arch_view.py -- ONE "
        "geometry PER SCENARIO; edit the drawio, then re-run; do not edit "
        "by hand) */\n" + blob + "\n")
    INDEX.write_text(head + src[j:], encoding="utf-8")
    GEOJSON.write_text(json.dumps(out, indent=1), encoding="utf-8")
    print("written: %d scenarios, %d nodes%s"
          % (len(out), total, (" (%d warnings)" % warned) if warned else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
