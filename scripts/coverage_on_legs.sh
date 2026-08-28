#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Coverage ON-leg completion pass (AW directive 2026-07-21: maximise
# coverage). The plusarg-gated feature testbenches run their feature-OFF
# leg under the plain `abc --coverage` suite; every ON leg only ever ran
# through the cli_* check scripts (XSIM). This script re-runs the ALREADY
# BUILT Verilator executables directly with the ON plusargs, writing one
# coverage_<tb>_<leg>.dat per leg into the test's .vsim dir — which
# scripts/coverage_report.sh already globs into the union merge.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
LOG="bld/coverage_on_legs.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# Why this script counts and reports instead of just logging (2026-08-13):
#
# Until today it wrote SKIP/FAIL lines into the log and ENDED WITH 0 in every
# case -- the last statement was a `say`, whose status is tee's. Measured on
# this tree, where robustness_tb happened not to be built: 24 OK, 3 SKIP,
# rc=0. The union that scripts/coverage_report.sh then merges was missing
# three legs and nothing said so; the coverage percentage that comes out is a
# NUMBER, and an incomplete number is worse than a missing one, because a
# number gets quoted. That is the shape of the defect of 2026-08-12 (27 legs
# SKIPped, run green, coverage silently partial, full re-measurement lost).
#
# The resolution is "run everything, then say what was not run", not "abort at
# the first SKIP":
#   * aborting would throw away the 24 legs that DID run, and rebuilding a
#     Verilator testbench is minutes -- the incomplete state is worth keeping,
#     it just must not look complete;
#   * the summary line names the counts AND the skipped legs, so the log
#     answers "what is missing" without a diff against the leg list;
#   * the exit code separates the two causes, following the convention of
#     scripts/ct_env.sh (see docs FIX_gate_env_autarky):
#         0   every leg ran and produced its .dat
#         1   a leg RAN and produced nothing -- a real failure, debug it
#         78  a leg could not run at all (no executable) -- build it, the
#             CT_E_TOOL slot: "not performable", not "property violated"
#     If both happen, 1 wins: a leg that ran and produced nothing is the more
#     actionable defect. Both counts are printed either way.
# The sibling passes coverage_suite.sh / coverage_etrace.sh already end in
# `exit $fails`; this one was the only member of the family that did not.
n_ok=0
n_skip=0
n_fail=0
skipped=""
failed=""

run_leg () {
	local tb="$1"; shift
	local leg="$1"; shift
	local exe="bld/${tb}.vsim/obj_${tb}/${tb}.exe"
	if [ ! -x "$exe" ]; then
		say "$tb/$leg: SKIP (no executable)"
		n_skip=$((n_skip + 1))
		skipped="$skipped $tb/$leg"
		return
	fi
	local dat="coverage_${tb}_${leg}.dat"
	( cd "bld/${tb}.vsim" && timeout 600 "./obj_${tb}/${tb}.exe" "$@" \
		"+verilator+coverage+file+${dat}" ) > "bld/cov_leg_${tb}_${leg}.log" 2>&1
	local rc=$?
	if [ -s "bld/${tb}.vsim/${dat}" ]; then
		say "$tb/$leg: OK (rc=$rc)"
		n_ok=$((n_ok + 1))
	else
		say "$tb/$leg: FAIL rc=$rc (no ${dat})"
		n_fail=$((n_fail + 1))
		failed="$failed $tb/$leg"
	fi
}

run_leg implicit_return_tb  ir      +IMPLICIT_RETURN
run_leg implicit_return_tb  ts      +TIMESTAMPS
run_leg implicit_return_tb  irts    +IMPLICIT_RETURN +TIMESTAMPS
run_leg implicit_return_tb  nots    +NO_TSTAMP
run_leg repeated_history_tb rh      +REPEATED_HISTORY
run_leg repeated_history_tb rhw     +REPEATED_HISTORY +WIDE_ICNT
run_leg repeat_branch_tb    rb      +REPEAT_BRANCH
run_leg jtc_tb              jtc     +JTC
run_leg branch_predict_tb   bp      +BP
run_leg robustness_tb       hist    +ROBUST_HIST
run_leg robustness_tb       bp      +ROBUST_BP
run_leg robustness_tb       all     +ROBUST_ALL
run_leg ibhs_tb             on      +IBHS
run_leg repeat_instr_tb     on      +RPTI
run_leg trig_seq_own_tb     trig    +TRIGLEG
run_leg trig_seq_own_tb     seq     +SEQLEG
run_leg trig_seq_own_tb     own     +OWNLEG
run_leg config_msg_tb       none    +NONELEG
run_leg config_msg_tb       onsync  +ONSYNCLEG
run_leg config_msg_tb       bp      +BPLEG
run_leg config_msg_tb       bpneg   +BPNEGLEG
run_leg btm_tb              btm     +BTMLEG
# Gap-Closure-Legs (Worklist T1/W, 2026-07-21):
run_leg icnt_overflow_tb    btm     +BTMLEG
run_leg icnt_overflow_tb    bp      +BPLEG
run_leg repeated_history_tb rhp     +RH_PARTIAL
run_leg repeat_branch_tb    rbt     +RB_TIGHT
run_leg jtc_tb              jret    +JTC_RET

n_total=$((n_ok + n_skip + n_fail))
say "=== ON-legs done: $n_ok/$n_total OK, $n_skip skipped, $n_fail failed ==="
[ "$n_skip" -eq 0 ] || say "    SKIPPED (no executable -- the coverage union below is INCOMPLETE):$skipped"
[ "$n_fail" -eq 0 ] || say "    FAILED (ran, wrote no .dat):$failed"

# Both hints name the COVERAGE build on purpose. Measured 2026-08-13: a
# robustness_tb built with a plain `abc -sim` satisfies the -x test, runs to
# completion, exits 0 -- and writes no .dat at all, because that binary is
# compiled with -DVM_COVERAGE=0. "Executable present" and "executable usable
# here" are two different things, and the first FAIL of this kind cost a
# wrong diagnosis ("the leg is broken") before the build flags were read.
BUILD_HINT="build it the way coverage_suite.sh does:"
BUILD_HINT="$BUILD_HINT ( cd bld && abc --sim-backend verilator --coverage -sim ../<path>.abc )"
if [ "$n_fail" -gt 0 ]; then
	say "    verdict: FAIL -- $n_fail leg(s) produced no coverage data"
	say "    If the run itself looks clean, check the binary was built WITH coverage"
	say "    (a plain 'abc -sim' build has -DVM_COVERAGE=0 and writes no .dat): $BUILD_HINT"
	exit 1
fi
if [ "$n_skip" -gt 0 ]; then
	say "    verdict: TOOL (${CT_E_TOOL:-78}) -- $n_skip leg(s) had no executable."
	say "    $BUILD_HINT"
	say "    This is NOT a coverage result. Do not merge this union as complete."
	exit "${CT_E_TOOL:-78}"
fi
say "    verdict: OK -- all $n_total legs contributed coverage data"
exit 0
