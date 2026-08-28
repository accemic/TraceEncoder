#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Recording helper: a window data set from the demo capture (analysis).

NOTE: the website no longer uses this data set -- it embeds the original
dashboard as a replay, and `record_web_replay.py` produces that data set. This
script stays as a measurement and analysis tool: it established the largest
cleanly decoding prefix (13,436 of 262,144 B), the loop periodicity (53 %
self-coverage at period 6048) and the prefix stability of the decoder.

From the **recorded** demo artefacts of this directory it builds a
record-and-replay data set that the website plays back without a board,
without a server and without network access. The decoder runs here, not in the
browser.

    py record_web_demo.py -o <website>/site/public/ctte-demo

Method (the reason the numbers hold up)
---------------------------------------
A window taken from the middle of the byte stream cannot be decoded on its
own -- it starts inside a cut message and the decoder rejects it. So decoding
happens not per window but **per prefix**: for ascending byte bounds
L0 < L1 < ... < Ln the stream [0, Li) is decoded. Window i is then the
difference of two real decode runs -- bytes [L(i-1), Li) and the instructions
that appeared with them.

That is only valid if the decoder is prefix-stable (a longer run yields the
same first N PCs). The script **checks** that instead of assuming it, and
aborts on any deviation.

The upper bound is the **largest cleanly decoding prefix** of the capture,
determined by bisection. Beyond it the decoder aborts (the capture is a slice,
and `demo/cva6_linux.pcinfo` covers the OpenSBI phase, not the whole boot) --
a window past that point would no longer be a measurement.

What does NOT travel (on purpose, not forgotten)
------------------------------------------------
* **The register map** (`regmap.json`) and every register view -- a release
  decision.
* **Scenario internals** (`scenarios.json`) -- likewise.
* **The FIFO fill histogram** -- in demo mode the server rolls dice for the
  bins (`DemoBus._tick`). A diced histogram next to real decode numbers is a
  prop, and synthetic data is not a hardware capture.
* **Everything except CVA6** -- the MicroBlaze V capture would be a measured
  number about third-party IP.
* **Any density statement as a metric.** The slice is a repeating early boot
  loop (measured: the PC sequence covers itself to 53 % at period 6048). Bits
  per instruction over such a slice is a loop artefact, not a workload
  measurement. The script computes the sizes so that they can be followed --
  the website presents them as the size of THIS slice and not as a metric.

The data set carries its provenance with it: every input file with size and
SHA-256, the decoder invocation verbatim, and the version of the decoder.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import insight  # noqa: E402  (lives next to this script)

# ---------------------------------------------------------------------------
# Inputs -- exclusively the checked-in demo artefacts
# ---------------------------------------------------------------------------
TRACE = HERE / "demo" / "demo_trace_cva6_linux.bin"
PCINFO = HERE / "demo" / "cva6_linux.pcinfo"
SYMBOLS = HERE / "demo" / "symbols_sbi.map"
CONSOLE = HERE / "demo" / "console_linux.txt"

# Where the pinned reference decoder lands: bin/, filled by
# `py scripts/fetch_cttd.py` (scripts/cttd.pin). The two entries that used to
# stand here pointed into a third_party/ layout of the PREDECESSOR repository,
# which this tree does not have -- so neither candidate could ever resolve.
NEXRV_CANDIDATES = [
    HERE.parents[1] / "bin" / ("cttd-windows-x64.exe" if os.name == "nt"
                               else "cttd-linux-x86_64"),
    HERE.parents[1] / "bin" / ("NexRv.exe" if os.name == "nt" else "NexRv"),
]

WINDOWS = 6          # number of windows; they tile the clean prefix
CONSOLE_LINES = 220  # excerpt of the boot capture (data budget)


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def find_nexrv() -> Path:
    for c in NEXRV_CANDIDATES:
        if c.is_file():
            return c
    raise SystemExit("NexRv not found: " +
                     ", ".join(str(c) for c in NEXRV_CANDIDATES))


VERSION_LINE = re.compile(r"^NexRv\b.*\bv\d+\.\d+")


def nexrv_version(nexrv: Path) -> str:
    """The version line sits in the usage help.

    The first block of output is an error line ("Unkown option") -- a naive
    "first line that starts with the tool name" fishes out exactly that one
    and writes it into the provenance as the decoder version (measured
    2026-08-11). Hence the match is on the version number.
    """
    r = subprocess.run([str(nexrv), "-help"], capture_output=True, text=True)
    for line in ((r.stdout or "") + (r.stderr or "")).splitlines():
        if VERSION_LINE.match(line.strip()):
            return line.strip()
    return "unknown"


class Decoder:
    """One decoder run over a prefix of the capture."""

    def __init__(self, nexrv: Path, raw: bytes, pcinfo: Path, workdir: Path):
        self.nexrv, self.raw, self.pcinfo, self.wd = nexrv, raw, pcinfo, workdir
        self.calls = 0

    def cmdline(self, n: int) -> list[str]:
        return [str(self.nexrv), "-deco", str(self.wd / "trace.bin"),
                "-pcinfo", str(self.pcinfo),
                "-pcout", str(self.wd / "out.pcout"), "-stat"]

    def run(self, n: int):
        """(ok, pcs) for the prefix [0, n)."""
        (self.wd / "trace.bin").write_bytes(self.raw[:n])
        cmd = self.cmdline(n)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        self.calls += 1
        out = (r.stdout or "") + (r.stderr or "")
        ok = r.returncode == 0 and "Decoded OK" in out
        pcs = insight.parse_pcout((self.wd / "out.pcout").read_bytes())
        return ok, pcs


def message_boundaries(raw: bytes) -> list[int]:
    """Byte offsets where a new message starts.

    Nexus MSEO: `0b11` ends a message, `0b00` begins the next one. A cut at
    such a boundary lets the prefix end on whole messages -- exactly what the
    decoder requires.
    """
    out = []
    prev_end = False
    for i, b in enumerate(raw):
        if prev_end and (b & 0x3) == 0x0:
            out.append(i)
        prev_end = (b & 0x3) == 0x3
    return out


def largest_clean_prefix(dec: Decoder, hi: int) -> tuple[int, list[int]]:
    """Largest prefix that NexRv decodes to the end without error (bisection)."""
    lo = 0
    ok, pcs = dec.run(hi)
    if ok:
        return hi, pcs
    while hi - lo > 1:
        mid = (lo + hi) // 2
        ok, _ = dec.run(mid)
        if ok:
            lo = mid
        else:
            hi = mid
    ok, pcs = dec.run(lo)
    if not ok:
        raise SystemExit("no cleanly decoding prefix found")
    return lo, pcs


def touched_symbols(pcs, symbols):
    """[[start, end, name], ...] -- only the symbols that actually occur.

    The lookup happens in the browser by bisection. One symbol name per
    instruction would be the same name ten thousand times over; the whole
    OpenSBI table would be 748 entries for the three dozen the slice touches.
    """
    hit = {}
    for pc in pcs:
        name, start, _off = symbols.lookup(pc)
        if name is None:
            continue
        i = symbols.addrs.index(start)
        hit[start] = (start, symbols.ends[i], name)
    return [list(v) for v in sorted(hit.values())]


def rle_encode(pcs):
    """[startPC, [d, n], [d, n], ...] -- a stride and how often it repeats.

    Measured over the slice: 47,892 of 53,039 transitions are exactly +4
    (RV64, uncompressed instruction). The run-length form therefore costs
    80 KB instead of 127 KB flat.
    """
    if not pcs:
        return []
    runs = []
    cur, n = None, 0
    for a, b in zip(pcs, pcs[1:]):
        d = b - a
        if d == cur:
            n += 1
        else:
            if cur is not None:
                runs.append([cur, n])
            cur, n = d, 1
    if cur is not None:
        runs.append([cur, n])
    return [pcs[0]] + runs


def console_excerpt(path: Path, lines: int) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    rows = [ln.rstrip("\r") for ln in text.splitlines()]
    return rows[:lines]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", required=True,
                    help="target directory (site/public/ctte-demo of the website)")
    ap.add_argument("--windows", type=int, default=WINDOWS)
    args = ap.parse_args()

    for p in (TRACE, PCINFO, SYMBOLS, CONSOLE):
        if not p.is_file():
            raise SystemExit("missing: %s" % p)

    nexrv = find_nexrv()
    raw = TRACE.read_bytes()
    symbols = insight.SymbolTable.from_file(SYMBOLS)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    wd = Path(tempfile.mkdtemp(prefix="ctte_web_"))
    try:
        dec = Decoder(nexrv, raw, PCINFO, wd)

        t0 = time.time()
        clean, full_pcs = largest_clean_prefix(dec, len(raw))
        print("clean prefix: %d of %d bytes -> %d instructions"
              % (clean, len(raw), len(full_pcs)))

        bounds = [b for b in message_boundaries(raw[:clean]) if b > 0]
        if len(bounds) < args.windows:
            raise SystemExit("too few message boundaries (%d)" % len(bounds))

        # Cuts spread evenly over the prefix, each on a message boundary. The
        # last cut is the prefix itself.
        cuts = []
        for k in range(1, args.windows):
            target = clean * k // args.windows
            cuts.append(min(bounds, key=lambda b: abs(b - target)))
        cuts = sorted(set(cuts)) + [clean]

        # Prefix decodes. Every one of them is a real decoder run.
        marks = [(0, [])]
        for c in cuts:
            ok, pcs = dec.run(c)
            if not ok:
                raise SystemExit("prefix %d does not decode cleanly" % c)
            prev_n = len(marks[-1][1])
            if pcs[:prev_n] != marks[-1][1]:
                raise SystemExit(
                    "prefix stability violated at %d bytes: the first %d "
                    "PCs differ from the shorter run" % (c, prev_n))
            marks.append((c, pcs))
            print("  prefix %6d bytes -> %7d instructions" % (c, len(pcs)))

        if marks[-1][1] != full_pcs:
            raise SystemExit("final run deviates from the bisection run")

        # Message mix per window as the DIFFERENCE of two prefix scans.
        # Scanning the byte slice directly would miss its first message:
        # `scan_messages` recognises a start only by the preceding end marker,
        # which the slice does not contain. Taken as a difference, the windows
        # sum exactly to the total.
        def scan_prefix(n):
            c, m, idl, _ = insight.scan_messages(raw[:n])
            return c, m, idl

        windows, total_bytes, total_instr, total_msgs = [], 0, 0, 0
        for i in range(1, len(marks)):
            b0, p0 = marks[i - 1]
            b1, p1 = marks[i]
            wraw = raw[b0:b1]
            wpcs = p1[len(p0):]
            c1, m1, i1 = scan_prefix(b1)
            c0, m0, i0 = scan_prefix(b0)
            counts = {t: c1.get(t, 0) - c0.get(t, 0) for t in c1}
            counts = {t: c for t, c in counts.items() if c}
            msgs, idle = m1 - m0, i1 - i0
            # The leading function of the window -- the label in the picker.
            span = {}
            for pc in wpcs:
                name, _s, _o = symbols.lookup(pc)
                key = name or "\u2014"
                span[key] = span.get(key, 0) + 1
            lead = max(span.items(), key=lambda kv: kv[1])[0] if span else "\u2014"
            windows.append({
                "index": i - 1,
                "byte_from": b0, "byte_to": b1, "bytes": len(wraw),
                "instructions": len(wpcs),
                "messages": msgs, "idle_bytes": idle,
                "message_mix": sorted(
                    ({"tcode": t,
                      "name": insight.TCODE_NAMES.get(t, "TCODE %d" % t),
                      "count": c} for t, c in counts.items()),
                    key=lambda r: -r["count"]),
                "lead_symbol": lead,
                "functions": len(span),
                "hex": wraw.hex(),
                "pcs": rle_encode(wpcs),
            })
            total_bytes += len(wraw)
            total_instr += len(wpcs)
            total_msgs += msgs

        # The windows have to tile the prefix without a remainder -- otherwise
        # the head of the demo claims a total the windows do not add up to.
        if total_bytes != clean or total_instr != len(full_pcs):
            raise SystemExit("windows do not tile the prefix (%d/%d B, %d/%d I)"
                             % (total_bytes, clean, total_instr, len(full_pcs)))

        # Hot list over the whole clean prefix -- a real decode, a real symbol
        # table, no extrapolation.
        heat = {}
        for pc in full_pcs:
            name, _s, _o = symbols.lookup(pc)
            heat[name or "\u2014"] = heat.get(name or "\u2014", 0) + 1
        heat_rows = sorted(heat.items(), key=lambda kv: -kv[1])[:12]

        counts, msgs, idle, _ = insight.scan_messages(raw[:clean])
        manifest = {
            "generated": time.strftime("%Y-%m-%d %H:%M %Z"),
            "generator": "examples/dashboard/record_web_demo.py (CEDARtools.TraceEncoder)",
            "scenario": {
                "id": "cva6_linux",
                "core": "CVA6",
                "workload": "Linux 6.12 boot, OpenSBI phase",
                "protocol": "N-Trace",
            },
            "capture": {
                "file_bytes": len(raw),
                "decoded_bytes": clean,
                "instructions": len(full_pcs),
                "messages": msgs,
                "idle_bytes": idle,
                "decode_seconds": round(time.time() - t0, 1),
                "decoder_calls": dec.calls,
                # Deliberately NO density metric -- see the module header.
                "density_note": "loop-dominated excerpt; not a workload figure",
            },
            "message_mix": sorted(
                ({"tcode": t, "name": insight.TCODE_NAMES.get(t, "TCODE %d" % t),
                  "count": c, "share": round(c / msgs, 4) if msgs else 0}
                 for t, c in counts.items()), key=lambda r: -r["count"]),
            "heat": [{"symbol": n, "instructions": c,
                      "share": round(c / len(full_pcs), 4)} for n, c in heat_rows],
            "windows": [{k: w[k] for k in
                         ("index", "byte_from", "byte_to", "bytes",
                          "instructions", "messages", "idle_bytes",
                          "lead_symbol", "functions")} for w in windows],
            "console_lines": CONSOLE_LINES,
            "symbols": {"count": symbols.count, "source": SYMBOLS.name,
                        "touched": len(touched_symbols(full_pcs, symbols))},
            "provenance": {
                "decoder": nexrv_version(nexrv),
                "decoder_command":
                    "NexRv -deco <prefix>.bin -pcinfo %s -pcout <out> -stat"
                    % PCINFO.name,
                "inputs": [
                    {"file": p.name, "bytes": p.stat().st_size,
                     "sha256": sha256(p)}
                    for p in (TRACE, PCINFO, SYMBOLS, CONSOLE)
                ],
            },
        }
        console = {"lines": console_excerpt(CONSOLE, CONSOLE_LINES),
                   "source": CONSOLE.name,
                   "total_lines": len(console_excerpt(CONSOLE, 10 ** 9))}

        # `manifest.json` is the readable summary for a review, `dataset.json`
        # is what the site build embeds.
        (out / "manifest.json").write_text(
            json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
        (out / "dataset.json").write_text(
            json.dumps({"manifest": manifest, "windows": windows,
                        "symbols": touched_symbols(full_pcs, symbols),
                        "console": console},
                       separators=(",", ":"), ensure_ascii=False),
            encoding="utf-8")

        sizes = sorted(((f.stat().st_size, f.name) for f in out.iterdir()
                        if f.is_file()), reverse=True)
        print("\nwritten to %s" % out)
        for s, n in sizes:
            print("  %8d B  %s" % (s, n))
        ds = (out / "dataset.json").read_bytes()
        import gzip
        print("\nembedded payload: %d B (gzip %d B)"
              % (len(ds), len(gzip.compress(ds, 9))))
        return 0
    finally:
        shutil.rmtree(wd, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
