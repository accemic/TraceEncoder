#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Every xsim call goes through ct_xsim -- drift guard for the R4 class.

xsim does not report a failed run through its exit code. A snapshot the
running simulator cannot start (wrong Vivado, missing DLL, no licence)
writes

    ERROR: [Simtcl 6-50] Simulation engine failed to start: ...

into its LOG and exits 0. A script that then copies `${tb}.atb.bin`
promotes the PREVIOUS leg's dump, and the comparison downstream reports a
byte difference that is really a stale file. That is what happened on
2026-08-05 (P7 finding R4): a red byte-neutrality gate, half a day of
hypotheses, and the actual cause was a foreign Vivado on PATH.

The repair back then was local -- one script. The P7 audit (finding B-2)
counted the other callers: not one of them checked the exit code OR the
log, including the two gate scripts P7 had just written. So the check
moved into scripts/ct_env.sh (`ct_xsim`, `ct_xsim_ok`) and this guard
keeps it there: a new `xsim` invocation that bypasses the helper is a
failure, named with file and line.

Exit 0 = every caller uses the helper, 1 = at least one does not.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SEARCH_DIRS = ("scripts", "ci", "tools")

# The helper itself is the one place a bare xsim may be spelled out.
ALLOWED = {"scripts/ct_env.sh"}

# `xsim` as a COMMAND: at the start of a line or after a shell separator,
# and not part of ct_xsim / xsim.dir / xsim.log.
CALL_RE = re.compile(r"(?:^|[;&|(){}]|&&|\|\|)\s*(xsim(?:\.exe)?)\s+")


def code_only(line: str) -> str:
    """Drop a trailing shell comment and blank out quoted contents.

    Both are needed: a comment may quote a bare `xsim ...` as an example,
    and a message string may talk ABOUT xsim ("xsim did not run"). Only a
    command outside quotes is a real call. Quoted spans are replaced by
    dots, which are neither a shell separator nor part of the word, so an
    actual `xsim "$@"` stays visible.
    """
    out, quote = [], None
    for i, ch in enumerate(line):
        if quote:
            out.append("." if ch != quote else ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out)


def main() -> int:
    failures = []
    users = 0
    for d in SEARCH_DIRS:
        base = REPO / d
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.sh")):
            rel = path.relative_to(REPO).as_posix()
            text = path.read_text(encoding="utf-8", errors="replace")
            if rel in ALLOWED:
                continue
            uses_helper = "ct_xsim" in text
            if uses_helper:
                users += 1
                if "ct_env.sh" not in text:
                    failures.append(
                        f"  [FAIL] {rel}: calls ct_xsim but never sources "
                        f"scripts/ct_env.sh -- the helper would not exist")
            for lineno, line in enumerate(text.splitlines(), start=1):
                code = code_only(line)
                for m in CALL_RE.finditer(code):
                    failures.append(
                        f"  [FAIL] {rel}:{lineno}: bare `{m.group(1)}` call -- "
                        f"use `ct_xsim <log> <args...>` (scripts/ct_env.sh). A "
                        f"bare xsim reports a failed start only in its log and "
                        f"exits 0, so the next `cp` promotes the previous leg's "
                        f"dump (P7 finding R4 / audit B-2).")
    if failures:
        print("\n".join(failures))
        print(f"[check_xsim_guard] {len(failures)} failure(s)")
        return 1
    print(f"[check_xsim_guard] OK: {users} script(s) drive xsim, all through "
          f"ct_xsim/ct_xsim_ok; no bare xsim call outside "
          f"{', '.join(sorted(ALLOWED))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
