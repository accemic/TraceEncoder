#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Profile-dependency drift guard: an elaboration guard is only half a fix.

Several build switches may not be enabled on their own. The RTL states that
with an elaboration `$fatal` of the shape

    $fatal(1, "<module>: CT_EN_A requires CT_EN_B (<reason>)");

which is the right place for it: a profile that violates the dependency
aborts loudly instead of building something meaningless.

The other half is that every script which selects such a profile has to
carry the dependency. That half has been forgotten three times in a row and
cost real time every time:

  * P3 (CT_EN_DF_ADDR_COMPRESS -> CT_EN_DATA_TRACE): the CAPS-22 re-mint
    silently lost all four compact=0 legs, and the pair gate then compared a
    missing dump set against a real one.
  * P4 (CT_EN_WATCHPOINT_MSG -> CT_EN_ACT): found while writing the status
    test; sixteen profile scripts had to be patched afterwards.
  * P7 (CT_EN_DF_DROP -> CT_EN_DATA_TRACE): the guard was added without
    touching a single profile script; every CF-only profile in the tree
    would have died in elaboration at its next run.

The failure mode is nasty because it is not local: the script that breaks is
usually NOT the one the feature author runs.

This guard therefore reads the dependencies out of the RTL itself (no second
list to keep in sync) and checks every profile script: a line that sets the
DEPENDED-ON switch to 0 must also set the DEPENDENT switch to 0 -- in the
same line or anywhere in the same shell function/leg.

Reading them out of the RTL has one failure mode of its own, and the P7
audit demonstrated it (finding B-3): with the `$fatal` wording changed from
"requires" to "needs", the guard reported

    [check_profile_deps] OK: 2 elaboration dependency(ies) ...   rc=0

-- green, while silently checking one dependency FEWER. A watchdog that
quietly shrinks is worse than no watchdog, so the reading is now guarded
from both sides:

  * EXPECTED_DEPS is the floor. Every pair listed there must be found in
    the RTL; a missing one fails with the reason and the two legitimate
    ways out (fix the wording, or drop the pair here together with the
    guard). It is deliberately a MINIMUM -- a new dependency needs no edit
    here, it is simply picked up and reported.
  * every `$fatal` whose message names two or more build switches must
    either parse as a dependency or stand in UNPARSED_OK. A reworded guard
    therefore turns up as a loud failure instead of a smaller number.

Exit 0 = OK, 1 = drift (with script, line and missing switch named).
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RTL_DIRS = ("rtl",)
SCRIPT_DIR = REPO / "scripts"

# Scripts that legitimately flip profile switches but are not profile
# selectors: they either drive a single named leg from the caller's values
# or are the generators themselves.
SKIP_SCRIPTS = {
    "p7_ooc_pair.sh",        # flips only the two P7 switches, both independent
    "p7_off_neutrality.sh",  # flips only status/trigger switches (no dependents)
}

# The floor: dependencies that MUST be found in the RTL. Keeps a reworded or
# deleted `$fatal` from silently shrinking this guard (P7 audit B-3).
# Add a line here only together with the guard itself; remove one only when
# the guard is genuinely gone.
EXPECTED_DEPS = {
    ("CT_EN_DF_ADDR_COMPRESS", "CT_EN_DATA_TRACE"),  # P3, ct_L2_nexus_formatter.sv
    ("CT_EN_WATCHPOINT_MSG",   "CT_EN_ACT"),         # P4, ct_L23_preproc_composer_etip.sv
    ("CT_EN_DF_DROP",          "CT_EN_DATA_TRACE"),  # P7, ct_L23_preproc_composer_etip.sv
    ("CT_EN_AXIS_TS",          "CT_EN_TIMESTAMP"),   # C0a, ct_L23_preproc_composer_axis.sv
    ("CT_EN_AXIS_TS",          "CT_EN_ACT"),         # C0a, ct_L23_preproc_composer_axis.sv
}

# Elaboration guards that name several switches but are NOT of the
# "A requires B" shape this checker models. They are listed with the exact
# phrase that identifies them: if one is reworded the phrase stops matching
# and the guard reports an unparsed dependency-shaped $fatal -- loud, which
# is the intended direction.
UNPARSED_OK = {
    # Inverse shape ("X requires the others to be OFF"): honoured by every
    # ptsuite/CF-only profile, which sets all three to 0 in one place.
    "CT_COMPACT_PACKER requires a CF-only profile",
    # Inverse shape as well ("set CT_EN_TRIG_REGS = 0"); the micro CSR is
    # selected by CT_MICRO_CSR, not by a profile script switch line.
    "CT_MICRO_CSR does not implement the trigger configuration block",
    # Same shape, second omission of the same block (P8 closing audit A-N1):
    # the histogram registers 0xe10/0xe14 are not decoded by the twin either.
    "CT_MICRO_CSR does not implement the eTIP FIFO fill histogram",
    # X2a: not a feature dependency at all -- an address-width restriction of
    # the E-Trace back end. CT_XLEN is an int knob, not a CT_EN_* switch, so
    # no profile script can "switch it off"; the pairing this guard checks
    # does not exist for it.
    "EN_ETRACE=1 with ct_pkg::CT_XLEN=64 is not implemented",
    # R1.3, same class as the CT_XLEN entry above: a RANGE restriction on an
    # int knob, not a feature dependency. CT_IRETIRE_WIDTH cannot be
    # "switched off" by a profile script, so the pairing this checker models
    # does not exist for it -- the guard only names CT_EN_BLOCK_TIP to say
    # WHEN the range applies. Found 2026-08-09 (D1) with `make lint`: the
    # guard has been in the tree since f85b251bc and left the Stage-1 gate
    # check_profile_deps RED, which is exactly the loud failure the mechanism
    # is designed to produce -- it just had not been answered yet.
    "CT_IRETIRE_WIDTH must be 2..",
}

failures = []


def fail(msg: str) -> None:
    failures.append(f"  [FAIL] {msg}")


FATAL_MSG = re.compile(r'\$fatal\s*\(\s*1\s*,\s*"([^"]*)"')
DEP_SHAPE = re.compile(r'(CT_EN_[A-Z0-9_]+)\s+requires\s+(CT_EN_[A-Z0-9_]+)')
SWITCH_TOKEN = re.compile(r'\bCT_(?:EN_)?[A-Z][A-Z0-9_]*\b')


def collect_dependencies() -> dict:
    """{dependent: [(depended_on, source_file), ...]} from the $fatals.

    Every `$fatal` message that names two or more build switches has to end
    up in this dict or in UNPARSED_OK -- otherwise the reading itself has
    drifted and that is reported as a failure (B-3).

    A dependent may carry SEVERAL guards (C0a: CT_EN_AXIS_TS requires both
    CT_EN_TIMESTAMP and CT_EN_ACT), so the value is a list -- a plain
    per-dependent entry would keep only the last guard read and silently
    check one dependency fewer, which is exactly the B-3 failure mode this
    reader is guarded against.
    """
    deps = {}
    for d in RTL_DIRS:
        for f in sorted((REPO / d).rglob("*.sv")):
            rel = f.relative_to(REPO).as_posix()
            text = f.read_text(encoding="utf-8", errors="replace")
            for lineno, line in enumerate(text.splitlines(), start=1):
                for msg in FATAL_MSG.findall(line):
                    m = DEP_SHAPE.search(msg)
                    if m:
                        pair = (m.group(2), rel)
                        if pair not in deps.setdefault(m.group(1), []):
                            deps[m.group(1)].append(pair)
                        continue
                    if len(set(SWITCH_TOKEN.findall(msg))) < 2:
                        continue          # not a dependency-shaped message
                    if any(phrase in msg for phrase in UNPARSED_OK):
                        continue
                    fail(f"{rel}:{lineno}: $fatal names several build switches "
                         f"but does not parse as `CT_EN_A requires CT_EN_B` -- "
                         f"a reworded guard would be dropped SILENTLY. Restore "
                         f"the wording or list the phrase in UNPARSED_OK. "
                         f"Message: {msg[:120]}")
    return deps


def switch_settings(line: str) -> dict:
    """{switch: value} for every set_sw/set_sw_in call on one line."""
    out = {}
    for m in re.finditer(r'set_sw(?:_in)?\s+(?:"\$\w+"\s+)?(CT_EN_[A-Z0-9_]+)\s+("?\$?\w+"?)',
                         line):
        out[m.group(1)] = m.group(2).strip('"')
    return out


def check_script(path: Path, deps: dict) -> None:
    rel = path.relative_to(REPO).as_posix()
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    # A "leg" is a shell function body or, outside functions, the whole file:
    # a profile is usually assembled over several consecutive lines.
    leg_start = 0
    legs = []
    for i, line in enumerate(lines):
        if re.match(r"^\s*\w+\s*\(\)\s*\{", line) or re.match(r"^\}", line):
            legs.append((leg_start, i))
            leg_start = i
    legs.append((leg_start, len(lines)))

    for start, end in legs:
        settings = {}
        first_line = {}
        for i in range(start, end):
            for sw, val in switch_settings(lines[i]).items():
                settings[sw] = val
                first_line.setdefault(sw, i + 1)
        for dependent, pairs in deps.items():
            for needed, src in pairs:
                if settings.get(needed) != "0":
                    continue      # the dependency is not switched off here
                got = settings.get(dependent)
                if got is None:
                    fail(f"{rel}:{first_line[needed]}: sets {needed} = 0 but never "
                         f"{dependent} -- elaboration $fatal in {src}")
                elif got != "0":
                    fail(f"{rel}:{first_line[dependent]}: {dependent} = {got} while "
                         f"{needed} = 0 -- elaboration $fatal in {src}")


def main() -> int:
    deps = collect_dependencies()
    if not deps:
        print("  [FAIL] no `CT_EN_x requires CT_EN_y` elaboration guard found "
              "in the RTL -- the guard has nothing to check, which is itself "
              "a regression")
        return 1
    found = {(dependent, needed)
             for dependent, pairs in deps.items() for needed, _ in pairs}
    for dependent, needed in sorted(EXPECTED_DEPS - found):
        fail(f"expected dependency {dependent} -> {needed} is no longer "
             f"readable from the RTL. Either the elaboration $fatal was "
             f"reworded (restore `{dependent} requires {needed}`) or the "
             f"guard was removed on purpose (then drop the pair from "
             f"EXPECTED_DEPS in the same change).")
    scripts = [p for p in sorted(SCRIPT_DIR.glob("*.sh"))
               if p.name not in SKIP_SCRIPTS]
    checked = 0
    for p in scripts:
        text = p.read_text(encoding="utf-8", errors="replace")
        if "set_sw" not in text:
            continue
        checked += 1
        check_script(p, deps)
    if failures:
        for f_ in failures:
            print(f_)
        print(f"[check_profile_deps] {len(failures)} failure(s)")
        return 1
    n_pairs = sum(len(v) for v in deps.values())
    print(f"[check_profile_deps] OK: {n_pairs} elaboration dependency(ies) "
          f"({', '.join(f'{k}->{n}' for k, v in sorted(deps.items()) for n, _ in v)}) "
          f"honoured in {checked} profile script(s); "
          f"{len(EXPECTED_DEPS)} expected pair(s) present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
