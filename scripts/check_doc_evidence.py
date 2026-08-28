#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""A documented resource number needs a report a reader can open.

Twice, one commit apart, the same defect: a cost table in doc/ named the
report its numbers came from, the path pointed into `bld/`, and `bld/` is
gitignored. The next run of the same script overwrote that file with a
different configuration, so a reader following the reference arrived at
numbers contradicting the table -- and nobody could tell whether the table
or the file was wrong (P4 audit B-1, closed by 5293130; P8 closing audit
B-N2, the same class one commit later). The rule that came out of it is in
verification/evidence/README.md: *the utilization report a documented cost number is
read from is versioned*.

A rule that lives only in a README gets forgotten a third time, so it is
checked here. For every section of doc/*.adoc that quotes resource
numbers -- recognised by a table column named "CLB LUTs" or a
"Register as FF" / "Register as Flip Flop" column -- this guard asks three
questions:

  1. does the section name at least one utilization REPORT inside the
     tree (`verification/evidence/**/*.rpt`)? A section that only names `bld/`
     paths quotes numbers nobody can check. It has to be a .rpt: the
     second red control replaced the two report references by `bld/`
     paths and the guard stayed green, because a verdict LOG in the same
     section satisfied a weaker "any in-tree path" test. A log is not
     where a LUT count is read from.
  2. does every verification/evidence path it names exist?
  3. do the numbers in the report agree with the numbers in the table?
     Every "CLB LUTs*" and "Register as Flip Flop" value of every report
     the section names must appear in that section's tables. This is what
     catches a stale measurement generation: the report is in the tree,
     the table was written from an older run, and the two disagree.
     A section whose table also carries a block-RAM column has its
     "Block RAM Tile" value checked the same way. That row used to be
     read by nobody: the R1.1 closing audit changed the LUT figure of
     the address-width table from 26 283 to 26 284 and the guard went
     red, changed the BRAM figure from 11 to 42 and it stayed green
     (finding C-1). The row is checked only where a table quotes it,
     because most cost tables have no BRAM column at all and a report
     row nobody quotes is evidence for nothing.

Question 3 deliberately does not try to map a report to a table ROW (the
row labels are prose). It checks set membership, which is enough: a table
written from a different run of the same configuration has different
numbers, and a number that is nowhere in the table is reported with both
values so the reader sees the drift immediately.

The membership is tested against the TABLE CELLS only, not against the
section text. The first red control for this guard changed one cell of
the P8 table and it stayed green, because the same figure also appears in
the prose two paragraphs down -- so the prose was covering for the table.
Restricting the search to lines that start with "|" makes a single wrong
cell red, which is the case that matters.

Number formatting: AsciiDoc tables use a thin space or a plain space as
the thousands separator ("25 707"), Vivado reports do not ("25707"). Both
spellings are accepted, and only those two -- a match against the bare
digit string anywhere in the section would be far too weak. Block-RAM
tiles come as halves ("9.5"): the fraction is carried through unchanged,
there is nothing to group.

Exit 0 = every quoted resource number has a checkable source in the tree,
1 = at least one does not.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DOC_DIR = REPO / "doc"

# The Vivado utilization rows a cost table is allowed to quote, in the exact
# spelling the report uses. doc/integration.adoc names them for the reader
# (P9 audit F7): "CLB LUTs*" is the LUT column, "Register as Flip Flop" the
# flip-flop one -- NOT "CLB Registers", which also counts latches.
RPT_ROWS = ("CLB LUTs*", "Register as Flip Flop")

# The block-RAM row, in the report's spelling. Checked only in sections
# whose table actually carries a BRAM column -- see the docstring on
# audit finding C-1.
BRAM_ROW = "Block RAM Tile"

# A section is a "cost section" when its table header carries one of these.
COST_COLUMNS = ("CLB LUTs", "Register as FF", "Register as Flip Flop")

# ... and it quotes block RAM when a table cell carries one of these. The
# match is against the table lines, not the prose: "the +1.5 BRAM tiles are
# not the jump-target cache" is an explanation, not a quoted number.
BRAM_COLUMNS = ("Block RAM Tile", "Block RAM", "BRAM")

# What a report cell may hold for one of those rows: an integer count, or
# a half tile ("9.5"). Anything else is not a number this guard reads.
VALUE_RE = re.compile(r"^\d+(?:\.\d+)?$")

# Paths mentioned in prose or in a link: macro.
PATH_RE = re.compile(r"(?:link:\.\./)?((?:verification/evidence|bld)/[A-Za-z0-9_./*-]+)")
# Section = an anchored block [#name] up to the next anchor OR the next
# heading, whichever comes first. Without the heading terminator an anchored
# block swallows every unanchored section after it, and prose in one of those
# ("a section quoting CLB LUTs must name a .rpt") makes the guard analyse a
# section that quotes no numbers at all. `^= ` with the space is the heading
# form; `====` without one is a block delimiter and must NOT end a section.
ANCHOR_RE = re.compile(r"^\[#([A-Za-z0-9_-]+)\]\s*$")
HEADING_RE = re.compile(r"^={1,6}\s+\S")


def read_report(path: Path, rows: tuple) -> dict:
    """{row label: value as the report prints it} for the requested rows."""
    out = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.split("|")]
        # "| CLB LUTs*  | 25707 | 0 | ..." -> cells[1] label, cells[2] used
        if len(cells) < 3:
            continue
        for row in rows:
            if cells[1] == row and VALUE_RE.match(cells[2]):
                out[row] = cells[2]
    return out


def spellings(raw: str) -> tuple:
    """How an AsciiDoc table may write the value the report prints.

    Integer counts get the thousands separators the tables use; a half
    tile ("9.5") has no group to separate, its fraction rides along.
    """
    whole, _, frac = raw.partition(".")
    tail = f".{frac}" if frac else ""
    n = int(whole)
    plain = raw
    grouped = f"{n:,}".replace(",", " ")          # 25707 -> "25 707"
    thin = f"{n:,}".replace(",", " ")        # thin space
    nbsp = f"{n:,}".replace(",", " ")        # non-breaking space
    # dict.fromkeys keeps the order and drops the duplicates a value below
    # 1000 produces -- "11" is its own grouping.
    return tuple(dict.fromkeys(
        (plain, grouped + tail, thin + tail, nbsp + tail)))


def sections(text: str):
    """Yield (anchor, body) for every [#anchor] block in an .adoc file."""
    lines = text.splitlines()
    starts = [(i, m.group(1)) for i, l in enumerate(lines)
              for m in [ANCHOR_RE.match(l)] if m]
    for idx, (start, name) in enumerate(starts):
        end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
        for i in range(start + 1, end):
            if HEADING_RE.match(lines[i]):
                end = i
                break
        yield name, "\n".join(lines[start:end])


def main() -> int:
    problems = []
    checked_sections = 0
    checked_numbers = 0

    docs = sorted(DOC_DIR.glob("*.adoc"))
    if not docs:
        print(f"[check_doc_evidence] ERROR: no .adoc files under {DOC_DIR}")
        return 1

    for doc in docs:
        text = doc.read_text(encoding="utf-8", errors="replace")
        for name, body in sections(text):
            if not any(c in body for c in COST_COLUMNS):
                continue
            checked_sections += 1
            where = f"{doc.name}[#{name}]"
            # Only the table cells count as "the table says so" -- see the
            # module docstring on the first red control.
            cells = "\n".join(l for l in body.splitlines()
                              if l.lstrip().startswith("|"))

            # The BRAM row is only evidence where a table quotes it.
            rows = RPT_ROWS
            if any(c in cells for c in BRAM_COLUMNS):
                rows = RPT_ROWS + (BRAM_ROW,)

            paths = set(PATH_RE.findall(body))
            intree = sorted(p for p in paths if p.startswith("verification/evidence/"))
            bldonly = sorted(p for p in paths if p.startswith("bld/"))
            intree_rpt = [p for p in intree
                          if p.endswith(".rpt") and "*" not in p]

            if not intree_rpt:
                problems.append(
                    f"{where}: quotes resource numbers but names no "
                    f"utilization report in the tree. Paths mentioned: "
                    f"{', '.join(sorted(paths)) if paths else '(none)'} -- "
                    f"bld/ is gitignored and per-host, so those numbers "
                    f"cannot be checked by a reader, and a verdict .log is "
                    f"not where a LUT count is read from. Archive the .rpt "
                    f"under verification/evidence/<package>/ and reference it there "
                    f"(verification/evidence/README.md).")
                continue

            for rel in intree:
                if "*" in rel:      # a glob in prose, not a reference
                    continue
                if rel.endswith("/") or (REPO / rel).is_dir():
                    continue        # the directory, named as a location
                p = REPO / rel
                if not p.is_file():
                    problems.append(f"{where}: references {rel}, which is not "
                                    f"in the tree")
                    continue
                if not rel.endswith(".rpt"):
                    continue        # a verdict log, not a number source
                values = read_report(p, rows)
                if not values:
                    problems.append(f"{where}: {rel} carries none of the rows "
                                    f"a cost table quotes ({', '.join(rows)})")
                    continue
                for row, val in values.items():
                    checked_numbers += 1
                    if not any(s in cells for s in spellings(val)):
                        problems.append(
                            f"{where}: {rel} reports {row} = {val}, and no "
                            f"table cell in this section carries that number. "
                            f"Either the table was written from a different "
                            f"run than the report it names, or the report was "
                            f"replaced after the table was written.")

    if problems:
        print("[check_doc_evidence] FAIL")
        for p in problems:
            print(f"  - {p}")
        return 1

    print(f"[check_doc_evidence] OK: {checked_sections} cost section(s), "
          f"{checked_numbers} number(s) cross-checked against in-tree reports")
    return 0


if __name__ == "__main__":
    sys.exit(main())
