#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""RDL enum-encoding guard: a declared enum must be ASSIGNED to a field.

SystemRDL lets a field DECLARE an enumeration inline and still not use it:
the declaration names a type, the `encode` property is what binds that type
to the field. Miss the second half and the file still compiles, the field
still reads and writes, every simulation still passes -- and every exporter
downstream silently drops the value list:

  * PeakRDL-regblock emits no `typedef enum` for the field,
  * PeakRDL-html renders the field with its description and NO value table,
  * anything walking the elaborated model gets `None` from
    `field.get_property("encode")` -- which is how this was found: the doc
    repository's register generator produced a table row for
    `sink_ctrl.pib_pattern` that just stopped after the description
    (doc@master, doc_internal/ctte/PROMPT_ctrace_rdl_encode_pib_pattern.md,
    2026-08-24).

Measured on that field, same renderer, only the `encode` line differing:
without it, zero of the six enum strings reach the HTML; with it, all six do.
So the defect is invisible in the source, invisible in simulation, and only
shows up as an absence in generated documentation -- the shape this repo's
other drift guards exist for.

What is checked, and over what denominator: every `.rdl` file under `rdl/`
and `examples/` (the SOURCES). Copies under `bld/` are deliberately excluded
-- they are generator output, regenerated from these; counting them turns
this file's numbers into build-state noise (a plain `grep -r` over the tree
reports 509 declarations against 18 real ones for exactly that reason).

A declaration that is intentionally a bare type anchor is legal, but it has
to say so: put

    // RDL-ENCODE-EXEMPT: <reason>

on a line above the `enum` keyword.

Exit 0 = OK, 1 = a declared enumeration nobody assigned.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE_DIRS = ("rdl", "examples")
EXEMPT = "RDL-ENCODE-EXEMPT"

DECL = re.compile(r"(?<![A-Za-z_])enum[ \t]+([A-Za-z_][A-Za-z_0-9]*)[ \t]*{")
ENC = re.compile(r"(?<![A-Za-z_])encode[ \t]*=[ \t]*([A-Za-z_][A-Za-z_0-9]*)[ \t]*;")


def source_files():
    out = []
    for d in SOURCE_DIRS:
        out += sorted((REPO / d).rglob("*.rdl"))
    return out


def main() -> int:
    files = source_files()
    assigned = set()
    decls = []  # (path, line, type name, exempt?)

    for f in files:
        text = f.read_text(encoding="utf-8")
        lines = text.splitlines()
        for m in ENC.finditer(text):
            assigned.add(m.group(1))
        for m in DECL.finditer(text):
            ln = text[: m.start()].count("\n") + 1
            above = lines[ln - 2] if ln >= 2 else ""
            decls.append((f, ln, m.group(1), EXEMPT in above))

    n_exempt = sum(1 for d in decls if d[3])
    print(
        "[check_rdl_encode] %d source .rdl files under %s; "
        "%d enum declarations (%d exempt), %d distinct types assigned via encode"
        % (len(files), "/, ".join(SOURCE_DIRS) + "/", len(decls), n_exempt, len(assigned))
    )

    bad = [d for d in decls if not d[3] and d[2] not in assigned]
    for f, ln, name, _ in bad:
        rel = f.relative_to(REPO).as_posix()
        print("  [FAIL] %s:%d: enum %s is declared but never assigned "
              "(`encode = %s;` missing) -- no exporter will emit its values"
              % (rel, ln, name, name))

    if bad:
        print("[check_rdl_encode] FAIL: %d unassigned enum declaration(s). "
              "Add `encode = <type>;` to the field, or mark the declaration "
              "with `// %s: <reason>` if it really is a bare type anchor."
              % (len(bad), EXEMPT))
        return 1

    print("[check_rdl_encode] OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
