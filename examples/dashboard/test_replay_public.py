#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""U12 (offline): marker scanner + public export of the replay bundle.

Both halves of an actual proof are checked -- that the scanner FINDS the real
classes of finding from R2 finding A-05, and that it leaves the payload
RUHE laesst:

  * one real example per pattern from the shipped bundle (red),
  * the false-positive delimitation: device-tree nodes of the boot log
    (`mmode_resv1@64000000`), nackte Hex-Strings, CSS-Selektoren wie
    `table.f`, object accesses such as `pr.cmd` and the bundle's own sha256
    sum must NOT fire,
  * the single exemption (console recording) applies exactly there and
    nirgends sonst,
  * the provenance schema: exactly the five permitted entries, no sixth,
  * the interlock: one marker in the result -> the export writes NOTHING,
  * neutrality: numbers, list lengths and time series survive the export
    unchanged,
  * the comment strip on exactly those cases where a naive lexer fails
    (a regex with quotes, a template with `${}`, a string containing "/*").

Aufruf:  py test_replay_public.py
"""
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import check_replay_public as S           # noqa: E402
import record_web_replay as R             # noqa: E402

FAILS = []
NCHECK = 0


def check(name, cond, extra=""):
    global NCHECK
    NCHECK += 1
    if not cond:
        FAILS.append("%s%s" % (name, (" -- " + extra) if extra else ""))


def pids(s, where="$.x"):
    return sorted({f.pid for f in S.string_findings(s, "replay.json", where)})


# --------------------------------------------------------------------------
def t_patterns_hit():
    """Every class of finding from A-05 on a REAL example."""
    cases = [
        ("repo_path", "vivado/kv260_app/duo_pib_pmod.xdc"),
        ("repo_path", "Source: docs/SPEC_axis_wp_memory_map.md \u00a77."),
        ("host_path", "C:\\dev\\ctrace_mbv\\third_party\\C-Trace\\bin\\NexRv.exe"),
        ("host_path", "/home/devuser/git/ctrace/x"),
        ("git_commit", "ctrace_mbv@660d5b9495e8"),
        ("git_commit", "commit 660d5b9495e8"),
        ("git_commit", "b" * 40),
        ("review_marker", "Einkern-Szenario des Trio-Aufbaus (AW-Befund 2026-07-29)"),
        ("review_marker", "H3 Befund 7, AW 2026-08-13"),
        ("repo_name", "ctrace_mbv"),
        ("repo_name", "aweiss/ntrace-gold-standard"),
        ("src_ref", "register (RDL ct_cs_cpuif.rdl:1440-1493)"),
        ("src_ref", "trio_soc_top.sv:234"),
        ("host_tool", "NexRv.exe"),
        ("german_text", "Die Senke war schlicht nie an und wird nicht gemeldet"),
    ]
    for pid, s in cases:
        check("pattern %-14s finds %r" % (pid, s[:44]), pid in pids(s),
              "gefunden: %s" % pids(s))
    # The per-file hash table is a STRUCTURE, not a text pattern.
    f = []
    S.scan_json_value({"index.html": "a" * 64, "regmap.json": "b" * 64},
                      "replay.json", "$.provenance.files", f, {})
    check("the hash-per-file table is recognised as a structure",
          any(x.pid == "file_hash_map" for x in f),
          str([x.pid for x in f]))
    f = []
    S.scan_json_value({"ui_build": "f20d7a3c"}, "replay.json", "$.s", f, {})
    check("hex under a build key is a finding",
          any(x.pid == "git_commit" for x in f), str([x.pid for x in f]))


def t_no_false_positives():
    """Payload must NOT go red -- the delimitation in one test."""
    clean = [
        # Device-tree nodes from the real Linux boot log: they look like
        # repo@hash but are addresses. The most expensive false positive.
        "[    0.000000] OF: reserved mem: mmode_resv1@64000000 nomap",
        "riscv-plic: interrupt-controller@c000000: mapped 8 interrupts",
        # bare hex strings in the payload (PC values, packet dumps)
        "8000f0a4", "0x6400_0000", "deadbeef cafebabe 12345678",
        # CSS/JS from the user interface
        "table.f th{color:var(--dim)}", "+(pr.cmd?(' ('+pr.cmd+')'):'')",
        # englische Produkttexte
        "Maximum interval between sync messages (2^(trTeInstSyncMax+4)).",
        "1 MiB URAM buffer capturing the MERGED stream (primary sink).",
        "Two harts, two encoders, one merged stream",
        # the bundle's own checksum (64 hex digits) is allowed
        "9512bd8f13c2c326cb6b0bc0aadc499f1f80b6f15046c07002c1dce0826bb32d",
        # public decoder name, not a repository
        "Decode with NexRv", "NexRv -target 0/1 -src 2",
    ]
    for s in clean:
        check("no finding in %r" % s[:46], not pids(s), "found: %s" % pids(s))


def t_exemption_is_narrow():
    line = "Machine model: Accemic CVA6 C-Trace Demonstrator (KV260 PL)"
    check("the exemption applies in the console recording",
          not pids(line, "$.scenarios.cva6_linux.console.text"),
          str(pids(line, "$.scenarios.cva6_linux.console.text")))
    check("the same line elsewhere is a finding",
          "repo_name" in pids(line, "$.shared./api/scenarios.scenarios[0].title"))
    check("the exemption covers ONLY its own pattern",
          "host_path" in pids("C:\\dev\\x " + line,
                              "$.scenarios.cva6_linux.console.text"))


# --------------------------------------------------------------------------
def _bundle():
    """A small but complete internal bundle as test input."""
    return {
        "meta": {"default": "rocket2", "scenarios": ["rocket2"], "version": 2},
        "shared": {
            "/api/scenarios": {
                "active": "rocket2", "version": 3,
                "nexrv": {"path": "C:\\dev\\ctrace_mbv\\bin\\NexRv.exe",
                          "available": True},
                "scenarios": [{
                    "id": "rocket2", "title": "Rocket",
                    "headline": ["recorded as C-Trace: 12 instructions"],
                    "_ctrl_comment": ["Kopfkommentar von vivado/kv260_app/x.sv"],
                    "cores": [{"name": "Rocket hart 0", "isa": "RV64IMAC",
                               "mhz": 75,
                               "desc": "window (+64 MiB, ctrace_resmem.dtso)",
                               "mhz_note": "75 MHz (vivado/kv260_app/"
                                           "kv260_plclk.sh). WNS +3.466 ns."}],
                    "regions": {"ctrl": {"base_int": 0, "size": 16,
                                         "label": "C-Trace CSRs"}},
                }]},
            "/regmap.json": {"generated_from": "third_party/C-Trace/rdl/x.rdl",
                             "regs": [{"name": "trTeControl", "offset": 0,
                                       "desc": "clean", "path": "ct_cs.trTe"}]},
            "/themes.json": {"default": "forge", "themes": {}},
            "/block_csrs.json": {"_comment": ["AW 2026-08-13"], "blocks": {}},
            "/api/mode": {"mode": "demo"},
            "/api/geheim": {"x": 1},
        },
        "scenarios": {"rocket2": {
            "reset_state": {"control": 0, "trace_bytes": 0, "ui_build": "f20d7a3c"},
            "state_series": [{"trace_bytes": 100 + i, "bpi_win": 3.0,
                              "ui_build": "f20d7a3c"} for i in range(4)],
            "livepc_series": [{"t": 0, "decode": {
                "pcinfo": ["C:\\dev\\ctrace_mbv\\tools\\x.pcinfo"], "pcs": [1, 2]}}],
            "trace_series": [{"words": [1, 2, 3]}],
            "regions": {"ctrl": {"base": 0, "size": 16, "words": [0, 1, 2, 3]}},
            "run_response": {"ok": True}, "stop_response": {"ok": True},
            "endpoints": {"/api/boot": {"ok": True},
                          "/api/symbols": {"count": 2, "source":
                                           "C:\\dev\\x\\symbols.map"},
                          "/api/intern": {"y": 2}},
            "console": {"text": "Accemic CVA6 C-Trace Demonstrator\n",
                        "schedule": [[0, 0], [10, 33]],
                        "source": "console_rocket2.txt"},
            "_notiz": "interner Kram",
        }},
        "provenance": {"generated": "2026-08-15 12:22 +0200",
                       "generator": "tools/ctrace_dashboard/record_web_replay.py",
                       "source_repo": "ctrace_mbv@660d5b9495e8",
                       "files": {"index.html": "a" * 64}},
    }


HTML = """<!doctype html><html><head>
<!-- interner Hinweis: docs/SPEC_x.md -->
<style>/* deutscher Kommentar, AW-Befund 2026-07-29 */
body{content:"/* kein Kommentar */";color:red}</style></head>
<body><script>
/* Kopfkommentar mit ctrace_mbv und AW-Befund 2026-07-29 */
const a = 'ein String mit /* Sternchen */ darin';
const b = x.replace(/'/g, "&#39;");        // Zeilenkommentar, deutsch: nicht
const c = `Vorlage ${obj.f(1) / 2} und ${'inner'} Ende`;
function f(){ return /ab\\/cd/.test('x'); }
</script></body></html>"""


def t_public_export():
    rec = _bundle()
    log = []
    pub = R.public_replay(json.loads(json.dumps(rec)), log)
    prov = R.public_provenance(rec, pub, "2026-08-15")
    check("provenance has EXACTLY the permitted fields",
          tuple(prov) == R.PUBLIC_PROVENANCE_FIELDS, str(tuple(prov)))
    check("provenance names no file hashes and no repository",
          not pids(json.dumps(prov, ensure_ascii=False), "$.provenance"),
          str(pids(json.dumps(prov, ensure_ascii=False), "$.provenance")))
    check("provenance names cores taken from the data",
          any("Rocket hart 0" in c for c in prov["cores"]), str(prov["cores"]))

    flat = json.dumps(pub, ensure_ascii=False)
    check("ui_build is gone", "ui_build" not in flat)
    check("underscore keys are gone",
          "_ctrl_comment" not in flat and "_notiz" not in flat and
          "_comment" not in flat)
    check("generated_from is gone", "generated_from" not in flat)
    check("an endpoint outside the allow list is dropped",
          "/api/intern" not in flat and "/api/geheim" not in flat)
    check("the decoder path is gone, its availability stays",
          "NexRv.exe" not in flat
          and pub["shared"]["/api/scenarios"]["nexrv"] == {"available": True},
          str(pub["shared"]["/api/scenarios"].get("nexrv")))
    check("the workbench path is cut down to the file name",
          pub["scenarios"]["rocket2"]["endpoints"]["/api/symbols"]["source"]
          == "symbols.map",
          str(pub["scenarios"]["rocket2"]["endpoints"]["/api/symbols"]))
    core0 = pub["shared"]["/api/scenarios"]["scenarios"][0]["cores"][0]
    check("the replacement keeps the sentence and takes only the reference",
          core0.get("desc") == "window (+64 MiB, reserved via device tree)"
          and core0.get("mhz_note") == "75 MHz. WNS +3.466 ns.",
          json.dumps(core0, ensure_ascii=False))
    check("C-Trace is renamed in labels",
          pub["shared"]["/api/scenarios"]["scenarios"][0]["regions"]["ctrl"]
          ["label"] == "CTTE CSRs")
    check("Konsolen-Mitschnitt bleibt WOERTLICH",
          pub["scenarios"]["rocket2"]["console"]["text"]
          == rec["scenarios"]["rocket2"]["console"]["text"],
          pub["scenarios"]["rocket2"]["console"]["text"])
    check("Zeitreihen bleiben vollstaendig",
          len(pub["scenarios"]["rocket2"]["state_series"]) == 4
          and pub["scenarios"]["rocket2"]["state_series"][3]["trace_bytes"] == 103)
    check("Register-Speicherabbild bleibt",
          pub["scenarios"]["rocket2"]["regions"]["ctrl"]["words"] == [0, 1, 2, 3])
    check("Konsolen-Zeitplan bleibt",
          pub["scenarios"]["rocket2"]["console"]["schedule"] == [[0, 0], [10, 33]])

    # For the neutrality check the two DELIBERATELY injected foreign endpoints
    # are removed first -- they test the allow list (above) and are not
    # payload that would have to survive.
    ref = json.loads(json.dumps({k: v for k, v in rec.items()
                                 if k != "provenance"}))
    ref["shared"].pop("/api/geheim")
    ref["scenarios"]["rocket2"]["endpoints"].pop("/api/intern")
    d = S.compare_payload(ref,
                          {k: v for k, v in pub.items() if k != "provenance"})
    check("neutrality: no number changed", not d["numeric"], str(d["numeric"][:3]))
    check("neutrality: no list length changed", not d["length"],
          str(d["length"][:3]))
    check("neutrality: no payload removed",
          not [x for x in d["removed"] if x[1] == "DATEN"],
          str([x for x in d["removed"] if x[1] == "DATEN"][:3]))


def t_comment_strip():
    out, spans = R.strip_comments(HTML)
    check("Kommentare gefunden", len(spans) >= 4, str(len(spans)))
    check("deutscher Kommentar weg", "AW-Befund" not in out and "Kopfkommentar" not in out)
    check("HTML-Kommentar weg", "interner Hinweis" not in out)
    check("a string containing /* stays", "'ein String mit /* Sternchen */ darin'" in out)
    check("the CSS content string stays", '"/* kein Kommentar */"' in out)
    check("a regex with quotes is undamaged",
          "x.replace(/'/g, \"&#39;\")" in out)
    check("Template bleibt", "${obj.f(1) / 2}" in out and "${'inner'}" in out)
    check("a regex with a slash stays", "/ab\\/cd/.test('x')" in out)
    check("Zeilenzahl unveraendert (Diff bleibt lesbar)",
          out.count("\n") == HTML.count("\n"),
          "%d/%d" % (out.count("\n"), HTML.count("\n")))
    msg = R._node_check(R._script_body(out))
    check("node --check on the de-commented script",
          msg in ("", "SKIP node not available"), msg)


def t_export_refuses():
    """The interlock: one marker in the result and NOTHING gets written."""
    keep = R.HTML_REDACTIONS
    R.HTML_REDACTIONS = []
    try:
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "bundle"
            log = Path(td) / "x.log"
            bad = "<html><body>C:\\dev\\ctrace_mbv\\x</body></html>"
            rc = R.public_export(_bundle(), bad, out, "2026-08-15", log)
            check("the export reports FAIL", rc == 1, "rc=%s" % rc)
            check("the export wrote NOTHING", not out.exists())
            check("the export log names the reason",
                  "PUBLIC_SCAN_FAIL" in log.read_text(encoding="utf-8"))
            # Counter-check: without a marker the same path goes through.
            rc = R.public_export(_bundle(), "<html><body>ok</body></html>",
                                 out, "2026-08-15", log)
            check("counter-check: a clean bundle is written",
                  rc == 0 and (out / "replay.json").is_file(), "rc=%s" % rc)
            pub = json.loads((out / "replay.json").read_text(encoding="utf-8"))
            files = {p.name: p.read_bytes() for p in out.iterdir()}
            got = pub["provenance"]["bundle_sha256"]
            pub["provenance"]["bundle_sha256"] = ""
            files["replay.json"] = json.dumps(
                pub, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            check("the bundle checksum can be recomputed",
                  R.bundle_digest(files) == got,
                  "%s != %s" % (R.bundle_digest(files)[:16], got[:16]))
            check("the scan of the generated bundle is green",
                  not S.scan_bundle(out)[0],
                  str([f.pid for f in S.scan_bundle(out)[0]][:5]))
    finally:
        R.HTML_REDACTIONS = keep


def t_mutation():
    """Counter-check: an injected marker MUST make the scan go red."""
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        (d / "replay.json").write_text(json.dumps(
            {"meta": {"version": 2}, "scenarios": {}}), encoding="utf-8")
        check("a clean mini bundle is green", not S.scan_bundle(d)[0])
        for marker in ("ctrace_mbv@660d5b9495e8",
                       "vivado/kv260_app/duo_pib_pmod.xdc",
                       "AW-Befund 2026-07-29",
                       "ct_cs_cpuif.rdl:1440-1493",
                       "C:\\dev\\ctrace_mbv"):
            (d / "replay.json").write_text(json.dumps(
                {"meta": {"version": 2}, "note": marker}), encoding="utf-8")
            check("Mutation rot: %s" % marker[:34], bool(S.scan_bundle(d)[0]))


def main() -> int:
    for t in (t_patterns_hit, t_no_false_positives, t_exemption_is_narrow,
              t_public_export, t_comment_strip, t_export_refuses, t_mutation):
        t()
    print()
    if FAILS:
        print("U12_PUBLIC_FAIL  %d/%d rot:" % (len(FAILS), NCHECK))
        for f in FAILS:
            print("  - " + f)
        return 1
    print("U12_PUBLIC_ALL_PASS  (%d checks)" % NCHECK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
