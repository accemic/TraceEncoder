#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""A gate that runs a simulation must be able to see the simulation fail.

xsim exits 0 even when a testbench calls `$fatal`. The only trace of a fired
assertion is a line in the log. A gate whose verdict is "did NexRv decode it"
or "are the bytes identical" therefore cannot see an assertion that fires
WITHOUT corrupting the stream -- and those are the interesting ones. V1
counted the state on 2026-08-09: of the 29 xsim-driving gates, four looked at
that channel and 25 did not (docs/handoffs/V1_verification_infra.md §5.3a).

V2 answered that with one road rather than 25 patches: `ct_no_sva_errors` in
scripts/ct_env.sh, hung inside `ct_xsim_ok`, so every gate that starts a
simulation through ct_xsim has the check whether or not its author knew the
rule. This guard keeps the road the only road:

  1. The wiring itself. If `ct_xsim_ok` stopped calling `ct_no_sva_errors`,
     every gate below would still "use the shared path" and none of them
     would check anything. That is the exact shape of the bug this guard is
     about, one level up, so it is checked first and by content.
  2. Every cli gate that drives a simulation must reach the shared path
     (ct_xsim / ct_xsim_ok / ct_no_sva_errors).
  3. `xelab -R` runs its own simulation, and its `-log` holds the
     ELABORATION transcript only -- the run writes xsim.log in the working
     directory. Three gates grepped the elaboration log and could never see
     an $error (V2-F1). A gate that uses `xelab -R` must therefore name
     xsim.log in a ct_no_sva_errors call.
  3b. `abc -sim` is the THIRD way to start a simulation in this tree, and
     until 2026-08-13 this guard did not know it. It read cli_corexlen and
     cli_synccadence -- both of which simulate for real, on the committed
     Verilator backend -- as "starts no simulation" and demanded a waiver for
     them. That is the dangerous kind of wrong: a guard that reports two
     healthy gates red gets waived, and a waived guard is blind for
     EVERYONE. Both gates were in fact unchecked (their verdicts are byte
     counts, TCODE-8 counts and decoded PCs, so an assertion that fires
     without corrupting the stream was invisible), so the waiver would have
     cemented exactly the hole this guard exists to find.
     There is no ct_xsim wrapper on the abc route to hang the check on, so
     the rule is stated directly: a gate that drives `abc -sim` must call
     ct_no_sva_errors itself. Verilator's spelling is `%Error`/`%Fatal`,
     which CT_SVA_RE already carries.
  4. No hand-rolled detector. `grep -q "Error:" ...` as a condition is how
     the four gates that DID check were written; each spelled it slightly
     differently and none of them knew about "Fatal:" or Verilator's
     "%Error". Diagnostics that PRINT matching lines are fine -- what is
     forbidden is a second, private verdict.
  5. `CT_SVA_EXPECT=off` is the escape hatch for a leg whose errors are the
     point (a red control). Every occurrence is listed here with a reason,
     and the list is exact in both directions: an `off` that disappears also
     turns the guard red, so the waiver list cannot quietly outlive its
     reason.

Exit 0 = the channel is wired everywhere it must be, 1 = it is not.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"
CT_ENV = SCRIPTS / "ct_env.sh"

SHARED_CALL = re.compile(r"(?<![\w.-])(ct_xsim|ct_xsim_ok|ct_no_sva_errors)\b")
NO_SVA_CALL = re.compile(r"(?<![\w.-])ct_no_sva_errors\b([^\n]*)")
XELAB_R = re.compile(r"\bxelab\b[^\n]*(?:\s-R\b|\s-R$)")
DRIVES_XSIM = re.compile(r"(?<![\w.-])(ct_xsim|xsim(?:\.exe)?)\s+[-\w\"$]")
# The abc-flow route (rule 3b). `abc -sim <file>.abc` builds AND runs the
# testbench; with the committed sim_backend=verilator the transcript is the
# redirect of that very command, i.e. a log the gate names itself.
DRIVES_ABC_SIM = re.compile(r"(?<![\w.-])abc\b[^\n|]*\s-sim\b")
# Any grep used as a CONDITION on the severity words. Deliberately wider than
# "Error:"/"Fatal:" with the colon: the first version of this guard missed two
# further private spellings (`grep -qiE "^Error|Fatal: "` in fifohist,
# `grep -qE "^Error|ERROR:|..."` in blocktip) precisely because they punctuate
# differently. Six spellings in one tree is the argument for one road.
HAND_ROLLED = re.compile(r"\bgrep\b[^|\n]*\s-\w*q\w*\b[^|\n]*\b(Error|Fatal|error|fatal)\b")
# Tool-level greps that are NOT the SVA channel: a failed xvlog/xelab prints
# "ERROR: [VRFC ...]" and the gate wants to show it. Those inspect the
# COMPILER's log, never the simulation transcript.
HAND_ROLLED_OK = re.compile(r"\b(xvlog|xelab)\w*\.log\b")
OFF_MARK = re.compile(r"CT_SVA_EXPECT=off")

# ---------------------------------------------------------------------------
# Legs whose $error/$fatal lines are the RESULT, not a defect. Key is
# "<script>:<line-ish anchor>", value the reason a human checked.
# ---------------------------------------------------------------------------
OFF_WAIVERS = {
    "cli_i20_test.sh": (
        "mutation leg only: the I12 assertion firing IS the red counter-proof "
        "for the ICNT-cap fix, and the leg counts those lines itself "
        "(>=1 required). The three real legs keep the exact-zero expectation."
    ),
    "cli_syncreqrst_test.sh": (
        "red control: the retired one-cycle strobe MUST fail, and the gate's "
        "verdict is inverted ('the red control PASSED' is the failure). An "
        "exact count would pin the gate to an incidental 141."
    ),
}

# Gates that run no simulation of their own (they drive other gates, replay a
# stored capture, or only decode). Reason each, so the list stays readable.
NO_SIM_WAIVERS = {
    "cli_dfcompress_test.sh":  "byte-identity over stored captures, no simulator",
    "cli_dfworkload_test.sh":  "byte-identity over stored captures, no simulator",
    "cli_etrace_ctxp_test.sh": "decoder-only leg; the simulation is run by cli_etrace_test.sh",
    "cli_resyncir_test.sh":    "drives cli_etrace_test.sh, which owns the simulation",
    "cli_syncquota_test.sh":   "drives make sim-* targets; abc owns the simulation",
}


def read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def code(text: str) -> str:
    """The script without its whole-line comments.

    Not a shell parser -- it drops lines whose first non-blank character is
    '#'. That is enough here and it matters: without it, the sentence "xelab
    2022.1 does not accept -testplusarg, so -R cannot be used here" in
    cli_pausedge_test.sh reads as a `xelab -R` call, and the guard demands a
    check for a simulation that never happens. A guard that is wrong about
    what it sees teaches people to waive it.
    """
    return "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))


def main() -> int:
    fail = []
    notes = []

    # ---- 1. the wiring, by content ---------------------------------------
    env = read(CT_ENV)
    if not env:
        print("  [FAIL] scripts/ct_env.sh unreadable -- this guard judges nothing without it")
        return 1
    if "ct_no_sva_errors()" not in env:
        fail.append("  [FAIL] scripts/ct_env.sh no longer defines ct_no_sva_errors()")
    # ct_xsim_ok must CALL it, otherwise every gate below is green and blind.
    m = re.search(r"ct_xsim_ok\(\)\s*\{(.*?)\n\}", env, re.S)
    if not m:
        fail.append("  [FAIL] scripts/ct_env.sh: ct_xsim_ok() not found")
    elif "ct_no_sva_errors" not in m.group(1):
        fail.append(
            "  [FAIL] scripts/ct_env.sh: ct_xsim_ok() does not call ct_no_sva_errors. "
            "Every gate would still look wired and none would check the SVA channel.")
    # And the detector must know both backends' spellings.
    mre = re.search(r"^CT_SVA_RE=(.*)$", env, re.M)
    if not mre:
        fail.append("  [FAIL] scripts/ct_env.sh: CT_SVA_RE not found")
    else:
        pat = mre.group(1)
        for needed in ("Error", "Fatal", "%"):
            if needed not in pat:
                fail.append(f"  [FAIL] CT_SVA_RE no longer mentions {needed!r} -- "
                            f"xsim writes 'Error:'/'Fatal:', Verilator '%Error'")

    # ---- 2..5. the gates -------------------------------------------------
    gates = sorted(SCRIPTS.glob("cli_*.sh"))
    n_sim = 0
    off_seen = {}
    no_sim_seen = set()
    for g in gates:
        rel = g.name
        t = code(read(g))
        abc_sim = bool(DRIVES_ABC_SIM.search(t))
        drives = bool(DRIVES_XSIM.search(t)) or bool(XELAB_R.search(t)) or abc_sim

        if OFF_MARK.search(t):
            off_seen[rel] = len(OFF_MARK.findall(t))

        if not drives:
            no_sim_seen.add(rel)
            if rel in NO_SIM_WAIVERS:
                notes.append(f"  [NO-SIM] {rel}: {NO_SIM_WAIVERS[rel]}")
            else:
                fail.append(
                    f"  [FAIL] {rel} starts no simulation this guard can see. If that is "
                    f"right, record it in NO_SIM_WAIVERS with a reason; if it is wrong, "
                    f"the guard has gone blind and must be taught the new spelling.")
            continue
        n_sim += 1

        if not SHARED_CALL.search(t):
            fail.append(
                f"  [FAIL] {rel} drives a simulation but never reaches the shared SVA "
                f"path. Run it through ct_xsim (scripts/ct_env.sh), or call "
                f"ct_no_sva_errors on the log the run wrote. xsim exits 0 on $fatal.")

        if XELAB_R.search(t):
            logs = " ".join(m.group(1) for m in NO_SVA_CALL.finditer(t))
            if "xsim.log" not in logs:
                fail.append(
                    f"  [FAIL] {rel} uses `xelab -R` but no ct_no_sva_errors call names "
                    f"xsim.log. xelab's -log is the ELABORATION transcript; the run it "
                    f"spawns writes xsim.log. That is V2-F1 -- a check that cannot fire.")

        if abc_sim and not NO_SVA_CALL.search(t):
            fail.append(
                f"  [FAIL] {rel} drives `abc -sim` but never calls ct_no_sva_errors. "
                f"abc's Verilator backend runs the testbench and writes %Error/%Fatal "
                f"into the log the gate redirects; there is no ct_xsim wrapper on this "
                f"route, so the gate has to name that log itself.")

        hr = [ln.strip() for ln in t.splitlines()
              if HAND_ROLLED.search(ln) and not HAND_ROLLED_OK.search(ln)]
        for ln in hr:
            fail.append(
                f"  [FAIL] {rel}: hand-rolled SVA detector -- {ln[:70]}... "
                f"Use ct_no_sva_errors so every gate knows the same spellings "
                f"(xsim 'Error:'/'Fatal:', Verilator '%Error').")

    for rel in NO_SIM_WAIVERS:
        if rel not in no_sim_seen:
            if not (SCRIPTS / rel).exists():
                fail.append(f"  [FAIL] NO_SIM_WAIVERS names {rel}, which no longer exists -- "
                            f"drop the entry")
            else:
                fail.append(
                    f"  [FAIL] {rel} is in NO_SIM_WAIVERS but DOES drive a simulation now. "
                    f"Drop the entry in the same commit that gave it a simulation, so the "
                    f"list keeps meaning what it says.")

    for rel, n in sorted(off_seen.items()):
        if rel in OFF_WAIVERS:
            notes.append(f"  [OFF x{n}] {rel}: {OFF_WAIVERS[rel]}")
        else:
            fail.append(
                f"  [FAIL] {rel} uses CT_SVA_EXPECT=off without an entry in OFF_WAIVERS. "
                f"Switching the channel off is allowed; doing it unrecorded is not.")
    for rel in OFF_WAIVERS:
        if rel not in off_seen:
            fail.append(
                f"  [FAIL] OFF_WAIVERS names {rel}, which no longer uses CT_SVA_EXPECT=off "
                f"-- good news. Drop the entry in the same commit, so the list keeps "
                f"meaning what it says.")

    for n in notes:
        print(n)
    if fail:
        print("\n".join(fail))
        print(f"[check_sva_channel] {len(fail)} failure(s)")
        return 1
    print(f"[check_sva_channel] OK: {len(gates)} cli script(s), {n_sim} drive a simulation, "
          f"all on the shared SVA path; {len(off_seen)} recorded CT_SVA_EXPECT=off leg(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
