#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""A gate verdict has to belong to a tree this branch actually has.

The P8 fix round produced five verdict logs under verification/evidence/P8/, all
stamped `# HEAD : 9a41049`. That commit is not in this branch: the worker
had rebased its own commits onto the branch and never re-ran the gates, so
between the tree the logs judged and the tree they were filed against sat
four P4 commits touching the composer RTL, ct_pkg.sv, the formal runner
and the RDL. Nothing showed it. It surfaced only when a successor worker
took an inventory by hand, and the repair was a sixth log
(reverify_at_294bf6d.log) whose header says all of this in prose.

Prose is not a check, so here it is as one. For every
`verification/evidence/**/*.log` this guard asserts:

  H1  the header is well formed: `# gate`, `# package`, `# command`,
      `# HEAD` and `# when` are all present (verification/evidence/README.md);
  H2  the `# HEAD` stamp names a commit this repository knows;
  H3  that commit is an ANCESTOR of the current HEAD -- i.e. the tree the
      verdict was produced on is really part of this history. A log that
      fails H3 must carry `# superseded-by : <path>` naming another
      evidence log that passes H3 itself. That is the P8 case: five
      orphaned logs, one successor that re-ran the gates where they had
      to hold. A superseded log's stamp may even fail H2: a commit that was
      rebased away is not an object of a fresh clone at all (the P8 stamps
      are exactly that in any clone that never held the worker's branch).
      The superseding log carries the verdict, so the unknown stamp is
      accepted -- but ONLY behind a valid supersession; an unknown stamp
      without one is still red;
  H4  a log may declare `# covers : <path> [<path>...]`. It then claims to
      be CURRENT for those paths, and the guard fails it as soon as any of
      them changed after its stamp. Use it for evidence a package is still
      leaning on; a closed package's log does not declare it, because
      every closed package's evidence is older than today's RTL and
      failing on that would say nothing.

Regardless of the verdict, the guard PRINTS the inventory: for each log,
its age in commits and which of rtl/, rdl/, formal/, scripts/, tests/
and verification/ moved since it was written. That table, taken by hand, is what found
the defect in the first place -- running it on every `make lint` is the
cheap half of the fix.

Exit 0 = every verdict belongs to a tree in this history (and every
`covers` claim still holds), 1 = at least one does not.
"""

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
EVIDENCE = REPO / "verification" / "evidence"

REQUIRED = ("gate", "package", "command", "HEAD", "when")
# The areas whose movement matters for a verdict. Everything else in the
# tree (doc/, docs/, .claude/) cannot change what a gate measured.
AREAS = ("rtl", "rdl", "formal", "scripts", "tests", "verification")

HDR_RE = re.compile(r"^#\s*([A-Za-z-]+)\s*:\s*(.*?)\s*$")


def git(*args):
    return subprocess.run(["git", "-C", str(REPO), *args],
                          capture_output=True, text=True)


def header(path: Path) -> dict:
    """Header fields of an evidence log (the leading `# key : value` block).

    Continuation lines ("#           more text") extend the previous key,
    which is how the existing logs write multi-line notes.
    """
    out, last = {}, None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("#"):
            break
        m = HDR_RE.match(line)
        if m:
            last = m.group(1)
            out.setdefault(last, m.group(2))
        elif last is not None:
            out[last] += " " + line.lstrip("# ").strip()
    return out


def main() -> int:
    if not EVIDENCE.is_dir():
        print(f"[check_evidence_stamp] ERROR: {EVIDENCE} does not exist")
        return 1

    logs = sorted(EVIDENCE.rglob("*.log"))
    if not logs:
        print("[check_evidence_stamp] OK: no evidence logs yet")
        return 0

    heads = {p: header(p) for p in logs}
    problems, inventory = [], []

    # A PUBLISHED tree has no history to check H3 against, and pretending
    # otherwise would turn this guard into a liar in the one repository that
    # matters most.
    #
    # The published repository is a single root commit (the development
    # history was an internal working journal; see that commit's message).
    # None of the stamps below can be an ancestor of it -- not because the
    # evidence is unsound, but because the commits they name are not in this
    # clone. Two wrong answers were available and both are refused here:
    # re-stamping the logs onto the release commit would make every stamp
    # say something untrue, and passing H3 silently would make the guard
    # report a check it did not perform.
    #
    # So: detect the shape, skip H3 for every log, and SAY SO on every line
    # of the inventory. H1, H2 and H4 still run -- a malformed header or a
    # stale `# covers` is just as wrong in a release tree as anywhere else.
    # `rev-parse HEAD^` is NOT usable as the probe: on a root commit it fails
    # AND echoes "HEAD^" on stdout, so a stdout test reads it as success.
    # Ask for the return code of the --verify form instead.
    truncated = (git("rev-list", "--count", "HEAD").stdout.strip() == "1"
                 and git("rev-parse", "--verify", "--quiet",
                         "HEAD^").returncode != 0)
    if truncated:
        print("[check_evidence_stamp] history-truncated tree (single root "
              "commit): H3 (stamp is an ancestor of HEAD) CANNOT be checked "
              "here and is reported as UNVERIFIABLE, not as passed. Run this "
              "guard in the development repository to check ancestry.")

    # H3 needs to know which logs are themselves sound, so resolve ancestry
    # for everything first.
    ancestry = {}
    for p, h in heads.items():
        sha = h.get("HEAD", "")
        if not sha:
            ancestry[p] = "missing"
            continue
        # ORDER MATTERS. In a history-truncated tree the stamped commits
        # are not objects of this clone either, so the `cat-file` probe below
        # would call every one of them "unknown" -- a wrong diagnosis with a
        # right-sounding name. Ask about the shape of the repository first.
        if truncated:
            ancestry[p] = "unverifiable"
            continue
        if git("cat-file", "-e", f"{sha}^{{commit}}").returncode != 0:
            ancestry[p] = "unknown"
            continue
        ok = git("merge-base", "--is-ancestor", sha, "HEAD").returncode == 0
        ancestry[p] = "ancestor" if ok else "orphan"

    for p in logs:
        rel = p.relative_to(REPO).as_posix()
        h = heads[p]

        missing = [k for k in REQUIRED if k not in h]
        if missing:
            problems.append(f"{rel}: header is missing {', '.join(missing)} "
                            f"(verification/evidence/README.md names the five fields)")
            continue

        sha = h["HEAD"]
        state = ancestry[p]
        sup = h.get("superseded-by", "").split()[0] if h.get("superseded-by") else ""
        if state == "unknown" and not sup:
            problems.append(f"{rel}: `# HEAD : {sha}` is not a commit this "
                            f"repository knows (and the log is not "
                            f"superseded by one that is)")
            continue

        # "unknown" = the stamp is not even an object of this clone, which is
        # what a rebased-away commit looks like from a fresh clone. With a
        # valid supersession it is handled exactly like an orphan; without
        # one it was refused above.
        if state in ("orphan", "unknown"):
            if not sup:
                problems.append(
                    f"{rel}: `# HEAD : {sha}` is NOT in this branch's history "
                    f"-- the tree this verdict was produced on was rebased "
                    f"away or never merged, so the verdict says nothing about "
                    f"the branch. Re-run the gate at a commit that is in the "
                    f"history, or add `# superseded-by : <log>` naming the "
                    f"run that did.")
                continue
            target = REPO / sup
            if not target.is_file():
                problems.append(f"{rel}: `# superseded-by : {sup}` names a file "
                                f"that is not in the tree")
                continue
            if ancestry.get(target) != "ancestor":
                problems.append(f"{rel}: `# superseded-by : {sup}`, but that "
                                f"log is not itself stamped with a commit in "
                                f"this history -- superseding one orphan with "
                                f"another proves nothing")
                continue

        # --- inventory + H4 ------------------------------------------------
        tag = {"ancestor": "",
               "unverifiable": "  H3 UNVERIFIABLE (history-truncated tree)",
               "orphan": f" SUPERSEDED by {sup}",
               "unknown": f" SUPERSEDED by {sup} (stamp is not an object of "
                          f"this clone)"}[state]
        if state == "unknown":
            # Nothing to diff against: the stamp is not in this clone.
            inventory.append(f"  {rel}\n      HEAD {sha}{tag}")
            continue
        cnt = git("rev-list", "--count", f"{sha}..HEAD")
        n_behind = cnt.stdout.strip() if cnt.returncode == 0 else "?"
        names = git("diff", "--name-only", f"{sha}..HEAD")
        changed = set()
        if names.returncode == 0:
            for f in names.stdout.splitlines():
                top = f.split("/", 1)[0]
                if top in AREAS:
                    changed.add(top)
        inventory.append(
            f"  {rel}\n"
            f"      HEAD {sha}{tag}, {n_behind} commit(s) behind; "
            f"moved since: {', '.join(sorted(changed)) if changed else '(nothing)'}")

        covers = h.get("covers", "")
        if covers and state == "ancestor":
            stale = []
            for spec in covers.split():
                d = git("diff", "--name-only", f"{sha}..HEAD", "--", spec)
                if d.returncode == 0 and d.stdout.strip():
                    n = len(d.stdout.strip().splitlines())
                    stale.append(f"{spec} ({n} file(s))")
            if stale:
                problems.append(
                    f"{rel}: declares `# covers : {covers}` -- i.e. it claims "
                    f"to be current for those paths -- but they changed after "
                    f"{sha}: {'; '.join(stale)}. The verdict is older than "
                    f"what it judges. Re-run the gate, or drop the `covers` "
                    f"line and let it be package history.")

    print(f"[check_evidence_stamp] inventory ({len(logs)} verdict log(s)):")
    for line in inventory:
        print(line)

    if problems:
        print("[check_evidence_stamp] FAIL")
        for p in problems:
            print(f"  - {p}")
        return 1
    # The closing line must not claim more than was checked: in a
    # history-truncated tree H3 did not run, and "every stamp in this
    # branch's history" would be exactly the false green this guard exists
    # to prevent.
    if truncated:
        print(f"[check_evidence_stamp] OK: {len(logs)} verdict(s), headers and "
              f"coverage checked; ancestry NOT checked (history-truncated tree)")
    else:
        print(f"[check_evidence_stamp] OK: {len(logs)} verdict(s), every stamp in "
              f"this branch's history")
    return 0


if __name__ == "__main__":
    sys.exit(main())
