#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Every path a tutorial tells the reader to type has to exist.

A reviewer works through the tutorials line by line. A path that moved, a
script that was renamed, a directory that never made it into the tree --
none of that shows up in any test run, because no test reads the tutorial.
It shows up in front of the reader, at the first command that fails, and by
then the document has lost its credit.

That is the same class of defect as the seven found on 2026-08-19: green
everywhere, and still broken. The remedy is the same -- stop relying on
someone having checked once, and check it on every run.

The guard extracts from each documented file every backticked token that
looks like a path into this tree (contains a slash, no spaces, no shell
metacharacters) and asserts it exists. Tokens that are obviously not
in-tree paths are skipped by rule, and every skip rule is named here so a
reader can see what is NOT covered:

  * absolute paths and `/tmp/...`     -- they live on the board, not here
  * `$VAR` / `${VAR}` / `<...>`       -- placeholders the reader fills in
  * `bld/...`, `out/...`, `.../logs/...` -- build products, gitignored
                                       (`logs/` is where the KV260 Vivado
                                       flows write their build logs)
  * URLs                             -- not this tree's business

A path under `examples/.../bld/` is therefore NOT checked, and that is a
deliberate hole: those are outputs. If a tutorial promises an output file,
the promise is checked by the example's own test, not here.
"""
import re
import subprocess
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

DOCS = [
    "examples/kv260/TUTORIAL_build_demos.md",
    "examples/kv260/tgc5b2_rvcfi/HANDOVER_trace_your_own_software.md",
    "examples/kv260/tgc5b2_rvcfi/TUTORIAL_runtime_verification.md",
    "examples/kv260/README.md",
    "examples/README.md",
    "examples/dashboard/README.md",
    "README.md",
]

SKIP_PREFIX = ("/", "bld/", "out/", "http://", "https://", "~/")
SKIP_ANY = ("/proj/", ".runs/", "/bld/", "/out/", "/logs/")
SKIP_SUBSTR = ("$", "<", ">", "*", "?", "|", "..", "%", "…")


def looks_like_path(tok: str) -> bool:
    if "/" not in tok:
        return False
    if tok.startswith(SKIP_PREFIX):
        return False
    if any(c in tok for c in SKIP_SUBSTR):
        return False
    if any(k in tok for k in SKIP_ANY):
        return False
    # "26772/26772" is a test verdict and "text/html" a MIME type.
    if any(seg.isdigit() for seg in tok.split("/")):
        return False
    # Only tokens naming a FILE are checked -- a last segment with a dot in
    # it. Bare directories are deliberately out of scope: prose mentions them
    # ("older documentation pointed at a `sim/` directory that was never
    # migrated" is a correct sentence about a path that must NOT exist), and a
    # guard that argues with prose gets switched off. Files are unambiguous:
    # if a document tells the reader to run one, it has to be there.
    return "." in tok.rsplit("/", 1)[-1]


def make_targets(root: pathlib.Path) -> set:
    """Every target name the Makefile defines, from the file itself.

    Not `make -qp`: that needs make on PATH and a parsable tree, and this
    guard has to work in a checkout where nothing is built yet.
    """
    mf = root / "Makefile"
    if not mf.exists():
        return set()
    text = mf.read_text(encoding="utf-8", errors="replace")
    names = set()
    for m in re.finditer(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*:(?!=)", text, re.M):
        names.add(m.group(1))
    # `.PHONY: a b c` lists targets too, and some are defined only there
    for m in re.finditer(r"^\.PHONY\s*:(.*)$", text, re.M):
        names.update(m.group(1).split())
    return names


def main() -> int:
    bad = []
    checked = 0
    seen_docs = 0
    for rel in DOCS:
        p = ROOT / rel
        if not p.exists():
            bad.append((rel, "<the documented document itself is missing>"))
            continue
        seen_docs += 1
        text = p.read_text(encoding="utf-8", errors="replace")
        # Three spellings are all correct and all in use:
        #   `examples/kv260/mbv/fpga/gen_ip.tcl`  -- from the root
        #   `fpga/gen_ip.tcl`                     -- next to the document
        #   `board/mbv_board_gate.sh`             -- in a per-example table,
        #                                            meaning "in each example"
        # Resolving only against one of them reports the other two as
        # missing, which is noise, and noise is how a guard gets switched off.
        bases = [ROOT, p.parent] + sorted(
            d for d in (ROOT / "examples" / "kv260").iterdir() if d.is_dir()
        ) if (ROOT / "examples" / "kv260").is_dir() else [ROOT, p.parent]
        for tok in re.findall(r"`([^`\n]+)`", text):
            tok = tok.strip()
            # a command line: take only the arguments that look like paths
            for part in tok.split():
                part = part.strip(",;:()[]'\"")
                if not looks_like_path(part):
                    continue
                checked += 1
                # A README next to `mbv/` writes it that way; the tutorial
                # writes `examples/kv260/mbv/` for the same place. Both
                # spellings are correct, so both are tried -- resolving only
                # against the root would report every relative mention in
                # every README as missing, which is noise, and noise is how a
                # guard gets switched off.
                if not any(base.joinpath(part).exists() for base in bases):
                    bad.append((rel, part))
    # A tutorial that tells the reader to run `make sim-foo` has to name a
    # target that exists. This is the same failure as a moved path -- it fails
    # in front of the reader, and no test run reads a tutorial.
    targets = make_targets(ROOT)
    checked_t = 0
    if targets:
        for rel in DOCS:
            p = ROOT / rel
            if not p.exists():
                continue
            text = p.read_text(encoding="utf-8", errors="replace")
            # ONLY inside fenced code blocks. Prose says things like "every
            # `make sim-*` target" and "make every example build" -- neither is
            # an instruction, and a guard that argues with prose gets switched
            # off (same reasoning as the directory exclusion above).
            in_fence = False
            for line in text.splitlines():
                if line.lstrip().startswith("```"):
                    in_fence = not in_fence
                    continue
                if not in_fence:
                    continue
                for m in re.finditer(r"(?<![A-Za-z0-9._-])make[ 	]+([a-z0-9][a-z0-9._-]*)", line):
                    tgt = m.group(1)
                    checked_t += 1
                    if tgt not in targets:
                        bad.append((rel, f"make {tgt} (no such target)"))
    if bad:
        print(f"[check_tutorial_paths] {len(bad)} path(s) a reader would type do not exist:")
        for rel, tok in bad:
            print(f"  {rel}: {tok}")
        return 1
    print(f"[check_tutorial_paths] OK: {checked} path(s) and {checked_t} make target(s) "
          f"in {seen_docs} document(s) exist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
