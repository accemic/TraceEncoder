#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Recording v2 for the website replay of the ORIGINAL dashboard.

    py record_web_replay.py -o <website>/assets/ctte-demo/dashboard

v2: two scenarios -- **rocket2 (default)** and **cva6_linux** -- with a RESET
state (before Run) and a RUN sequence as a time series per scenario, plus a
**console schedule taken from the kernel timestamps** of the real recording
(15 s are 15 s -- the flat 2000 characters/s of v1 was too fast) and a
**livepc series** at the UI poll rate (2.5 s), so that the bpi chart moves
instead of standing on a single value.

The shim on the website plays that back: Run = series from the start, Stop =
freeze the state, scenario change = reset. Controlling endpoints are still NOT
recorded -- this is a read-only replay.

Console schedule -- what is measured and what is presentation:

* Kernel lines carry their timestamp `[ ss.uuuuuu ]` -- the schedule puts them
  EXACTLY there (measured; the source is the recording itself).
* Lines BEFORE the first timestamp (the OpenSBI banner) are rolled out from
  t=0 at UART speed 115200 8N1 (~11,520 characters/s) -- an approximation,
  and named as one.
* Lines AFTER the last timestamp (init/services/login) advance by 0.4 s per
  line; typed input (the login part) at 80 ms per character with a 1.5 s pause
  for thought before the prompt. That is presentation timing, not a
  measurement -- and the manifest says so.

Sources per scenario (all real captures; their preparation is documented in
make_demo_console.py):

| Scenario   | Console                      | Demo stream                         |
|------------|------------------------------|-------------------------------------|
| rocket2    | demo/console_rocket2.txt     | demo/demo_trace_rocket2.bin (board capture)      |
| cva6_linux | demo/console_cva6_linux.txt  | demo/demo_trace_cva6_linux.bin (boot recording)  |

There is additionally a PUBLIC export. The default above stays unchanged --
full provenance, all comments, a hash per file; that is what developers need.
For the website there is, alongside it:

    py record_web_replay.py --public --from-bundle <internal-bundle> -o <dest>
    py record_web_replay.py --public -o <dest>        # record afresh

The first way is preferred: it converts an EXISTING bundle, deterministically,
without a board and without a decoder. What happens in the process is
described further down under "PUBLIC EXPORT"; the interlock is
check_replay_public.py, which the export applies to its own output.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PORT = 8123
BASE = "http://127.0.0.1:%d" % PORT

SCENARIOS = ["rocket2", "cva6_linux"]
DEFAULT = "rocket2"
SERIES_SECONDS = {"rocket2": 45, "cva6_linux": 75}
LIVE_EVERY = 2.5            # UI poll rate of the bpi chart
TRACE_EVERY = 5
REGION_DUMP_BYTES = 0x1000

UART_CPS = 11520            # 115200 Baud 8N1
TAIL_LINE_S = 0.4           # lines after the last kernel timestamp
TYPE_CPS = 12               # typed characters (login part)
PROMPT_PAUSE_S = 1.5

STAMP = re.compile(r"^\[\s*(\d+)\.(\d{6})\]")


def get(path: str, timeout=300):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        return r.read()


def get_json(path: str, timeout=300):
    return json.loads(get(path, timeout))


def post_json(path: str, body: dict, timeout=60):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    h.update(p.read_bytes())
    return h.hexdigest()


def console_schedule(text: str):
    """[[ms, charOffset], ...] - when how much of the console is visible.

    Offsets are CHARACTERS into the text (line breaks included); the shim
    shows text[:offset]. Monotonically increasing, one mark per line (several
    per line where input is typed, for the typing effect).
    """
    sched: list[list[int]] = [[0, 0]]
    t = 0.0
    off = 0
    last_stamp = None
    interactive = False
    for line in text.split("\n"):
        n = len(line) + 1
        m = STAMP.match(line)
        if m:
            t = max(t, int(m.group(1)) + int(m.group(2)) / 1e6)
            last_stamp = t
        elif "login:" in line and last_stamp is not None:
            interactive = True
            t += PROMPT_PAUSE_S
        elif interactive and line.startswith(("#", "$")) is False and line.strip() \
                and last_stamp is not None and "login:" not in line:
            t += TAIL_LINE_S
        elif last_stamp is None:
            t += n / UART_CPS
        else:
            t += TAIL_LINE_S
        if interactive and ("login: " in line or line.startswith("# ")):
            # The typed part of the line appears character by character.
            typed_at = line.find(": ") + 2 if "login: " in line else 2
            base = off + typed_at
            for k in range(max(0, len(line) - typed_at)):
                t += 1.0 / TYPE_CPS
                sched.append([int(t * 1000), base + k + 1])
        off += n
        sched.append([int(t * 1000), min(off, len(text))])
    return sched


class Recorder:
    def __init__(self, out: Path):
        self.out = out
        self.rec = {"meta": {"default": DEFAULT, "scenarios": SCENARIOS,
                             "version": 2},
                    "shared": {}, "scenarios": {}, "provenance": {}}

    def record_scenario(self, sc_id: str):
        srv = subprocess.Popen(
            [sys.executable, str(HERE / "server.py"), "--demo",
             "--port", str(PORT), "--scenario", sc_id],
            cwd=str(HERE), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(60):
                try:
                    get_json("/api/mode", timeout=2)
                    break
                except Exception:
                    time.sleep(0.5)
            else:
                raise SystemExit("demo server (%s) does not answer" % sc_id)

            s: dict = {"state_series": [], "livepc_series": [],
                       "trace_series": [], "endpoints": {}, "regions": {}}

            # RESET state: the known starting point before every run.
            s["reset_state"] = get_json("/api/state")
            for p in ("/api/boot", "/api/symbols"):
                try:
                    s["endpoints"][p] = get_json(p)
                except Exception as e:
                    print("  MISSING %s (%s)" % (p, e))

            # Start the chain as on the device, then cut the series.
            # Bring the DDR sink up TOO (found 2026-08-12: the fill bars stood
            # still -- the sink had simply never been on). Window size as in
            # the board flow: 256 MiB, set BEFORE enabling.
            cat0 = get_json("/api/scenarios")
            act0 = next(x for x in cat0["scenarios"] if x["id"] == sc_id)
            off_ddr = (act0.get("ctrl") or {}).get("ddr_size")
            if off_ddr is not None:
                post_json("/api/write", {"region": "ctrl", "offset": off_ddr,
                                         "value": 256 * 1024 * 1024})
            post_json("/api/ctl", {"action": "run"})
            s["run_response"] = post_json("/api/ctl", {"action": "trace_on"})
            try:
                post_json("/api/ctl", {"action": "ddr_on"})
            except Exception as e:
                print("  ddr_on not possible: %s" % e)
            s["stop_response"] = None       # filled in after the series

            secs = SERIES_SECONDS[sc_id]
            print("  %s: %d s series ..." % (sc_id, secs))
            t0 = time.time()
            next_live = 0.0
            for tick in range(secs):
                s["state_series"].append(get_json("/api/state"))
                if time.time() - t0 >= next_live:
                    try:
                        s["livepc_series"].append(
                            {"t": tick, **get_json("/api/livepc?tail=2048")})
                    except Exception:
                        pass
                    next_live += LIVE_EVERY
                if tick % TRACE_EVERY == 0:
                    try:
                        s["trace_series"].append(get_json("/api/trace?tail=384"))
                    except Exception:
                        pass
                time.sleep(max(0.0, (tick + 1) - (time.time() - t0)))

            for p in ("/api/insight", "/api/coverage", "/api/events?n=300",
                      "/api/packets?tail=65536", "/api/fifohist?region=enc",
                      "/api/wp/status", "/api/wp/records"):
                try:
                    s["endpoints"][p] = get_json(p)
                except Exception as e:
                    print("  MISSING %s (%s)" % (p, e))
            print("  %s: decoding ..." % sc_id)
            try:
                s["endpoints"]["/api/decode?src=uram"] = get_json("/api/decode?src=uram")
                s["endpoints"]["/api/insight"] = get_json("/api/insight")
                s["endpoints"]["/api/coverage"] = get_json("/api/coverage")
            except Exception as e:
                print("  decode not recordable: %s" % e)

            # Run stop once for real, so the response shape is correct.
            s["stop_response"] = post_json("/api/ctl", {"action": "stop"})

            cat = get_json("/api/scenarios")
            if "/api/scenarios" not in self.rec["shared"]:
                cat["scenarios"] = [x for x in cat["scenarios"]
                                    if x["id"] in SCENARIOS]
                cat["active"] = DEFAULT
                self.rec["shared"]["/api/scenarios"] = cat
            active = next(x for x in self.rec["shared"]["/api/scenarios"]["scenarios"]
                          if x["id"] == sc_id)
            for name, reg in (active.get("regions") or {}).items():
                if name in ("ram", "trace", "axis", "con"):
                    continue
                n = min(reg["size"], REGION_DUMP_BYTES) // 4
                words: list[int] = []
                off = 0
                while len(words) < n:
                    chunk = min(4096, n - len(words))
                    words += get_json("/api/read?region=%s&off=%d&n=%d"
                                      % (name, off, chunk))["words"]
                    off += chunk * 4
                s["regions"][name] = {"base": reg["base_int"],
                                      "size": reg["size"], "words": words}

            con = HERE / "demo" / ("console_%s.txt" % sc_id)
            text = con.read_text(encoding="utf-8")
            s["console"] = {"text": text, "schedule": console_schedule(text),
                            "source": con.name,
                            "timing": "kernel stamps exact; pre-stamp lines "
                                      "at 115200 baud; post-stamp and typed "
                                      "lines are presentation pacing"}
            self.rec["scenarios"][sc_id] = s
        finally:
            srv.terminate()
            try:
                srv.wait(timeout=5)
            except Exception:
                srv.kill()

    def finish(self):
        self.rec["shared"]["/regmap.json"] = json.loads(
            (HERE / "regmap.json").read_text(encoding="utf-8"))
        self.rec["shared"]["/themes.json"] = json.loads(
            (HERE / "themes.json").read_text(encoding="utf-8"))
        # Block-to-CSR mapping: the dashboard loads it relatively via
        # fetch('block_csrs.json'); without recording it, the block panel of
        # the replay falls back to "No CSRs...".
        self.rec["shared"]["/block_csrs.json"] = json.loads(
            (HERE / "block_csrs.json").read_text(encoding="utf-8"))
        self.rec["shared"]["/api/mode"] = {"mode": "demo",
                                           "live_available": False,
                                           "live_error": None}
        shutil.copyfile(HERE / "index.html", self.out / "index.html")
        git = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(HERE),
                             capture_output=True, text=True).stdout.strip()
        files = {"index.html": HERE / "index.html",
                 "regmap.json": HERE / "regmap.json",
                 "themes.json": HERE / "themes.json",
                 "block_csrs.json": HERE / "block_csrs.json"}
        for sc in SCENARIOS:
            files["console_%s.txt" % sc] = HERE / "demo" / ("console_%s.txt" % sc)
            p = HERE / "demo" / ("demo_trace_%s.bin" % sc)
            if p.is_file():
                files[p.name] = p
        self.rec["provenance"] = {
            "generated": time.strftime("%Y-%m-%d %H:%M %z"),
            "generator": "examples/dashboard/record_web_replay.py (v2)",
            "source_repo": "TraceEncoder@" + (git[:12] or "unknown"),
            "default_scenario": DEFAULT,
            "server_mode": "demo (simulated registers; console and "
                           "trace stream from real board captures)",
            "files": {k: sha256(v) for k, v in files.items()},
        }
        (self.out / "replay.json").write_text(
            json.dumps(self.rec, separators=(",", ":"), ensure_ascii=False),
            encoding="utf-8")
        import gzip
        raw = (self.out / "replay.json").read_bytes()
        print("\nreplay.json: %d B (gzip %d B)" % (len(raw), len(gzip.compress(raw, 9))))


# ==========================================================================
# PUBLIC EXPORT
# ==========================================================================
# The bundle above is the INTERNAL state: full provenance, comments, source
# references, a hash per file. That is exactly what an external review found
# on the website. The public export below builds a bundle from it that
# carries ONLY what an outsider needs.
#
# The principle is an ALLOW LIST, in three stages -- plus one interlock:
#   1. STRUCTURE: only the sections, endpoints and scenario keys listed here
#      travel. Anything in no list drops out and is named in the export log.
#      A field added later therefore does not leak silently, it disappears
#      visibly.
#   2. PROVENANCE: rebuilt, not filtered. Only the five entries in
#      PUBLIC_PROVENANCE_FIELDS -- capture date, board/cores, trace protocol,
#      scenarios, and ONE checksum over the bundle.
#   3. TEXTS: annotation fields survive only if CLEAN. Every string runs
#      through the same patterns as the scanner (check_replay_public.py);
#      whatever trips it leaves together with its key. No partial redaction
#      that leaves half sentences behind.
#   4. INTERLOCK: at the end the export scans its own result. A single hit
#      and NOTHING is written (exit 1).
#
# The payload (state_series, livepc_series, trace_series, regions, console
# text and schedule, packet and event lists) stays untouched -- the replay
# has to behave byte for byte the same.

sys.path.insert(0, str(HERE))
import check_replay_public as scanner        # noqa: E402

PUBLIC_PROVENANCE_FIELDS = ("captured", "board", "cores", "trace_protocol",
                            "scenarios", "bundle_sha256")

# Board and protocol entry of the public provenance. Both are statements
# about the SETUP, not measurements: board = KV260 (every scenario in the
# catalogue runs in the PL of that board), protocol = N-Trace, evidenced by
# the fact that both scenarios decode with the N-Trace reference decoder.
# Cores and clock come from the catalogue, not from hand.
PUBLIC_BOARD = "AMD Kria KV260 (Zynq UltraScale+ MPSoC), design in the PL"
PUBLIC_PROTOCOL = "RISC-V N-Trace (Nexus) instruction trace"

PUBLIC_TOP_KEYS = ("meta", "shared", "scenarios", "provenance")
PUBLIC_META_KEYS = ("default", "scenarios", "version")
PUBLIC_SHARED_KEYS = ("/api/scenarios", "/regmap.json", "/themes.json",
                      "/block_csrs.json", "/api/mode")
PUBLIC_SCENARIO_KEYS = ("reset_state", "state_series", "livepc_series",
                        "trace_series", "endpoints", "regions",
                        "run_response", "stop_response", "console")
PUBLIC_ENDPOINTS = ("/api/boot", "/api/symbols", "/api/insight",
                    "/api/coverage", "/api/events?n=300",
                    "/api/packets?tail=65536", "/api/fifohist?region=enc",
                    "/api/wp/status", "/api/wp/records",
                    "/api/decode?src=uram")

# Keys that ALWAYS drop -- regardless of content, because by their nature
# they carry workbench state. A reason per entry.
PUBLIC_DROP_KEYS = {
    "ui_build": "md5 over the shipped server files (stale-cache guard of "
                "the live page); constant in the replay and shaped like "
                "a short commit id",
    "generated_from": "RDL source file from which regmap.json was generated",
    "files": "hash per file -- exactly the table from finding A-05",
    "source_repo": "repo name plus short commit id",
    "generator": "path of the generating script in the working tree",
}
# Individual locations instead of whole key names -- "path" does not mean
# the same everywhere (in regmap.json it holds the RDL register path, which
# the UI displays as the register name).
PUBLIC_DROP_PATHS = {
    "$.shared./api/scenarios.nexrv.path":
        "path of the decoder binary on the workbench. ONLY the path -- the "
        "sibling field 'available' stays, otherwise the UI reports "
        "'Decoder MISSING'.",
}
# Workbench paths that the UI DISPLAYS. Removing them entirely would put
# 'undefined' into the text; shortening to the file name says the same thing
# without naming the drive, the user and the tree of the development
# machine.
PUBLIC_BASENAME_KEYS = {
    "pcinfo": "pcinfo file of the decode",
    "live_pcinfo": "ditto, live variant",
    "source": "symbol map",
    "sites_source": "call-site map",
}
# Convention of these JSON trees: a leading underscore marks an INTERNAL
# annotation (_comment, _src, _ctrl_comment ...). Those go overboard as a
# group -- that is the "review comments" class.
PUBLIC_DROP_UNDERSCORE = True

# Renames BEFORE the check. Only documented name equivalences, no
# whitewashing: "C-Trace" is the informal short name of the product officially
# called CEDARtools.TraceEncoder (as stated in the header of index.html). A
# release artefact of the new name should no longer carry the old one.
PUBLIC_RENAME = [
    (re.compile(r"\bC-Trace\b"), "CTTE",
     "short name from before the rename to CEDARtools.TraceEncoder"),
]

# The same as HTML_REDACTIONS, but for texts INSIDE the recording object: a
# sentence that says nothing but useful things apart from the internal
# reference should not disappear entirely. Deliberately kept short -- the rule
# stays "clean or gone", and this is the named exception for texts the UI
# shows prominently. Zero hits = the list is stale = the export FAILS.
JSON_REDACTIONS = [
    (re.compile(r"\(\+64 MiB, ctrace_resmem\.dtso\)"),
     "(+64 MiB, reserved via device tree)",
     "CVA6 core description named the device-tree overlay of the working tree"),
    (re.compile(r" \(vivado/kv260_app/kv260_plclk\.sh\)"), "",
     "Rocket clock note named the board script of the working tree"),
]

# Visible texts in index.html that point at internal sources. The comment
# strip does not catch them, because they are genuine UI strings. Every
# replacement says the same thing without the reference; zero hits = the list
# is stale = the export FAILS (see public_index_html).
HTML_REDACTIONS = [
    # The former entry here ("tools/ctrace_dashboard/themes.json" in the help
    # text of the theme card) went away with the migration into this repo: the
    # cause was fixed AT THE SOURCE (index.html now says
    # "examples/dashboard/themes.json" -- a path INSIDE this example, no
    # longer a reference to the predecessor repository, and therefore no
    # longer a hit for the "repo_path" pattern of check_replay_public.py). A
    # redaction is only needed for what cannot be fixed at the source.
    (re.compile(r"\(RDL ct_cs_cpuif\.rdl:1440-1493, "
                r"SPEC_axis_wp_memory_map\.md §7\)"),
     "(see the AXIS watchpoint section of the register reference)",
     "tooltip pointed at RDL lines and an internal spec document "
     "(exactly the finding quoted in A-05)"),
    (re.compile(r"Source: docs/SPEC_axis_wp_memory_map\.md §7\."),
     "Source: the AXIS watchpoint section of the register reference.",
     "source reference of a hint text pointed into the docs tree"),
    (re.compile(r"\(<span class=\"mono\">dis_to_symbols\.py --sites</span>\)"),
     "(disassembly-derived call-site list)",
     "drop zone named the internal script that produces the file"),
    (re.compile(r"only the server drain \(wp_view\.py\) reads this window"),
     "only the server drain reads this window",
     "block description named the server module in the working tree"),
    (re.compile(r"\+'from \(md5 over index\.html, wp\.html, regmap\.json, '\s*"
                r"\n\s*\+'block_csrs\.json, scenarios\.json, server\.py\)\. "
                r"If the server '"),
     "+'from. If the server '",
     "tooltip of the build stamp listed the shipped server files"),
    (re.compile(r"\(vivado/kv260_app/duo_pib_pmod\.xdc\)\. "), "",
     "pin assignment named the internal constraints file "
     "(second finding quoted in A-05)"),
    (re.compile(r"tools/etrace_trio_demux\.py"), "the stream demultiplexer",
     "block description named a script of the working tree"),
]


def _verbatim(where: str) -> bool:
    """A field that stays VERBATIM -- recordings are not rewritten.

    This list is not a second truth: it is exactly the scanner's exemption
    table. Where the scanner tolerates a marker on purpose (because it comes
    from a measurement), the rename must not reach in either -- otherwise the
    export would silently falsify a recording protocol.
    """
    return any(fnmatch.fnmatch(where, ex["where"])
               for ex in scanner.EXEMPTIONS if ex["file"] == "replay.json")


_JSON_REDACT_HITS: dict = {}


def _rename(s: str) -> str:
    for rx, repl, _why in PUBLIC_RENAME:
        s = rx.sub(repl, s)
    for rx, repl, _why in JSON_REDACTIONS:
        s, n = rx.subn(repl, s)
        if n:
            _JSON_REDACT_HITS[rx.pattern] = _JSON_REDACT_HITS.get(rx.pattern, 0) + n
    return s


def _dirty(s: str, where: str):
    """Pattern ids this string trips inside the bundle (empty = clean)."""
    return sorted({f.pid for f in
                   scanner.string_findings(s, "replay.json", where)})


def _basename(v):
    """Path -> file name; lists element-wise, everything else unchanged."""
    if isinstance(v, str):
        return v.replace("\\", "/").rsplit("/", 1)[-1]
    if isinstance(v, list):
        return [_basename(x) for x in v]
    return v


class _Dirty:
    """A mark: this subtree carries an internal marker."""


DIRTY = _Dirty()


def _sanitize(node, where: str, log: list):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            sub = "%s.%s" % (where, k)
            if PUBLIC_DROP_UNDERSCORE and isinstance(k, str) and k.startswith("_"):
                log.append(("drop-underscore", sub, "internal annotation"))
                continue
            if k in PUBLIC_DROP_KEYS:
                log.append(("drop-key", sub, PUBLIC_DROP_KEYS[k]))
                continue
            hit = [g for g in PUBLIC_DROP_PATHS if fnmatch.fnmatch(sub, g)]
            if hit:
                log.append(("drop-path", sub, PUBLIC_DROP_PATHS[hit[0]]))
                continue
            if k in PUBLIC_BASENAME_KEYS:
                v = _basename(v)
                log.append(("basename", sub, PUBLIC_BASENAME_KEYS[k]))
            v2 = _sanitize(v, sub, log)
            if v2 is DIRTY:
                log.append(("drop-dirty", sub, ",".join(_dirty_of(v, sub))))
                continue
            out[k] = v2
        return out
    if isinstance(node, list):
        out_l = []
        for i, v in enumerate(node):
            v2 = _sanitize(v, "%s[%d]" % (where, i), log)
            if v2 is DIRTY:
                # A dirty element invalidates the whole list: a hole in a
                # text list would leave half sentences, a hole in a data
                # list would shift indices.
                return DIRTY
            out_l.append(v2)
        return out_l
    if isinstance(node, str):
        s = node if _verbatim(where) else _rename(node)
        return DIRTY if _dirty(s, where) else s
    return node


def _dirty_of(node, where: str) -> list:
    """Which patterns made the subtree dirty (for the log)."""
    ids: set = set()
    if isinstance(node, dict):
        for k, v in node.items():
            ids |= set(_dirty_of(v, "%s.%s" % (where, k)))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            ids |= set(_dirty_of(v, "%s[%d]" % (where, i)))
    elif isinstance(node, str):
        ids |= set(_dirty(_rename(node), where))
    return sorted(ids)


def _pick(d: dict, keys, where: str, log: list) -> dict:
    """Apply the allow-list and name every drop."""
    out = {}
    for k, v in d.items():
        if k in keys:
            out[k] = v
        else:
            log.append(("drop-structure", "%s.%s" % (where, k),
                        "not on any allow-list"))
    return out


def public_replay(rec: dict, log: list) -> dict:
    """Internal recording object -> public one (without provenance)."""
    _JSON_REDACT_HITS.clear()       # count afresh per export, otherwise the
    #                                 second run inherits the first run's hits
    pub = _pick(rec, PUBLIC_TOP_KEYS, "$", log)
    pub["meta"] = _pick(pub.get("meta", {}), PUBLIC_META_KEYS, "$.meta", log)
    pub["meta"]["public"] = True
    pub["shared"] = _pick(pub.get("shared", {}), PUBLIC_SHARED_KEYS,
                          "$.shared", log)
    scen = {}
    for sid, s in (pub.get("scenarios") or {}).items():
        s = _pick(s, PUBLIC_SCENARIO_KEYS, "$.scenarios.%s" % sid, log)
        s["endpoints"] = _pick(s.get("endpoints", {}), PUBLIC_ENDPOINTS,
                               "$.scenarios.%s.endpoints" % sid, log)
        scen[sid] = s
    pub["scenarios"] = scen
    pub = _sanitize(pub, "$", log)
    misses = [why for rx, _r, why in JSON_REDACTIONS
              if not _JSON_REDACT_HITS.get(rx.pattern)]
    for rx, _r, why in JSON_REDACTIONS:
        log.append(("json-redact", rx.pattern[:60],
                    "%dx -- %s" % (_JSON_REDACT_HITS.get(rx.pattern, 0), why)))
    if misses:
        raise SystemExit("PUBLIC_EXPORT_FAIL  %d replacement(s) without a hit "
                         "(the recording has changed):\n  - %s"
                         % (len(misses), "\n  - ".join(misses)))
    pub["provenance"] = {}
    return pub


def public_provenance(rec: dict, pub: dict, captured: str) -> dict:
    """The five permitted entries -- from the data, not from prose."""
    cores = []
    cat = (pub.get("shared") or {}).get("/api/scenarios") or {}
    for s in cat.get("scenarios") or []:
        names = ", ".join("%s (%s)" % (c.get("name"), c.get("isa"))
                          for c in s.get("cores") or [])
        mhz = sorted({c.get("mhz") for c in s.get("cores") or []
                      if c.get("mhz")})
        cores.append("%s: %s%s" % (s.get("id"), names,
                                   " @ %s MHz" % "/".join(str(m) for m in mhz)
                                   if mhz else ""))
    prov = {
        "captured": captured,
        "board": PUBLIC_BOARD,
        "cores": cores,
        "trace_protocol": PUBLIC_PROTOCOL,
        "scenarios": list((pub.get("meta") or {}).get("scenarios") or []),
        "bundle_sha256": "",
    }
    assert tuple(prov) == PUBLIC_PROVENANCE_FIELDS, "provenance allow-list"
    return prov


# ---- index.html: strip comments, replace references -----------------------

def _html_comment_spans(src: str, start: int, end: int):
    spans = []
    i = start
    while True:
        a = src.find("<!--", i)
        if a < 0 or a >= end:
            return spans
        b = src.find("-->", a + 4)
        b = end if b < 0 else b + 3
        spans.append((a, b))
        i = b


def _css_comment_spans(src: str, start: int, end: int):
    spans = []
    i = start
    while i < end:
        c = src[i]
        if c in "\"'":
            i = _skip_string(src, i, c)
            continue
        if c == "/" and i + 1 < end and src[i + 1] == "*":
            b = src.find("*/", i + 2)
            b = end if b < 0 else b + 2
            spans.append((i, b))
            i = b
            continue
        i += 1
    return spans


def _skip_string(src: str, i: int, q: str) -> int:
    i += 1
    while i < len(src):
        if src[i] == "\\":
            i += 2
            continue
        if src[i] == q:
            return i + 1
        i += 1
    return i


# After these characters (and keywords) a "/" starts a regular expression,
# not a division. The difference matters: mistake a regex literal for a
# division and the lexer reads a "'" inside it as the start of a string and
# loses the thread -- which really happened at `.replace(/'/g,"&#39;")` in
# index.html. The counter-check runs through node --check.
_RX_OK_PREV = set("(,=:[!&|?{};+-*%~^<>") | {""}
_RX_OK_WORD = {"return", "typeof", "case", "in", "of", "new", "delete",
               "void", "do", "else", "yield", "await", "instanceof"}


def _prev_word(src: str, i: int) -> str:
    j = i
    while j > 0 and src[j - 1].isspace():
        j -= 1
    k = j
    while k > 0 and (src[k - 1].isalnum() or src[k - 1] == "_"):
        k -= 1
    return src[k:j]


def _skip_regex(src: str, i: int, end: int) -> int:
    j = i + 1
    cls = False
    while j < end:
        if src[j] == "\\":
            j += 2
            continue
        if src[j] == "[":
            cls = True
        elif src[j] == "]":
            cls = False
        elif src[j] == "\n":
            break
        elif src[j] == "/" and not cls:
            return j + 1
        j += 1
    return j


def _js_template(src: str, i: int, end: int, spans: list) -> int:
    """Skip a template literal; `${...}` is normal code again."""
    i += 1
    while i < end:
        c = src[i]
        if c == "\\":
            i += 2
            continue
        if c == "`":
            return i + 1
        if c == "$" and i + 1 < end and src[i + 1] == "{":
            i = _js_scan(src, i + 2, end, spans, stop_brace=True)
            continue
        i += 1
    return i


def _js_scan(src: str, i: int, end: int, spans: list, stop_brace=False) -> int:
    """Read JS code, collect comment spans. One pass, one state."""
    prev = ""
    depth = 0
    while i < end:
        c = src[i]
        if c == "/" and i + 1 < end:
            d = src[i + 1]
            if d == "/":
                b = src.find("\n", i)
                b = end if b < 0 or b > end else b
                spans.append((i, b))
                i = b
                continue
            if d == "*":
                b = src.find("*/", i + 2)
                b = end if b < 0 else b + 2
                spans.append((i, b))
                i = b
                continue
            if prev in _RX_OK_PREV or _prev_word(src, i) in _RX_OK_WORD:
                i = _skip_regex(src, i, end)
                prev = "/"
                continue
            prev = "/"
            i += 1
            continue
        if c in "\"'":
            i = _skip_string(src, i, c)
            prev = c
            continue
        if c == "`":
            i = _js_template(src, i, end, spans)
            prev = "`"
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            if stop_brace and depth == 0:
                return i + 1
            depth -= 1
        if not c.isspace():
            prev = c
        i += 1
    return i


def _js_comment_spans(src: str, start: int, end: int):
    spans: list = []
    _js_scan(src, start, end, spans)
    return spans


def strip_comments(html: str):
    """Strip HTML, CSS and JS comments; the line count stays intact.

    A comment is replaced by its line breaks (or by a single space if it sat
    within one line) -- `a/*x*/b` must not glue into `ab`.
    """
    def _body(tag):
        a = html.find("<%s" % tag)
        if a < 0:
            return None
        a = html.find(">", a) + 1
        return a, html.find("</%s>" % tag, a)

    spans = []
    style = _body("style")
    script = _body("script")
    marks = sorted([m for m in (style, script) if m])
    plain = []
    cur = 0
    for a, b in marks:
        plain.append((cur, a))
        cur = b
    plain.append((cur, len(html)))
    for a, b in plain:
        spans += _html_comment_spans(html, a, b)
    if style:
        spans += _css_comment_spans(html, *style)
    if script:
        spans += _js_comment_spans(html, *script)
    spans.sort()
    out = []
    cur = 0
    for a, b in spans:
        assert html[a:a + 2] in ("//", "/*") or html[a:a + 4] == "<!--", \
            "no comment at %d: %r" % (a, html[a:a + 12])
        out.append(html[cur:a])
        nl = html.count("\n", a, b)
        out.append("\n" * nl if nl else " ")
        cur = b
    out.append(html[cur:])
    return "".join(out), spans


def _script_body(html: str) -> str:
    a = html.find("<script")
    if a < 0:
        return ""
    a = html.find(">", a) + 1
    return html[a:html.find("</script>", a)]


def _node_check(js: str):
    """Syntax counter-check for the comment strip -- '' = all good.

    The lexer decides what is a comment and what is a string or a regular
    expression. If it falls over, it eats code. node --check notices that;
    without node the probe is skipped (and says so).
    """
    import tempfile
    try:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "x.js"
            p.write_text(js, encoding="utf-8")
            r = subprocess.run(["node", "--check", str(p)],
                               capture_output=True, text=True)
            return "" if r.returncode == 0 else (r.stderr or "?").strip()[:400]
    except FileNotFoundError:
        return "SKIP node not available"


def public_index_html(html: str, log: list) -> str:
    out, spans = strip_comments(html)
    log.append(("html-comments", "index.html",
                "%d comments removed, %d -> %d bytes"
                % (len(spans), len(html), len(out))))
    before, after = _node_check(_script_body(html)), _node_check(_script_body(out))
    log.append(("node-check", "before/after",
                "%s / %s" % (before or "OK", after or "OK")))
    if before == "" and after not in ("", "SKIP node not available"):
        raise SystemExit("PUBLIC_EXPORT_FAIL  the comment strip damaged the "
                         "script: %s" % after)
    misses = []
    for rx, repl, why in HTML_REDACTIONS:
        out, n = rx.subn(repl, out)
        if not n:
            misses.append(why)
        log.append(("html-redact", rx.pattern[:60], "%dx -- %s" % (n, why)))
    if misses:
        raise SystemExit("PUBLIC_EXPORT_FAIL  %d replacement(s) without a hit "
                         "(index.html has changed):\n  - %s"
                         % (len(misses), "\n  - ".join(misses)))
    out = _rename(out)
    return out


# ---- checksum over the whole bundle ---------------------------------------

BUNDLE_RECIPE = ("sha256 over all bundle files, sorted by name, per "
                 "file: name + NUL + content + NUL; replay.json enters "
                 "with provenance.bundle_sha256 = \"\"")


def bundle_digest(files: dict) -> str:
    h = hashlib.sha256()
    for name in sorted(files):
        h.update(name.encode())
        h.update(b"\0")
        h.update(files[name])
        h.update(b"\0")
    return h.hexdigest()


def _dump(rec: dict) -> bytes:
    return json.dumps(rec, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def public_export(rec: dict, index_html: str, out: Path, captured: str,
                  log_path: Path) -> int:
    """Build the public bundle and write it ONLY if the scan comes back green."""
    import tempfile
    log: list = []
    pub = public_replay(rec, log)
    pub["provenance"] = public_provenance(rec, pub, captured)
    files = {"index.html": public_index_html(index_html, log).encode("utf-8")}
    files["replay.json"] = _dump(pub)
    digest = bundle_digest(files)
    pub["provenance"]["bundle_sha256"] = digest
    files["replay.json"] = _dump(pub)

    with tempfile.TemporaryDirectory() as td:
        stage = Path(td)
        for name, data in files.items():
            (stage / name).write_bytes(data)
        findings, used, _ = scanner.scan_bundle(stage)
        lines = ["# public export %s" % time.strftime("%Y-%m-%d %H:%M %z"),
                 "# target: %s" % out, ""]
        for kind, where, why in log:
            lines.append("%-16s %-58s %s" % (kind, where[:58], why))
        lines.append("")
        lines.append("bundle_sha256 = %s" % digest)
        lines.append("recipe        = %s" % BUNDLE_RECIPE)
        for name in sorted(files):
            lines.append("  %-14s %8d B" % (name, len(files[name])))
        lines.append("")
        for ex in scanner.EXEMPTIONS:
            lines.append("exemption %s %s -> %d hit(s) allowed: %s"
                         % (ex["id"], ex["where"], used.get(id(ex), 0),
                            ex["why"]))
        if findings:
            lines.append("")
            lines.append("PUBLIC_SCAN_FAIL  %d finding(s) -- NOTHING written"
                         % len(findings))
            for f in findings[:40]:
                lines.append("  %-12s %-11s %s" % (f.pid, f.file, f.where))
                lines.append("       %s" % f.text)
        else:
            lines.append("PUBLIC_SCAN_PASS  no internal markers")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("\n".join(lines[-12:]))
        print("export log: %s" % log_path)
        if findings:
            print("PUBLIC_EXPORT_FAIL  scan red -- output refused")
            return 1
        out.mkdir(parents=True, exist_ok=True)
        for name, data in files.items():
            (out / name).write_bytes(data)
    side = log_path.parent / (out.name + ".sha256")
    side.write_text("# %s\n%s  %s\n" % (BUNDLE_RECIPE, digest, out.name),
                    encoding="utf-8")
    print("PUBLIC_EXPORT_OK  %s  sha256=%s" % (out, digest))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--public", action="store_true",
                    help="public bundle (allow-list provenance, marker scan as "
                         "the gate) instead of the internal one")
    ap.add_argument("--from-bundle",
                    help="re-export an existing internal bundle instead of "
                         "recording anew (deterministic, without a board)")
    ap.add_argument("--captured",
                    help="capture date of the public provenance "
                         "(default: from the input bundle)")
    ap.add_argument("--log", help="path of the export log")
    args = ap.parse_args()
    out = Path(args.out)
    if args.from_bundle and not args.public:
        raise SystemExit("--from-bundle exists only together with --public")

    if args.from_bundle:
        src = Path(args.from_bundle)
        rec = json.loads((src / "replay.json").read_text(encoding="utf-8"))
        index_html = (src / "index.html").read_text(encoding="utf-8")
        captured = args.captured or (rec.get("provenance") or {}).get(
            "generated", "")[:10] or time.strftime("%Y-%m-%d")
    else:
        out.mkdir(parents=True, exist_ok=True)
        r = Recorder(out)
        for sc in SCENARIOS:
            r.record_scenario(sc)
        r.finish()
        if not args.public:
            return 0
        rec = r.rec
        index_html = (HERE / "index.html").read_text(encoding="utf-8")
        captured = args.captured or time.strftime("%Y-%m-%d")

    log_path = Path(args.log) if args.log else out.parent / (out.name + "_export.log")
    return public_export(rec, index_html, out, captured, log_path)


if __name__ == "__main__":
    raise SystemExit(main())
