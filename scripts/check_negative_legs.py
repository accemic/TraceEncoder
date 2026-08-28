#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Every build switch with an RDL profile override needs a compiled-out leg.

Global acceptance criterion 7 of the capability-gaps programme asks for a
negative test per new enable. Two kinds exist and they prove different
things:

  * the RUNTIME negative -- feature compiled IN, runtime bit off. Cheap,
    and every package has one.
  * the COMPILED-OUT negative -- the switch at 0, RDL profile regenerated.
    This is the only thing that exercises the `CT_PROFILE_NO_<X>` override
    in rdl/ct_cs_cpuif.rdl: that the field really reads 0, that a write
    does not stick, and that the CSR answers instead of faulting.

The second kind was forgotten twice in a row, by two different packages,
and both times an auditor found it (P9 finding F2, P7 finding B-1) -- the
same gap, discovered independently. Nothing in the tree made the omission
visible, because a missing test is invisible by nature.

So it is made visible here: `gen_rdl_profile.py` knows every switch that
has a profile override, and every one of them must appear below either
with its compiled-out leg or with a WAIVED reason. A new switch that has
neither is a failure naming both ways out. That is the whole point -- the
guard does not decide whether a leg is worth writing, it only makes the
decision explicit and dated.

Exit 0 = every profile switch is accounted for, 1 = at least one is not.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROFILE_MAP = REPO / "scripts" / "gen_rdl_profile.py"

# switch -> (script, how to run it, a string the script must contain)
NEGATIVE_LEGS = {
    "CT_EN_TRIG_REGS": (
        "scripts/cli_trigregs_test.sh", "bash scripts/cli_trigregs_test.sh ro",
        "compiled-out RO probes: OK"),
    "CT_EN_DF_DROP": (
        "scripts/cli_dfdrop_test.sh", "bash scripts/cli_dfdrop_test.sh ro",
        "compiled-out RO probe: DataDropEna refused"),
}

# Compiled-out legs for switches that have NO RDL profile override, so the
# loop over `switches` below cannot find them (P8 closing audit C-N5). The leg
# exists, but nothing made its disappearance visible -- which is the exact gap
# this guard was written for, one category further out. Checked like
# NEGATIVE_LEGS and exempt from the stale sweep.
EXTRA_LEGS = {
    "CT_EN_INST_SYNC_REQ": (
        "scripts/cli_tesyncreq_test.sh", "bash scripts/cli_tesyncreq_test.sh ro",
        "NO SYNC = 14 with the feature out"),
    "CT_EN_AXIS_TS": (
        "scripts/cli_axists_test.sh", "bash scripts/cli_axists_test.sh ro",
        "AXIS TS compiled out: elem2 invalid + Strb 0xff -- PASS"),
}

# Switches without a compiled-out leg, each with the reason it is acceptable.
# A line here is a DECISION, not a claim of coverage -- keep the reason
# honest enough that a reviewer can disagree with it.
WAIVED = {
    # --- capability-gaps programme -------------------------------------
    "CT_EN_QUOTA_SYNC": (
        "P2: the OFF build is covered bit-exactly by the byte-neutrality "
        "family (the quota mode is unreachable there); no CSR field is "
        "turned read-only by the profile, only the counters vanish."),
    "CT_EN_DF_ADDR_COMPRESS": (
        "P3: the profile override legalises the compression enum to FULL, "
        "which the WARL probe in the XOR smoke test exercises with the "
        "feature compiled IN; a compiled-out leg is open backlog."),
    "CT_EN_DEVICE_ID": (
        "P4: open backlog -- the OFF side is covered by the byte-neutrality "
        "family, the read-only profile override is not exercised."),
    "CT_EN_WATCHPOINT_MSG": (
        "P4: open backlog -- as CT_EN_DEVICE_ID."),
    # --- pre-dating the rule -------------------------------------------
    # These switches existed before the compiled-out-negative rule was
    # written down (P9 audit F2, 2026-08-05). They are listed so the
    # backlog is countable, NOT because they are covered.
    "CT_EN_FILTERS": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_DATA_TRACE": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_ACT": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_IMPLICIT_RETURN": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_BP": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_JTC": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_REPEATED_HISTORY": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_REPEAT_BRANCH": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_WIDE_ICNT": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_TIMESTAMP": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_IBHS": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_REPEAT_INSTR": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_TRIG_SYNC": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_SEQ_SYNC": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_OWNERSHIP": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_CONFIG_MSG": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_SYNC_STATUS": "legacy: pre-dates the rule; no compiled-out leg.",
    "CT_EN_FIFO_HIST": "legacy: pre-dates the rule; no compiled-out leg.",
}

MAP_RE = re.compile(r'^\s*"(CT_EN_[A-Z0-9_]+)"\s*:\s*"(CT_PROFILE_NO_[A-Z0-9_]+)"',
                    re.M)


def main() -> int:
    text = PROFILE_MAP.read_text(encoding="utf-8", errors="replace")
    switches = dict(MAP_RE.findall(text))
    if not switches:
        print("  [FAIL] no CT_EN_* -> CT_PROFILE_NO_* mapping found in "
              f"{PROFILE_MAP.relative_to(REPO).as_posix()} -- this guard has "
              "nothing to check, which is itself a regression")
        return 1

    failures = []

    def check_leg(sw, entry):
        script, how, marker = entry
        path = REPO / script
        if not path.is_file():
            failures.append(f"  [FAIL] {sw}: compiled-out leg {script} is gone")
            return
        if marker not in path.read_text(encoding="utf-8", errors="replace"):
            failures.append(
                f"  [FAIL] {sw}: {script} no longer contains the leg's "
                f"verdict marker {marker!r} -- the compiled-out negative "
                f"was removed or renamed (run: {how})")

    for sw, entry in sorted(EXTRA_LEGS.items()):
        check_leg(sw, entry)

    for sw in sorted(switches):
        if sw in NEGATIVE_LEGS:
            check_leg(sw, NEGATIVE_LEGS[sw])
            continue
        if sw in WAIVED:
            continue
        failures.append(
            f"  [FAIL] {sw} has an RDL profile override ({switches[sw]}) but "
            f"no compiled-out negative and no waiver. Either add the leg "
            f"(pattern: `bash scripts/cli_trigregs_test.sh ro` -- switch at 0, "
            f"RDL profile regenerated, the field must read back 0 and the "
            f"feature must produce nothing) and register it in NEGATIVE_LEGS, "
            f"or add a WAIVED entry saying why not. Silence is what let this "
            f"gap through twice (P9 F2, P7 B-1).")

    stale = sorted((set(NEGATIVE_LEGS) | set(WAIVED)) - set(switches))
    for sw in stale:
        failures.append(
            f"  [FAIL] {sw} is registered here but no longer has a profile "
            f"override -- drop the entry together with the switch")

    if failures:
        print("\n".join(failures))
        print(f"[check_negative_legs] {len(failures)} failure(s)")
        return 1
    print(f"[check_negative_legs] OK: {len(switches)} profile switch(es); "
          f"{len(NEGATIVE_LEGS)} with a compiled-out negative leg, "
          f"{len(WAIVED)} waived with a reason; plus {len(EXTRA_LEGS)} leg(s) "
          f"for switch(es) without a profile override")
    return 0


if __name__ == "__main__":
    sys.exit(main())
