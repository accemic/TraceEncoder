#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Nothing in the tree points a public reader at a place they cannot reach.

Written for the cross-repository audit of 2026-08-24, before the GitHub
release. The tree was clean of lab addresses (check_no_lab_internals.py) and
of German (check_language.py), and still an outsider following the README
would have hit, in this order: the private git host in both pin files, two
repository links that worked only because GitHub redirects a renamed
repository, the name of the internal predecessor repository in eight
board-script headers, and internal branch names in source comments. None of
it is a secret; all of it tells a reader "this was not written for you", and
one of them -- the host -- stops the tutorial at its first command.

What this guard checks, over every tracked text file (`git ls-files`; an
untracked file is not published, and a guard that read the working tree
would have passed its own first version -- see check_no_lab_internals.py):

  1. HOST     -- the private git host, its raw-asset path, and the Gitea-style
                 `Accemic/<Repo>` slug that only means something there.
  2. SLUG     -- retired GitHub repository names. They resolve today because
                 GitHub redirects a renamed repository; that redirect dies the
                 day somebody creates a repository under the old name.
  3. INTERNAL -- the predecessor repository and internal branch names.
  4. VERSION  -- the version is stated in five places; they must agree. The
                 demo-series version the tutorial quotes must be the one the
                 demo pin carries.
  5. LINKS    -- every relative link in the README-level documents resolves
                 (markdown `](path)`, AsciiDoc `link:`/`xref:`/`image::`).
                 check_tutorial_paths.py checks the backticked PATHS a reader
                 types; this is the other half, the links a reader clicks.

Until the 1.0.0 cutover an ALLOW_UNTIL_CUTOVER table tolerated the private
host on exactly the `base_url` line of each pin; the decoder pin now names
the public release host and the demo bundles are tracked in-repo, so the
table is gone and the private host is red everywhere. The test plants the
host in a pin AND in a README, so the guard is proven red in both places.

Deliberately NOT covered, so a reader can see the hole:

  * `examples/dashboard/demo/**` and `verification/**` -- recorded captures
    and evidence files: raw data with published checksums (the reasoning is in
    check_no_lab_internals.py).
  * `examples/dashboard/check_replay_public.py` and its test -- the patterns
    below ARE the detector there, and the internal names are its fixtures.
  * `<demo>/fpga/prebuilt/**` -- published bundle contents, extracted verbatim
    and verified against scripts/demo.pin and their own MANIFEST.sha256;
    editing a file there to fix a stale slug would break both proofs (the
    same trade-off check_language.py documents for the same trees). The
    v1.0.1-demo2 series froze the Gitea-style slug into four BOARD_SETUP.txt
    files; the live board scripts they refer to are covered.
  * this file and its test -- they name the strings they search for.
"""
import argparse
import pathlib
import re
import subprocess
import sys

SELF = "scripts/check_public_links.py"
SKIP_FILES = {
    SELF,
    "scripts/test_check_public_links.py",
    "examples/dashboard/check_replay_public.py",
    "examples/dashboard/test_replay_public.py",
}
SKIP_PREFIX = ("examples/dashboard/demo/", "verification/")
# Pin-verified verbatim bundle contents (see the docstring's NOT-covered list).
SKIP_PREBUILT_MARKER = "/fpga/prebuilt/"

# (regex, rule, what). Each pattern is here because it was found in the tree.
PATTERNS = [
    (re.compile(r"git\.cedartools\.com"), "HOST", "the private git host"),
    (re.compile(r"(?<![A-Za-z0-9_])raw/dist(?![A-Za-z0-9_])"), "HOST",
     "a raw-asset path of the private git host"),
    (re.compile(r"\bAccemic/(?:TraceEncoder|TraceDecoder|TraceEncoderDemos)\b"), "HOST",
     "a Gitea-style repository slug (use the public URL)"),
    (re.compile(r"github\.com/accemic/c-trace(?![A-Za-z0-9_-])", re.I), "SLUG",
     "the retired repository name of accemic/TraceEncoder"),
    (re.compile(r"NexRv-for-C-Trace", re.I), "SLUG",
     "the retired name of accemic/NexRv-for-TraceEncoder (superseded by accemic/CTTD)"),
    (re.compile(r"C-Trace-eXPort-format|c-trace-export-format", re.I), "SLUG",
     "the retired name of accemic/CTXP-format"),
    (re.compile(r"\bctrace_mbv\b"), "INTERNAL", "the internal predecessor repository"),
    (re.compile(r"\baweiss/[A-Za-z0-9._-]+"), "INTERNAL", "an internal branch name"),
]

# The five places the release version is stated, and how to read each.
VERSION_SOURCES = [
    ("VERSION", re.compile(r"^\s*(\d+\.\d+\.\d+)\s*$")),
    ("CITATION.cff", re.compile(r'^version:\s*"?(\d+\.\d+\.\d+)"?\s*$', re.M)),
    ("REUSE.toml", re.compile(r'^SPDX-PackageVersion\s*=\s*"(\d+\.\d+\.\d+)"', re.M)),
    ("README.md", re.compile(r"badge/version-(\d+\.\d+\.\d+)-")),
    ("doc/release-notes.adoc", re.compile(r"^== (\d+\.\d+\.\d+) \(", re.M)),
]
DEMO_PIN = "scripts/demo.pin"
DEMO_DOCS = ["examples/kv260/TUTORIAL_build_demos.md"]
DEMO_SERIES = re.compile(r"\bv\d+\.\d+\.\d+-demo\d+\b")

LINK_DOCS = [
    "README.md", "CONTRIBUTING.md", "LICENSE.md", "MAINTAINERS.md",
    "TRADEMARKS.md", "SECURITY.md", "bin/README.md",
    "examples/README.md", "examples/kv260/README.md",
    "examples/kv260/TUTORIAL_build_demos.md", "examples/dashboard/README.md",
    "doc/*.adoc", "doc/adapters/*.adoc",
]
MD_LINK = re.compile(r"\]\(([^)\s]+)\)")
ADOC_LINK = re.compile(r"(?:link|xref|image::?|include::):?([^\[\s]+)\[")


def tracked(root):
    out = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True,
                         text=True, check=True).stdout
    return [rel for rel in out.splitlines() if rel]


def scan_text(root, files):
    hits = []
    scanned = 0
    for rel in files:
        if rel in SKIP_FILES or rel.startswith(SKIP_PREFIX) \
                or SKIP_PREBUILT_MARKER in rel:
            continue
        try:
            text = (root / rel).read_text(encoding="utf-8", errors="strict")
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        for rx, rule, what in PATTERNS:
            for m in rx.finditer(text):
                line_no = text.count("\n", 0, m.start()) + 1
                hits.append((rel, line_no, rule, "%s (%s)" % (what, m.group(0))))
    return hits, scanned


def check_versions(root):
    hits = []
    seen = {}
    for rel, rx in VERSION_SOURCES:
        p = root / rel
        if not p.is_file():
            hits.append((rel, 0, "VERSION", "file missing -- the version is stated here"))
            continue
        m = rx.search(p.read_text(encoding="utf-8", errors="replace"))
        if not m:
            hits.append((rel, 0, "VERSION", "no version statement found where one is expected"))
            continue
        seen[rel] = m.group(1)
    if len(set(seen.values())) > 1:
        for rel, v in seen.items():
            hits.append((rel, 0, "VERSION", "says %s; the sources disagree: %s"
                         % (v, ", ".join("%s=%s" % kv for kv in sorted(seen.items())))))
    pin = root / DEMO_PIN
    series = None
    if pin.is_file():
        m = re.search(r"^version\s*=\s*(\S+)", pin.read_text(encoding="utf-8"), re.M)
        series = m.group(1) if m else None
    for rel in DEMO_DOCS:
        p = root / rel
        if not p.is_file() or series is None:
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        for m in DEMO_SERIES.finditer(text):
            if m.group(0) != series:
                line_no = text.count("\n", 0, m.start()) + 1
                hits.append((rel, line_no, "VERSION",
                             "quotes demo series %s but %s pins %s" % (m.group(0), DEMO_PIN, series)))
    return hits, len(seen)


def check_links(root, files):
    hits = []
    checked = 0
    tracked_set = set(files)
    docs = []
    for pat in LINK_DOCS:
        if "*" in pat:
            d, _, glob = pat.rpartition("/")
            docs += sorted(str(p.relative_to(root)).replace("\\", "/")
                           for p in (root / d).glob(glob)) if (root / d).is_dir() else []
        else:
            docs.append(pat)
    for rel in docs:
        if rel not in tracked_set:
            continue
        p = root / rel
        text = p.read_text(encoding="utf-8", errors="replace")
        rx = ADOC_LINK if rel.endswith(".adoc") else MD_LINK
        for m in rx.finditer(text):
            target = m.group(1).split("#", 1)[0]
            if not target or re.match(r"[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                continue
            checked += 1
            if not (p.parent / target).exists():
                line_no = text.count("\n", 0, m.start()) + 1
                hits.append((rel, line_no, "LINKS", "link target does not exist (%s)" % target))
    return hits, checked


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parent.parent),
                    help="repository root (default: this checkout; the test uses a fixture)")
    args = ap.parse_args(argv)
    root = pathlib.Path(args.root).resolve()
    files = tracked(root)
    hits, scanned = scan_text(root, files)
    vhits, nver = check_versions(root)
    lhits, nlinks = check_links(root, files)
    hits += vhits + lhits
    if hits:
        print("[check_public_links] %d finding(s) a public reader would trip over:" % len(hits))
        for rel, line_no, rule, what in hits:
            print("  %s:%d: %s: %s" % (rel, line_no, rule, what))
        return 1
    print("[check_public_links] OK: %d text file(s) name no private host, retired "
          "repository or internal branch; %d version statement(s) agree; %d link(s) resolve"
          % (scanned, nver, nlinks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
