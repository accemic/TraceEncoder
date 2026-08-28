#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""swwel census guard: every ungated CSR field is one the RDL names on purpose.

`rdl/ct_cs_cpuif.rdl` locks configuration fields with

    <field> ->swwel = te.trTeControl.Enable;

and PeakRDL turns that into one extra term in the generated write branch
(`&& !(field_storage.te.trTeControl.Enable.value)`). The header of that
assignment block also carries a list titled "Not gated (intentionally always
writable)" -- the only place where the DIFFERENCE between "deliberately free"
and "forgotten" is written down.

That list was decoration. Measured 2026-08-15 (finding U3, a full CSR
read/write audit): it named 10 fields while 31 were ungated,
so "not in the list" carried no information, and one of the 21 silent ones was
a real defect -- the eight trTeInstFeatures.InstEn* bits, which the register's
own description and doc/integration.adoc both declared Enable-locked while the
hardware let them change mid-session (U10 F-1, fixed 2026-08-16).

The guard closes the loop in the only direction that can rot: it reads the
GENERATED block (the fact) and the list (the intent) and requires them to
agree.

  1. every field whose generated SW-write branch has no Enable term must be
     named in the list;
  2. every field named in the list must exist and must really be ungated --
     a name that has since been locked, renamed or deleted is stale intent
     and would hide the next omission;
  3. the census totals are printed, so a review sees the numbers move.

RW1C status bits count as ungated for (1): they carry no Enable term either,
and the list names them as its own group. Fields with no SW write branch at
all (hw-only) are outside the question.

Exit 0 = OK, 1 = drift (with the offending field named).
"""

import re
import sys
from collections import OrderedDict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GEN = REPO / "rtl" / "pkg" / "ct_cs_cpuif.sv"
RDL = REPO / "rdl" / "ct_cs_cpuif.rdl"

# The list block: from its title to the closing "Arrays collapse" sentence of
# the same comment header. Anchored on both ends so a truncated header (the
# failure mode that would silently empty the intent side) is a parse error,
# not an empty set.
LIST_START = "Not gated (intentionally always writable)"
LIST_END = "Arrays collapse to a single assignment"

GATE_TERM = "!(field_storage.te.trTeControl.Enable.value)"

failures = []


def fail(what: str) -> None:
    failures.append(f"[check_swwel_census] FAIL: {what}")


def census(text: str) -> "OrderedDict[str, str]":
    """Classify every generated field block by its SW write branch."""
    out = OrderedDict()
    cur, body = None, []

    def flush():
        if cur is None:
            return
        blob = "\n".join(body)
        if "decoded_req_is_wr" not in blob:
            kind = "NONE"          # hw-only field, no software write path
        elif GATE_TERM in blob:
            kind = "GATED"
        elif "SW write 1 clear" in blob:
            kind = "W1C"
        else:
            kind = "FREE"
        out[cur] = kind

    for line in text.splitlines():
        m = re.match(r"\s*// Field: (\S+)", line)
        if m:
            flush()
            cur, body = m.group(1), []
        elif cur is not None:
            body.append(line)
    flush()
    return out


def listed_names(text: str) -> set:
    """Field names mentioned in the intent list, normalised to the census
    spelling (`ct_cs_cpuif.<path>`)."""
    try:
        block = text.split(LIST_START, 1)[1].split(LIST_END, 1)[0]
    except IndexError:
        fail(f"cannot find the intent list between "
             f"{LIST_START!r} and {LIST_END!r} in {RDL.name}")
        return set()

    names = set()
    # Two spellings appear: a plain path (te.trTeControl.Active) and a brace
    # expansion (te.trTeControl.{Active,Enable,...}). Both are expanded here;
    # anything else in the prose is ignored on purpose -- the guard must not
    # invent intent from a sentence.
    for m in re.finditer(r"\b((?:te|pc|atb|trWp\w*)(?:\.\w+)*)\.\{([^}]*)\}", block):
        prefix, inner = m.group(1), m.group(2)
        for leaf in re.split(r"[,\s]+", inner.replace("\n", " ")):
            leaf = leaf.strip().strip(".")
            if leaf:
                names.add(f"ct_cs_cpuif.{prefix}.{leaf}")
    for m in re.finditer(r"\b((?:te|pc|atb)\.\w+\.\w+)\b", block):
        names.add(f"ct_cs_cpuif.{m.group(1)}")
    return names


def main() -> int:
    gen = GEN.read_text(encoding="utf-8")
    rdl = RDL.read_text(encoding="utf-8")

    fields = census(gen)
    if not fields:
        fail(f"no fields parsed from {GEN.name}")
        print(failures[0])
        return 1

    listed = listed_names(rdl)
    ungated = [n for n, k in fields.items() if k in ("FREE", "W1C")]

    for name in ungated:
        if name not in listed:
            fail(f"{name} is software-writable while trTeControl.Enable=1 "
                 f"and is NOT in the intentional list in {RDL.name} -- add the "
                 f"swwel assignment, or the field WITH its reason to the list")

    for name in sorted(listed):
        kind = fields.get(name)
        if kind is None:
            fail(f"{name} stands in the intentional list of {RDL.name} but no "
                 f"such field exists in {GEN.name} (renamed? removed?)")
        elif kind == "GATED":
            fail(f"{name} stands in the intentional list of {RDL.name} but is "
                 f"Enable-gated in {GEN.name} -- stale intent hides the next "
                 f"omission")
        elif kind == "NONE":
            fail(f"{name} stands in the intentional list of {RDL.name} but has "
                 f"no software write path at all in {GEN.name}")

    tally = {}
    for k in fields.values():
        tally[k] = tally.get(k, 0) + 1

    if failures:
        for f_ in failures:
            print(f_)
        print(f"[check_swwel_census] {len(failures)} failure(s)")
        return 1

    print("[check_swwel_census] OK: {gated} Enable-gated, {free} free, "
          "{w1c} RW1C, {none} hw-only of {total} fields; all {ung} ungated "
          "fields are named in the RDL intent list".format(
              gated=tally.get("GATED", 0), free=tally.get("FREE", 0),
              w1c=tally.get("W1C", 0), none=tally.get("NONE", 0),
              total=len(fields), ung=len(ungated)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
