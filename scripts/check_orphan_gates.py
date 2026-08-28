#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Nothing that can judge may sit there unstarted.

This repository has written the rule down once already, in
scripts/cli_preprocsync_test.sh: "A testbench that nothing starts is a silent
failure -- it cannot go red." It was written after ONE such testbench was
found by accident (P8 re-check RC-2). It happened again with
tests/instruction/19_feature_matrix (D1-F6, 2026-08-09), also by accident --
a neighbouring package happened to look.

Twice by accident is a class, not a coincidence, so V1 counted it. The
inventory on 2026-08-09 found:

  * 45 cli_*_test.sh exist, the gate list named 34. Nine gates are
    started by NOTHING in the whole tree -- finished runners, with verdicts
    and floors, that cannot go red.
  * 16 testbenches are named by no script, Makefile target or CI entry.

V2 did that work on the same day: all nine gates were run and triaged
(docs/handoffs/V2_blind_gates.md §2). Eight were green, so they are wired into
the gate battery and their entries are gone from the list below; the ninth
skips itself for a reason a run established. The testbench half is unchanged --
see that handoff §4 for what each of the sixteen turned out to be.

This guard does not fix that -- fixing it means running and triaging each one,
which is its own work. It FREEZES it: every orphan known on 2026-08-09 is
listed below with the reason it is still an orphan, and anything NEW turns the
guard red. A waiver list that grows silently would be the same failure one
level up, so the lists are exact: an entry that is no longer an orphan (good
news) also turns the guard red, and is removed in the commit that wired it up.

Reachability is TRANSITIVE: a gate that scripts/gates.list does not name but
that another reachable gate calls (cli_resyncir_test.sh runs cli_etrace_test.sh)
counts as started.

Scope note: `sim/` is deliberately NOT scanned. It
belongs to the board packages, which have their own runner
conventions (Vivado projects, board scripts); a guard that judged them by this
repository's cli convention would be red about a convention that does not
apply there.

Known weakness, stated rather than hidden: "started" here means the name
appears in a starter file. A gate mentioned only in a COMMENT inside a shell
script would count as started. That is deliberate -- the alternative is
parsing shell -- and it is why the waiver entries carry a reason a human
checked, not just a name.

Exit 0 = no unexpected orphan, 1 = at least one (in either direction).
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GATE_LIST = REPO / "scripts" / "gates.list"

# Directories a runner could live in.
STARTER_DIRS = ("scripts", "tools", "vivado")
STARTER_SUFFIXES = (".sh", ".py", ".tcl", ".ps1", ".yml", ".yaml", "")
SKIP_PARTS = {"bld", ".git", "coverage_html", "third_party", "_retired_2026-08-09_superseded_by_doc_repo"}

# Testbench roots. See the scope note in the docstring for what is left out.
# The adapter benches use the tb_* PREFIX convention (they came from the
# board integration tree); without the third glob they would be invisible
# to this guard -- which is precisely the failure mode it exists to stop.
TB_GLOBS = ("tests/**/*_tb.sv", "rtl/**/test/*_tb.sv", "rtl/**/test/tb_*.sv")


# ---------------------------------------------------------------------------
# Known orphans, 2026-08-09 (V1). Each entry says WHY it is still one.
# ---------------------------------------------------------------------------
# V2 (2026-08-09) ran all nine. Seven were green and are wired into
# scripts/gates.list in the same commit, so their entries are gone from this
# list -- the list is exact in both directions, and a wired gate that kept its
# waiver would turn this guard red. One remains, for a reason that a run
# established rather than assumed.
# Empty since 2026-08-19, and that is the point: the one entry it held said
# `etrace_ctxp` could only ever SKIP here, because the decoder in bin/ had no
# `-decoe` front end. That stopped being true when this repository moved to
# the pinned CTTD build -- `cttd -h` lists `-decoe`, and the gate now runs
# green on six legs (26/20/60/1154/76/171 PCs). The waiver was a correct
# statement about a decoder that is no longer the one we ship.
#
# A waiver is a promise that someone re-checks it. This one was checked by
# the guard itself: wiring the gate into stage 2 made this file fail with
# "is in GATE_WAIVERS but IS started now -- good news", which is exactly the
# service an allowlist owes its reader. Keep it that way: no entry without a
# reason, and no reason that nobody re-tests.
GATE_WAIVERS = {}

TB_WAIVERS = {
    # Eleven unit testbenches of the pre-processor. They are in NO glob at
    # all: scripts/coverage_suite.sh collects rtl/test/, rtl/mseo_mdo/test/
    # and tests/lib/test/ -- rtl/preproc/test/ is missing from that list.
    "rtl/preproc/test/ct_L23_preproc_act_cap_tb.sv":      "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_act_proc_tb.sv":     "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_act_st_tb.sv":       "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_axis_tb.sv":         "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_cf_tb.sv":           "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_comp_filters_tb.sv": "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_df_range_tb.sv":     "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_df_split_tb.sv":     "no runner, no glob, and no .abc file either",
    "rtl/preproc/test/ct_L23_preproc_df_tb.sv":           "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_perfcnt_tb.sv":      "no runner, no glob",
    "rtl/preproc/test/ct_L23_preproc_tb.sv":              "no runner, no glob",
    # Five that scripts/coverage_suite.sh does run -- but that script is a
    # coverage collector, not a gate: the gate battery does not call it, and its verdict
    # rule accepts "rc=0 and no PASS tag" as DONE (V1-F6).
    "rtl/test/ct_L2_nexus_formatter_tb.sv":               "runs only in coverage_suite.sh, which judges nothing (V1-F6)",
    "rtl/test/ct_L2_nexus_formatter_err_tb.sv":           "runs only in coverage_suite.sh, which judges nothing (V1-F6)",
    "rtl/mseo_mdo/test/ct_L2_mseo_mdo_formatter_tb.sv":   "runs only in coverage_suite.sh, which judges nothing (V1-F6)",
    # V2 correction: this one does NOT run in coverage_suite.sh either -- it
    # cannot run at all. tests/lib/ct_nexus_decoder.abc:6 reads
    # ../../nexus/mseo2_decoder.sv, and nexus/ does not exist in this tree.
    # That is deliberate and documented at tests/lib/ct_env.sv:216-221:
    # the in-sim Nexus decoder is not instantiated because mseo2_decoder was
    # never ported here; Nexus content is checked offline with NexRv instead.
    "tests/lib/test/ct_nexus_decoder_tb.sv":              "cannot run here: its DUT needs nexus/mseo2_decoder.sv, which was never ported into this repo (ct_env.sv:216)",
}


def read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def starter_files():
    out = []
    for d in STARTER_DIRS:
        base = REPO / d
        if not base.is_dir():
            continue
        for p in base.rglob("*"):
            if not p.is_file() or SKIP_PARTS & set(p.relative_to(REPO).parts):
                continue
            # This file names every known orphan -- counting itself as a
            # starter would make the guard permanently satisfied by its own
            # waiver list.
            if p.resolve() == Path(__file__).resolve():
                continue
            if p.suffix in STARTER_SUFFIXES:
                out.append(p)
    mk = REPO / "Makefile"
    if mk.is_file():
        out.append(mk)
    return out


def main() -> int:
    failures, notes = [], []

    files = starter_files()
    text = {p: read(p) for p in files}

    # ---- 1. cli gates ----------------------------------------------------
    gates = sorted(p.stem[len("cli_"):-len("_test")]
                   for p in (REPO / "scripts").glob("cli_*_test.sh"))
    if not GATE_LIST.is_file():
        print("  [FAIL] scripts/gates.list not found -- this guard cannot judge "
              "anything without the list of gates the battery runs")
        return 1
    listed = set()
    for line in GATE_LIST.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            listed.add(line)
    if not listed:
        print("  [FAIL] scripts/gates.list names no gate -- an empty list would "
              "make every gate in the tree an orphan, which is not a verdict")
        return 1

    unknown = listed - set(gates)
    if unknown:
        failures.append(f"  [FAIL] scripts/gates.list names gate(s) with no script: "
                        f"{sorted(unknown)}")

    # Transitive closure: a gate called by a reachable gate is reachable.
    reachable = set(listed)
    changed = True
    while changed:
        changed = False
        for g in gates:
            if g in reachable:
                continue
            for r in list(reachable):
                rp = REPO / "scripts" / f"cli_{r}_test.sh"
                if rp.is_file() and f"cli_{g}_test" in read(rp):
                    reachable.add(g)
                    changed = True
                    break

    orphan_gates = [g for g in gates if g not in reachable]
    for g in orphan_gates:
        if g in GATE_WAIVERS:
            notes.append(f"  [KNOWN] gate {g}: {GATE_WAIVERS[g]}")
        else:
            failures.append(
                f"  [FAIL] scripts/cli_{g}_test.sh is started by NOTHING. Add it to "
                f"scripts/gates.list (after running it once and "
                f"triaging what it says), or record it in GATE_WAIVERS with a reason. "
                f"A gate nobody starts cannot go red.")
    for g in GATE_WAIVERS:
        if g not in orphan_gates:
            failures.append(
                f"  [FAIL] gate {g} is in GATE_WAIVERS but IS started now -- good news. "
                f"Remove the waiver in the same commit that wired it up, so the list "
                f"keeps meaning what it says.")

    # ---- 2. testbenches --------------------------------------------------
    tbs = sorted({p for g in TB_GLOBS for p in REPO.glob(g)})
    orphan_tbs = []
    for tb in tbs:
        rel = tb.relative_to(REPO).as_posix()
        if SKIP_PARTS & set(tb.relative_to(REPO).parts):
            continue
        name = tb.stem
        if not any(name in t for p, t in text.items() if p != tb):
            orphan_tbs.append(rel)
    for rel in orphan_tbs:
        if rel in TB_WAIVERS:
            notes.append(f"  [KNOWN] testbench {rel}: {TB_WAIVERS[rel]}")
        else:
            failures.append(
                f"  [FAIL] {rel} is named by no script, Makefile target or CI entry. "
                f"Give it a runner (see scripts/cli_featurematrix_test.sh for the "
                f"pattern) or record it in TB_WAIVERS with a reason.")
    for rel in TB_WAIVERS:
        if rel not in orphan_tbs:
            if not (REPO / rel).exists():
                failures.append(f"  [FAIL] TB_WAIVERS names {rel}, which no longer exists -- "
                                f"drop the entry")
            else:
                failures.append(
                    f"  [FAIL] {rel} is in TB_WAIVERS but IS started now -- good news. "
                    f"Remove the waiver in the same commit that wired it up.")

    for n in notes:
        print(n)
    if failures:
        print("\n".join(failures))
        print(f"[check_orphan_gates] {len(failures)} failure(s)")
        return 1
    print(f"[check_orphan_gates] OK: {len(gates)} cli gate(s), {len(reachable)} reachable "
          f"from scripts/gates.list, {len(orphan_gates)} known-orphan; "
          f"{len(tbs)} testbench(es), {len(orphan_tbs)} known-orphan. No NEW orphan.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
