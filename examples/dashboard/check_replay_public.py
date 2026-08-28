#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""U12: marker scan for the PUBLIC replay bundle (R2 finding A-05).

The bundle under `assets/ctte-demo/dashboard/` goes public with the CTTE
release. An external review found internals in it: commit ids
(`ctrace_mbv@660d5b94...`), internal source paths
(`vivado/kv260_app/duo_pib_pmod.xdc`), RDL line references
(`ct_cs_cpuif.rdl:1440-1493`), review markers ("AW-Befund 2026-07-29") and
per-file hashes of internal paths.

This script is the EVIDENCE, not the claim: it reads a finished bundle
(directory or single file) and reports every hit with its file, location
(JSON path or line), pattern id and the text found. One hit is a FAIL
(exit 1) -- `record_web_replay.py --public` runs the scan itself and refuses
to emit the output if it is red.

    py check_replay_public.py <bundle-directory>
    py check_replay_public.py <file> --json report.json

The patterns sit as a maintainable list in PATTERNS, each with a comment
saying WHY it is a marker and WHERE it actually occurred. The (few)
exemptions sit just as visibly in EXEMPTIONS and are ALWAYS printed with the
report -- a silent exemption would be worse than the finding.

Delimiting false positives (U12 point 5): payload data contain masses of
legitimate hex strings (PC values, packet dumps, symbol addresses). The
commit pattern therefore only fires in context -- `repo@<hex>`, a keyword
(commit/sha/rev/build/git) immediately in front of it, or a JSON key whose
name announces a build/commit id. A bare hex string in the payload is not a
finding (test: test_replay_public.py).
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Patterns. Order = reporting order; one sentence of WHY per pattern.
# --------------------------------------------------------------------------
PATTERNS: list[dict] = [
    {
        "id": "repo_path",
        # Paths into the work tree. A-05 named vivado/kv260_app/duo_pib_pmod.xdc;
        # the bundle also carried docs/SPEC_*, rtl/*, third_party/*, tools/*.
        "why": "path into the internal source tree",
        "rx": re.compile(
            r"(?<![A-Za-z0-9_./\\-])"
            r"(?:rtl|sim|vivado|third_party|docs|doc|tools|bld|sw|scripts|asic|test)"
            r"/[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_.-]+)*"),
    },
    {
        "id": "host_path",
        # Absolute path of the development machine (C:\dev\ctrace_mbv\...,
        # /home/..., /mnt/d/...). Gives away user, drive and tree structure.
        "why": "absolute path of a development machine",
        "rx": re.compile(
            r"(?:\b[A-Za-z]:[\\/]{1,2}[A-Za-z0-9_.$-]"
            r"|/home/[a-z][a-z0-9_-]*/"
            r"|/mnt/[a-z]/[A-Za-z0-9_.-])"),
    },
    {
        "id": "git_commit",
        # Commit id IN CONTEXT. Three forms, all with context:
        #   1. <known repo>@<hex>   -- the finding from A-05
        #   2. a keyword in front of it (commit/sha/rev/git/build)
        #   3. a full 40-digit SHA-1 as a word of its own
        # Deliberately NOT every "<word>@<hex>": the Linux boot log carries
        # device-tree nodes such as "mmode_resv1@64000000" and
        # "interrupt-controller@c000000". Those are the payload of a
        # recording, not commits (false positive, measured on the existing
        # bundle; counter-check in test_replay_public.py).
        "why": "commit/build id",
        "rx": re.compile(
            r"(?:(?:ctrace_mbv|C-Trace|CTTE|TraceEncoder|CEDARtools[A-Za-z.]*"
            r"|nexrv-for-c-trace|[A-Za-z0-9_-]+_mvp)@[0-9a-f]{7,40}\b"
            r"|(?:commit|sha1?|revision|rev|git|build)"
            r"[\s:=#-]{1,3}[0-9a-f]{7,40}\b"
            r"|(?<![0-9a-zA-Z])[0-9a-f]{40}(?![0-9a-zA-Z]))", re.I),
    },
    {
        "id": "review_marker",
        # Internal review/working markers. A-05 named "AW-Befund 2026-07-29";
        # the same class covers AW-Regel/-Auftrag, finding numbers and the
        # names of the internal working documents.
        "why": "internal review/working marker",
        "rx": re.compile(
            r"(?:\bAW[\s-]*(?:Befund|Regel|Auftrag|Direktive|Freigabe|Wunsch)"
            r"|\bAW\s+\d{4}-\d{2}-\d{2}"
            r"|\bBefund\s+\d"
            r"|\b(?:FINDINGS|HANDOVER|TASK_STATE|PLAN|REPORT|PROMPT|SPEC)_[A-Za-z0-9_]+"
            r"|\bTODO\b|\bFIXME\b|\bXXX\b)"),
    },
    {
        "id": "repo_name",
        # Repository, branch and pre-rename names. "C-Trace" is the old short
        # name of today's CEDARtools.TraceEncoder and does not belong in a
        # release artefact carrying the new name.
        "why": "repository/branch/legacy name",
        "rx": re.compile(
            r"(?:ctrace_mbv|aweiss/|gold-standard|nexrv-for-c-trace"
            r"|\bC-Trace\b|git\.cedartools\.com)", re.I),
        # Deliberately NOT included: the plain decoder name "NexRv". It appears
        # in the user interface ("Decode with NexRv") and denotes the public
        # N-Trace reference decoder, not an internal repository. The binary
        # on the workbench is still caught by host_tool (.exe).
    },
    {
        "id": "src_ref",
        # Reference to a source file (often with a line number): RDL, RTL, XDC,
        # TCL, device-tree overlay, internal .md/.py. A-05:
        # ct_cs_cpuif.rdl:1440-1493. No ".f" and no ".bd" in the list -- they
        # hit CSS selectors such as "table.f" (false positive, measured on the
        # existing bundle).
        "why": "reference to a source/spec file",
        "rx": re.compile(
            r"\b[A-Za-z0-9_][A-Za-z0-9_.-]*"
            r"\.(?:rdl|sv|svh|vhd|vhdl|xdc|tcl|dtso|dts|ys|py|md)"
            r"\b(?::\d+)?"),
    },
    {
        "id": "host_tool",
        # Executable tools of the Windows development environment. The target
        # system of the demo is Linux -- an .exe/.ps1/.bat in the bundle always
        # comes from the workbench, never from the recording.
        # No ".cmd" in the list: that hit the object access "pr.cmd" in the
        # JS of the user interface (false positive, measured on the existing
        # bundle).
        "why": "tool of the development environment",
        "rx": re.compile(r"\b[A-Za-z0-9_-]+\.(?:exe|ps1|bat|vcxproj|sln)\b"),
    },
    {
        "id": "german_text",
        # Publicly visible texts are English (U12 point 1). These words do not
        # occur in English text, in C symbol names or in the Linux boot log
        # -- a hit is leftover German text. The word list below is the
        # DETECTOR and stays German on purpose.
        "why": "leftover German text in an English bundle",
        "rx": re.compile(
            r"\b(?:und|nicht|werden|wird|eine|einen|einem|einer|nach|ueber"
            r"|damit|deshalb|keine|kein|beim|dass|weil|wenn|dann|sind|haben"
            r"|dieser|diese|dieses|schon|jeder|jede|jedes|zwei|drei|gegen"
            r"|ohne|durch|sich|auch|aber|oder|nur noch|steht|liegt|gibt)\b"),
    },
]

# --------------------------------------------------------------------------
# Exemptions. Each line: file glob, location glob, pattern id, reason.
# The report prints every applied exemption WITH its hit count -- an
# exemption nobody sees is a gap.
# --------------------------------------------------------------------------
EXEMPTIONS: list[dict] = [
    {
        "file": "replay.json",
        "where": "$.scenarios.*.console.text",
        "id": "repo_name",
        "why": "verbatim OpenSBI/Linux capture of the demonstrator: "
               "'Accemic CVA6 C-Trace Demonstrator' is the device-tree "
               "model string of the recorded system. Editing the capture "
               "would mean falsifying a measurement.",
    },
]

TEXT_SUFFIXES = {".html", ".htm", ".js", ".css", ".txt", ".md", ".csv", ".svg"}
JSON_SUFFIXES = {".json"}
SKIP_SUFFIXES = {".bin", ".png", ".jpg", ".jpeg", ".gz", ".woff", ".woff2",
                 ".ico", ".webp", ".mp4"}

# JSON keys whose value ANNOUNCES a build/commit id. A bare hex string under
# such a key is a finding even without
# Kontextwort im Text selbst (real: "ui_build": "f20d7a3c").
HASHY_KEYS = re.compile(
    r"^(?:ui_build|build|commit|sha|sha1|sha256|rev|revision|git|"
    r"source_repo|version_hash|md5)$", re.I)
HEX_ONLY = re.compile(r"^[0-9a-f]{7,64}$")

# Structure "file name -> hash": exactly the per-file hash table from A-05.
FILEISH = re.compile(r"^[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,6}$")


class Finding:
    __slots__ = ("file", "where", "pid", "why", "text")

    def __init__(self, file: str, where: str, pid: str, why: str, text: str):
        self.file, self.where, self.pid = file, where, pid
        self.why, self.text = why, text

    def as_dict(self) -> dict:
        return {"file": self.file, "where": self.where, "pattern": self.pid,
                "why": self.why, "text": self.text}


def _exempt(file: str, where: str, pid: str):
    for ex in EXEMPTIONS:
        if (ex["id"] == pid and fnmatch.fnmatch(file, ex["file"])
                and fnmatch.fnmatch(where, ex["where"])):
            return ex
    return None


def string_findings(s: str, file: str, where: str, used: dict | None = None):
    """All patterns against ONE string -> list of findings (exemptions removed).

    The public export uses exactly this function too, so that sanitising and
    checking can never drift apart.
    """
    out: list[Finding] = []
    for pat in PATTERNS:
        for m in pat["rx"].finditer(s):
            ex = _exempt(file, where, pat["id"])
            if ex is not None:
                if used is not None:
                    used[id(ex)] = used.get(id(ex), 0) + 1
                continue
            start = max(0, m.start() - 30)
            ctx = s[start:m.end() + 30].replace("\n", " ")
            out.append(Finding(file, where, pat["id"], pat["why"],
                               "%s   [...%s...]" % (m.group(0)[:80], ctx[:110])))
    return out


def scan_text(s: str, file: str, where: str, findings, used):
    """All patterns against one string; collect hits or book an exemption."""
    findings.extend(string_findings(s, file, where, used))


def scan_json_value(o, file: str, where: str, findings, used):
    if isinstance(o, dict):
        # per-File-Hash-Tabelle (A-05: provenance.files)
        if o and all(isinstance(k, str) and FILEISH.match(k) for k in o) \
                and all(isinstance(v, str) and HEX_ONLY.match(v) for v in o.values()):
            findings.append(Finding(file, where, "file_hash_map",
                                    "hash table per internal file",
                                    "%d Eintraege: %s" % (len(o), ", ".join(list(o)[:4]))))
        for k, v in o.items():
            sub = "%s.%s" % (where, k)
            scan_text(str(k), file, sub, findings, used)
            if isinstance(v, str) and HASHY_KEYS.match(str(k)) and HEX_ONLY.match(v):
                findings.append(Finding(file, sub, "git_commit",
                                        "Commit-/Build-Kennung (Schluesselname)",
                                        "%s = %s" % (k, v)))
            scan_json_value(v, file, sub, findings, used)
    elif isinstance(o, list):
        for i, v in enumerate(o):
            scan_json_value(v, file, "%s[%d]" % (where, i), findings, used)
    elif isinstance(o, str):
        scan_text(o, file, where, findings, used)


def scan_file(p: Path, root: Path, findings, used):
    rel = p.name if p.parent == root else str(p.relative_to(root)).replace("\\", "/")
    if p.suffix.lower() in SKIP_SUFFIXES:
        return
    if p.suffix.lower() in JSON_SUFFIXES:
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:                       # noqa: BLE001
            findings.append(Finding(rel, "$", "unreadable",
                                    "file not readable", str(e)))
            return
        scan_json_value(doc, rel, "$", findings, used)
        return
    if p.suffix.lower() not in TEXT_SUFFIXES:
        return
    text = p.read_text(encoding="utf-8", errors="replace")
    for n, line in enumerate(text.split("\n"), 1):
        scan_text(line, rel, "line %d" % n, findings, used)


def scan_bundle(target: Path):
    """-> (findings, used_exemptions, gescannte Dateien)"""
    findings: list[Finding] = []
    used: dict[int, int] = {}
    files: list[Path] = []
    if target.is_dir():
        files = sorted(q for q in target.rglob("*") if q.is_file())
        root = target
    else:
        files = [target]
        root = target.parent
    for q in files:
        scan_file(q, root, findings, used)
    return findings, used, files


# --------------------------------------------------------------------------
# Neutrality probe: hold the public bundle against the internal one. The
# replay must NOT change -- so the sanitising must not have touched numbers,
# list lengths or time series. Allowed are exclusively: removed strings (or
# string containers) and rewritten strings. If a number comes out different
# or a list gets shorter, the replay is no longer the same.
# --------------------------------------------------------------------------
_MISSING = object()


def _stringy(o) -> bool:
    """Strings/null only (also inside lists/dicts) -- so no payload."""
    if isinstance(o, str) or o is None:
        return True
    if isinstance(o, list):
        return all(_stringy(x) for x in o)
    if isinstance(o, dict):
        return all(_stringy(v) for v in o.values())
    return False


def compare_payload(old, new, where="$", diffs=None):
    if diffs is None:
        diffs = {"removed": [], "added": [], "changed": [],
                 "numeric": [], "length": []}
    if isinstance(old, dict) and isinstance(new, dict):
        for k in old:
            if k not in new:
                diffs["removed"].append((where + "." + str(k),
                                         "string" if _stringy(old[k]) else "DATEN"))
            else:
                compare_payload(old[k], new[k], where + "." + str(k), diffs)
        for k in new:
            if k not in old:
                diffs["added"].append(where + "." + str(k))
        return diffs
    if isinstance(old, list) and isinstance(new, list):
        if len(old) != len(new):
            diffs["length"].append((where, len(old), len(new)))
            return diffs
        for i, (a, b) in enumerate(zip(old, new)):
            compare_payload(a, b, "%s[%d]" % (where, i), diffs)
        return diffs
    if old == new and type(old) is type(new):
        return diffs
    if isinstance(old, str) and isinstance(new, str):
        diffs["changed"].append((where, old[:70], new[:70]))
    else:
        diffs["numeric"].append((where, repr(old)[:40], repr(new)[:40]))
    return diffs


def neutrality(internal: Path, public: Path, maxlist=25) -> int:
    old = json.loads((internal / "replay.json").read_text(encoding="utf-8"))
    new = json.loads((public / "replay.json").read_text(encoding="utf-8"))
    # provenance is deliberately rebuilt -- it is not payload.
    old.pop("provenance", None)
    new.pop("provenance", None)
    d = compare_payload(old, new)
    hard = [x for x in d["removed"] if x[1] == "DATEN"]
    print("Neutralitaets-Probe  intern=%s  oeffentlich=%s" % (internal, public))
    print("  entfernte Strings/String-Behaelter : %d" % (len(d["removed"]) - len(hard)))
    print("  entfernte NUTZDATEN                : %d" % len(hard))
    print("  neue Schluessel                    : %d  %s"
          % (len(d["added"]), ", ".join(d["added"][:6])))
    print("  umgeschriebene Strings             : %d" % len(d["changed"]))
    print("  geaenderte Zahlen/Typen            : %d" % len(d["numeric"]))
    print("  geaenderte Listenlaengen           : %d" % len(d["length"]))
    for w, a, b in d["changed"][:maxlist]:
        print("    ~ %s\n        alt: %s\n        neu: %s" % (w, a, b))
    if len(d["changed"]) > maxlist:
        print("    ... %d more" % (len(d["changed"]) - maxlist))
    for w, t in hard[:maxlist]:
        print("    - %s (%s)" % (w, t))
    for w, a, b in d["numeric"][:maxlist]:
        print("    ! %s  %s -> %s" % (w, a, b))
    for w, a, b in d["length"][:maxlist]:
        print("    ! %s  length %d -> %d" % (w, a, b))
    ok = not hard and not d["numeric"] and not d["length"]
    print("\nPAYLOAD_NEUTRAL_%s  no number, no list length, no payload "
          "value changed" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help="bundle directory or single file")
    ap.add_argument("--json", help="additionally write the report as JSON")
    ap.add_argument("--max", type=int, default=60,
                    help="print at most this many findings (default 60)")
    ap.add_argument("--against",
                    help="internal bundle: additionally run the payload "
                         "neutrality probe")
    args = ap.parse_args()
    if args.against:
        rc = neutrality(Path(args.against), Path(args.target))
        print()
        if rc:
            return rc
    target = Path(args.target)
    if not target.exists():
        print("PUBLIC_SCAN_ERROR  does not exist: %s" % target)
        return 2

    findings, used, files = scan_bundle(target)

    print("Bundle : %s" % target)
    print("files  : %d (%s)" % (len(files), ", ".join(p.name for p in files[:8])))
    for ex in EXEMPTIONS:
        n = used.get(id(ex), 0)
        print("exemption: %-12s %-32s %s -> %d hit(s) allowed"
              % (ex["id"], ex["where"], ex["file"], n))
        print("           reason: %s" % ex["why"])

    by_pat: dict[str, int] = {}
    for f in findings:
        by_pat[f.pid] = by_pat.get(f.pid, 0) + 1

    if args.json:
        Path(args.json).write_text(json.dumps(
            {"target": str(target), "files": [p.name for p in files],
             "counts": by_pat, "findings": [f.as_dict() for f in findings]},
            indent=1, ensure_ascii=False), encoding="utf-8")

    if not findings:
        print("\nPUBLIC_SCAN_PASS  no internal markers (%d patterns checked)"
              % len(PATTERNS))
        return 0

    print("\nfinding classes:")
    for pid, n in sorted(by_pat.items(), key=lambda kv: -kv[1]):
        print("  %-14s %4d" % (pid, n))
    print("\nfindings (max %d):" % args.max)
    for f in findings[:args.max]:
        print("  %-12s %-11s %s" % (f.pid, f.file, f.where))
        print("       %s" % f.text)
    if len(findings) > args.max:
        print("  ... %d more" % (len(findings) - args.max))
    print("\nPUBLIC_SCAN_FAIL  %d findings in %d classes"
          % (len(findings), len(by_pat)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
