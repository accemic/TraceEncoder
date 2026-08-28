#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Negative control for check_public_links.py: prove the guard can go red.

A guard that has only ever been green has not been tested (the lesson in
check_no_lab_internals.py). This builds a minimal, CONSISTENT fixture tree in
a temporary git repository, asserts the guard passes there, then plants one
violation per rule and asserts the guard fails naming that rule. Since the
1.0.0 cutover deleted the pin allow-list, the private host is proven red on
a pin's base_url line exactly like anywhere else.

Run: python3 scripts/test_check_public_links.py   (part of make check-publication)
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent

GUARD = HERE / "check_public_links.py"

FIXTURE = {
    "VERSION": "1.2.3\n",
    "CITATION.cff": 'cff-version: 1.2.0\ntitle: x\nversion: "1.2.3"\n',
    "REUSE.toml": 'version = 1\nSPDX-PackageVersion = "1.2.3"\n',
    "README.md": ("# x\n[![Version 1.2.3](https://img.shields.io/badge/version-1.2.3-blue.svg)]"
                  "(doc/release-notes.adoc)\nSee [LICENSE](LICENSE.md#top) and "
                  "[notes](doc/release-notes.adoc).\n"),
    "LICENSE.md": "# license\n",
    "doc/release-notes.adoc": "= notes\n\n== 1.2.3 (2026-01-01)\n\nlink:../README.md[readme]\n",
    "scripts/cttd.pin": "base_url = https://github.com/accemic/CTTD/releases/download\nversion = v1\n",
    "scripts/demo.pin": "version  = v9.9.9-demo1\n",
    "examples/kv260/TUTORIAL_build_demos.md": "pinned bundles (`v9.9.9-demo1`).\n",
}


def git(root, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
                   cwd=root, check=True, capture_output=True)


def build(root):
    for rel, text in FIXTURE.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "fixture")


def run(root):
    r = subprocess.run([sys.executable, str(GUARD), "--root", str(root)],
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def plant(root, rel, text):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    git(root, "add", "-A")


def main():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="check_public_links_"))
    failures = []
    try:
        build(tmp)
        rc, out = run(tmp)
        if rc != 0:
            failures.append("clean fixture must pass:\n" + out)

        host_on_pin = "base_url = https://git.cedartools.com/Accemic/TraceDecoder/raw/dist\nversion = v1\n"
        cases = [
            ("HOST", "notes/x.md", "see https://git.cedartools.com/Accemic/TraceEncoder\n"),
            ("HOST", "notes/x.md", "built from Accemic/TraceEncoder\n"),
            ("SLUG", "notes/x.md", "https://github.com/accemic/c-trace\n"),
            ("SLUG", "notes/x.md", "the NexRv-for-C-Trace fork\n"),
            ("SLUG", "notes/x.md", "https://github.com/accemic/C-Trace-eXPort-format\n"),
            ("INTERNAL", "notes/x.sh", "# ported from ctrace_mbv\n"),
            ("INTERNAL", "notes/x.sv", "// branch aweiss/some-branch\n"),
            ("VERSION", "VERSION", "1.2.4\n"),
            ("VERSION", "examples/kv260/TUTORIAL_build_demos.md", "pinned bundles (`v9.9.8-demo1`).\n"),
            ("LINKS", "README.md", "# x\n[![Version 1.2.3](https://img.shields.io/badge/version-1.2.3-blue.svg)](doc/release-notes.adoc)\n[gone](doc/missing.adoc)\n"),
            ("LINKS", "doc/release-notes.adoc", "= notes\n\n== 1.2.3 (2026-01-01)\n\nlink:../nowhere.md[x]\n"),
        ]
        for rule, rel, text in cases:
            original = (tmp / rel).read_text(encoding="utf-8") if (tmp / rel).exists() else None
            plant(tmp, rel, text)
            rc, out = run(tmp)
            if rc == 0 or (": %s: " % rule) not in out:
                failures.append("planted %s in %s must fail naming %s:\n%s" % (rule, rel, rule, out))
            if original is None:
                (tmp / rel).unlink()
            else:
                (tmp / rel).write_text(original, encoding="utf-8")
            git(tmp, "add", "-A")

        # The pin's base_url line has no allowance since the cutover: the
        # private host is red there exactly like anywhere else.
        plant(tmp, "scripts/cttd.pin", host_on_pin)
        rc, out = run(tmp)
        if rc == 0:
            failures.append("private host on a pin must fail since the cutover:\n" + out)
        plant(tmp, "scripts/cttd.pin", FIXTURE["scripts/cttd.pin"])

        rc, out = run(tmp)
        if rc != 0:
            failures.append("fixture must be clean again after the plants:\n" + out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("[test_check_public_links] FAIL: %d case(s)" % len(failures))
        for f in failures:
            print("  " + f.replace("\n", "\n    "))
        return 1
    print("[test_check_public_links] OK: guard proven red on %d planted violation(s), "
          "green on the clean fixture" % len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
