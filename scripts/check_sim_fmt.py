#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""A format string handed to $display/$sformatf/... must be a LITERAL.

Why this is a gate and not a style rule
---------------------------------------
`$sformatf(FMT, a)` with FMT a parameter/variable is legal SystemVerilog and
XSIM substitutes it. Verilator 5.040 -- the backend pinned in `.abc.config`,
i.e. the one `make sim` runs -- does NOT: it emits the format string itself
and appends the arguments in default formatting.

That is not a cosmetic difference when the string ends up in a REFERENCE
file. `tests/lib/cpu_model.sv` built every expected PC through

    localparam string PC_HEX_FMT = ... ? "0x%016x" : "0x%08x";
    function automatic string pc_hex(...); return $sformatf(PC_HEX_FMT, a);

so on the default backend `expected.pcs`, the NexRv PCInfo and
`expected.data` all began with the eleven characters `0x%08x` followed by a
decimal number. Every `--pc` gate on that backend was comparing against
garbage, and the decoder could not parse the PCInfo it was handed either
(measured 2026-08-09, D1-F2: `tests/instruction/01_basic` decoded 1 of 26
PCs; the same testbench under XSIM matched 26 of 26).

A defect that only shows up on one of two simulators, in the file the test
compares AGAINST, is exactly the class that survives a green suite. This
guard keeps it out of the tree; `scripts/decode_and_check.sh` catches a
garbage oracle from any other cause at run time.

Scope: `rtl/` and `tests/` (the simulator-visible sources of this repo).
Vendored trees under `third_party/` and the generated `bld/` are skipped.

Exit 0 = every format argument is a literal (or an explicitly waived,
counted exception), 1 = at least one is not.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SEARCH_DIRS = ("rtl", "tests")
SKIP_PARTS = {"bld", "third_party", ".git", "coverage_html"}

# System tasks that take a format string, and WHICH argument it is.
#   $display("...", a)          -> index 0
#   $fwrite(fd, "...", a)       -> index 1   (file descriptor first)
#   $sformat(str, "...", a)     -> index 1   (output string first)
#   $fatal(1, "...", a)         -> index 1   (finish number first)
FMT_ARG_INDEX = {
    "display": 0, "displayb": 0, "displayo": 0, "displayh": 0,
    "write": 0, "writeb": 0, "writeo": 0, "writeh": 0,
    "sformatf": 0,
    "info": 0, "warning": 0, "error": 0,
    "monitor": 0, "strobe": 0,
    "fdisplay": 1, "fdisplayb": 1, "fdisplayo": 1, "fdisplayh": 1,
    "fwrite": 1, "fwriteb": 1, "fwriteo": 1, "fwriteh": 1,
    "fmonitor": 1, "fstrobe": 1,
    "sformat": 1, "swrite": 1, "swriteb": 1, "swriteo": 1, "swriteh": 1,
    "fatal": 1,
}

CALL_RE = re.compile(r"\$([a-z]+)\s*\(")

# Waived, WITH a reason and a count. A new occurrence in the same file still
# turns the guard red -- a waiver is a statement about known lines, not a
# licence for the file.
#   relative path -> (expected number of occurrences, reason)
WAIVERS = {
    "rtl/external/testtools/tt.sv": (
        2,
        "third-party test library, and the two sites (tt_assert_eq_int / "
        "tt_assert_gte_int) build only the DIAGNOSTIC text of an assertion "
        "that has already failed -- the pass/fail verdict and the "
        "failed_assertions counter are unaffected, so a garbled message "
        "cannot turn a red run green. Reported as V1-F1; fixing it means "
        "touching vendored external RTL and belongs in its own change."
    ),
}


def strip_comments(text: str) -> str:
    """Blank out comments and the CONTENTS of string literals.

    String contents are blanked (the quotes stay) so that a `%` or a `(`
    inside a message cannot be mistaken for code, while `"` still marks the
    argument as a literal for the check below.
    """
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out.append('"')
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    out.append(" ")
                    i += 1
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append('"')
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            i = min(i + 2, n)
            continue
        out.append(c)
        i += 1
    return "".join(out)


def split_args(text: str, start: int):
    """Split the argument list that opens at text[start] == '('.

    Returns (list_of_arg_strings, index_after_closing_paren) or (None, start)
    when the list is unterminated.
    """
    depth = 0
    args, cur = [], []
    i = start
    while i < len(text):
        c = text[i]
        if c in "([{":
            depth += 1
            if depth == 1:
                i += 1
                continue
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append("".join(cur))
                return args, i + 1
        if depth == 1 and c == ",":
            args.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    return None, start


def scan(path: Path):
    """Yield (lineno, task, argtext) for every non-literal format argument."""
    raw = path.read_text(encoding="utf-8", errors="replace")
    code = strip_comments(raw)
    for m in CALL_RE.finditer(code):
        task = m.group(1)
        if task not in FMT_ARG_INDEX:
            continue
        idx = FMT_ARG_INDEX[task]
        args, _ = split_args(code, m.end() - 1)
        if args is None or len(args) <= idx:
            continue
        fmt = args[idx].strip()
        if fmt.startswith('"'):
            continue                      # literal -- fine
        # No further arguments means nothing would be substituted anyway and
        # both simulators print the string as it stands; that is not this
        # defect class.
        if len(args) <= idx + 1:
            continue
        yield code.count("\n", 0, m.start()) + 1, task, fmt


def main() -> int:
    failures, waived, scanned = [], [], 0
    per_file = {}
    for d in SEARCH_DIRS:
        base = REPO / d
        if not base.is_dir():
            continue
        for path in sorted(list(base.rglob("*.sv")) + list(base.rglob("*.svh"))):
            if SKIP_PARTS & set(path.relative_to(REPO).parts):
                continue
            scanned += 1
            rel = path.relative_to(REPO).as_posix()
            for lineno, task, fmt in scan(path):
                per_file.setdefault(rel, []).append((lineno, task, fmt))

    for rel, hits in sorted(per_file.items()):
        if rel in WAIVERS:
            want, reason = WAIVERS[rel]
            if len(hits) == want:
                waived.append(f"  [WAIVED] {rel}: {len(hits)} known site(s) -- {reason}")
                continue
            failures.append(
                f"  [FAIL] {rel}: {len(hits)} non-literal format argument(s), "
                f"waiver covers {want}. Lines: "
                f"{', '.join(str(h[0]) for h in hits)}. Either fix the new "
                f"site or update the waiver in scripts/check_sim_fmt.py "
                f"WITH a reason.")
            continue
        for lineno, task, fmt in hits:
            failures.append(
                f"  [FAIL] {rel}:{lineno}: ${task}(... ) takes its format from "
                f"`{fmt}`, not a literal. Verilator 5.040 (the .abc.config "
                f"default backend, i.e. `make sim`) does not substitute a "
                f"non-literal format -- it prints the format string itself. "
                f"Use a literal at the call site (branch on the width instead "
                f"of parameterising the format). See D1-F2.")

    for line in waived:
        print(line)
    if failures:
        print("\n".join(failures))
        print(f"[check_sim_fmt] {len(failures)} failure(s) over {scanned} file(s)")
        return 1
    print(f"[check_sim_fmt] OK: {scanned} SystemVerilog file(s) in "
          f"{'/, '.join(SEARCH_DIRS)}/ -- every $display/$sformatf/... format "
          f"argument is a string literal ({len(waived)} waived file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
