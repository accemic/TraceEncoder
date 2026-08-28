#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Nothing in the tree names our lab.

The publication hygiene audit of 2026-08-19 found a working board password,
our lab IP and our jump host's name as defaults in six board scripts. They
were removed the same day (9f0a2708bb) -- but only in the ASSIGNMENTS. The
help texts kept naming the same IP as the default, so the tree still named
the lab, and worse, the help now LIED: there was no default any more, and a
reviewer following that line would call the script without --board and get
an error the documentation had promised them away.

That is why this is a guard and not a second cleanup. A one-off scrub finds
what someone thought to grep for, on the day they grepped; the next board
script starts from a copy of an old one.

Deliberately NOT covered, so a reader can see the hole:

  * `examples/dashboard/demo/**` -- recorded console output. The Linux
    version string of a kernel contains the machine it was built on
    (`aweiss@panama`), and those files are RAW DATA with published sha256
    sums and a reproduction recipe. Editing them would break the checksums
    and turn evidence into a retouched artefact, which costs more than the
    build host's name is worth.
  * THIS FILE. The patterns below have to contain the very strings they
    search for, so a guard that scanned itself could never be green. The
    exemption is one path, not a prefix, and it is worth knowing how it was
    found: the first version had no exemption and passed -- because it was
    not committed yet, and the scan reads `git ls-files`. It went red on the
    first run AFTER its own commit. A guard that cannot see itself is a
    guard that has not been tested.
"""
import re
import subprocess
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The lab. Each pattern is here because it was actually found in the tree.
PATTERNS = [
    (r"192\.168\.\d+\.\d+", "a private lab IP"),
    (r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b", "a MAC address"),
    (r"\bpanama\b", "the jump host's name"),
    # `${KV260_SUDO_PASS:-}` is the CORRECT form (empty fallback); only a
    # fallback with an actual value in it is a finding.
    (r"KV260_SUDO_PASS:-[^}\s]", "a non-empty fallback for the board password"),
    (r"SUDO_PASS=[\"']?[A-Za-z0-9]", "a board password in clear text"),
]

SKIP_PREFIX = ("examples/dashboard/demo/",)

# Exactly this file, not a prefix -- see the docstring.
SELF = "scripts/check_no_lab_internals.py"


def main() -> int:
    files = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.splitlines()
    hits = []
    scanned = 0
    for rel in files:
        if rel.startswith(SKIP_PREFIX) or rel == SELF:
            continue
        p = ROOT / rel
        try:
            text = p.read_text(encoding="utf-8", errors="strict")
        except (UnicodeDecodeError, OSError):
            continue  # binary or unreadable: nothing to read a hostname out of
        scanned += 1
        for pat, what in PATTERNS:
            for m in re.finditer(pat, text):
                line = text.count("\n", 0, m.start()) + 1
                hits.append((rel, line, what, m.group(0)))
    if hits:
        print(f"[check_no_lab_internals] {len(hits)} mention(s) of lab internals:")
        for rel, line, what, got in hits:
            print(f"  {rel}:{line}: {what} ({got})")
        return 1
    print(f"[check_no_lab_internals] OK: {scanned} text file(s), no lab internals")
    return 0


if __name__ == "__main__":
    sys.exit(main())
