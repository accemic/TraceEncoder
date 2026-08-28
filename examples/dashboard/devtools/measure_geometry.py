# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Measure the RENDERED geometry of the dashboard, per scenario.

Why measure instead of compute: the page does not draw the ARCH coordinates,
it scales them (SCALE is determined at runtime from the stage size --
currently 1.78, not the 2.4 in the source), sets font sizes via CSS and
computes the arrows in layoutWires() itself. An export from ARCH
therefore matches neither the edge routing nor the text sizes (from the
request "give me a genuine 1:1 geometry").

    py devtools/measure_geometry.py [port] [target directory]

Requires a running dashboard server (demo mode is enough):
    py server.py --demo --port 8142   (from examples/dashboard/)
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# ROOT is this script's own directory (devtools/, the former gui/); see
# export_drawio.py for why the old ROOT/"tools"/"ctrace_dashboard" path
# collapses to ROOT.parent in this repository's layout.
ROOT = Path(__file__).resolve().parent
EDGE = Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe")
SCEN = ROOT.parent / "scenarios.json"


def measure(port, scen, work):
    """Load one scenario view and collect its geodump.

    --dump-dom is the way in: JS return values do not come back out of headless
    mode, so the page puts the result into the DOM as a <pre>.
    """
    url = "http://localhost:%s/?scen=%s&geodump=1" % (port, scen)
    r = subprocess.run([str(EDGE), "--headless=new", "--disable-gpu",
                        "--user-data-dir=%s" % (work / ("p_" + scen)),
                        "--window-size=1700,1100",
                        "--virtual-time-budget=9000", "--dump-dom", url],
                       capture_output=True, timeout=180)
    dom = r.stdout.decode("utf-8", "replace")
    m = re.search(r'<pre id="geodump"[^>]*>(.*?)</pre>', dom, re.S)
    if not m:
        raise SystemExit("%s: no geodump in the DOM -- is the server running on "
                         "Port %s?" % (scen, port))
    txt = m.group(1)
    for a, b in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"')]:
        txt = txt.replace(a, b)
    return json.loads(txt)


def main() -> int:
    port = sys.argv[1] if len(sys.argv) > 1 else "8142"
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "measured"
    out.mkdir(parents=True, exist_ok=True)
    # browser profiles into scratch, not next to the measurements -- otherwise
    # hundreds of cache files would land in the repo (happened for real, ab96df0).
    work = Path(tempfile.mkdtemp(prefix="ctte_geo_"))
    cat = json.loads(SCEN.read_text(encoding="utf-8"))
    for sc in cat["scenarios"]:
        g = measure(port, sc["id"], work)
        (out / ("geo_%s.json" % sc["id"])).write_text(
            json.dumps(g, indent=1, ensure_ascii=False), encoding="utf-8")
        print("  %-11s %2d blocks · %d containers · %2d edges · stage %dx%d "
              "· SCALE %.3f" % (sc["id"], len(g["blocks"]), len(g["containers"]),
                                len(g["edges"]), g["stage"]["w"], g["stage"]["h"],
                                g["scale"]))
    shutil.rmtree(work, ignore_errors=True)
    print("measured -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
