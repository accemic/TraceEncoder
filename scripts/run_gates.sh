#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# The simulation gate battery: robustness gates, the compression byte-identity
# legs, the feature and width gates. The SVA invariants I1-I12 run along in
# every simulation. Needs Vivado XSIM -- NOT runnable on a stock CI runner.
#
#   bash scripts/run_gates.sh              # every gate in scripts/gates.list
#   GATES="natovf jtcovf" bash scripts/run_gates.sh   # a subset
#   COVERAGE=1 bash scripts/run_gates.sh   # + the Verilator coverage union
#
# The list of gates lives in scripts/gates.list, not here, because
# scripts/check_orphan_gates.py has to read the same list to prove every
# cli_*_test.sh in the tree is reachable.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
GATE_LIST="$here/scripts/gates.list"

# --------------------------------------------------------------------------
# One battery at a time.
#
# Every gate works in bld/<tb>.abc.vivado/.../xsim: it does `rm -rf xsim.dir`,
# re-elaborates a snapshot under a FIXED name, and copies artefacts out of the
# working directory. Two passes in the same tree therefore delete and rebuild
# each other's snapshots mid-run, and the damage does not look like damage --
# it looks like a property failure on whichever gate lost the race.
#
# Measured on 2026-08-09 (V2): three passes ran concurrently after a restart,
# offset by ~5 min. The evidence is in the per-leg logs, which xsim renames to
# <name>_<pid>.backup.log on every new run:
#
#   dfdrop    xsim_off.log      20:10 clean · 20:15 clean · 20:20 $fatal
#   tesyncreq xsim_cfonly.log   20:11 clean · 20:17 clean · 20:21 $fatal
#   status_pair xsim_did_cmp0   20:20 · 20:24 · 20:29   (three passes, one gate)
#
# Both gates pass in isolation (bld/v2_repro_dfdrop_tesyncreq.log). A FALSE RED
# is not the harmless direction of this mistake: it teaches people to re-run
# until green, which is how a true red gets ignored too.
#
# GATES_FORCE=1 overrides, loudly, for the case where the operator KNOWS the
# other pass is gone and the stale check did not notice.
# --------------------------------------------------------------------------
mkdir -p "$here/bld"
gates_lock="$here/bld/.gates.lock"
if [ -s "$gates_lock" ]; then
	other="$(cat "$gates_lock" 2>/dev/null)"
	if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
		if [ "${GATES_FORCE:-0}" = "1" ]; then
			echo "WARNING: gate pass $other still lives -- GATES_FORCE=1, running anyway."
			echo "         Any red below may be interference, not a property failure."
		else
			echo "REFUSED: another gate pass (pid $other) is running in this tree."
			echo "  Two passes share bld/ and produce false reds; see the header of"
			echo "  $0. Wait for it, or GATES_FORCE=1 if you know it is gone."
			exit 78
		fi
	else
		echo "note: taking over a stale gate lock (pid ${other:-?} is gone)"
	fi
fi
echo $$ > "$gates_lock"
trap 'rm -f "$gates_lock"' EXIT

# The list is data, not code: strip comments and blank lines, keep the order.
if [ ! -f "$GATE_LIST" ]; then
	echo "ERROR: $GATE_LIST not found -- the gate battery has no list to run." >&2
	exit 78
fi
default_gates="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$GATE_LIST" | tr -d '[:blank:]' | tr '\n' ' ')"
gates="${GATES:-$default_gates}"
if [ -z "${gates// /}" ]; then
	# An empty battery must never report success -- that is how a run that
	# executed nothing once produced a green verdict.
	echo "ERROR: empty gate list -- refusing to report a pass over nothing." >&2
	exit 78
fi
fail=0
declare -a results

for g in $gates; do
	echo "########## GATE: $g"
	timeout "${GATE_TIMEOUT:-1800}" bash "scripts/cli_${g}_test.sh"
	rc=$?
	# 77 = the gate skipped itself because an input it needs is not part of
	# this repository. A skip must never read as a pass in the summary.
	# 78 = the toolchain or the build tree could not be established
	# (ct_env.sh, CT_E_TOOL). Still a red run -- but naming it TOOL keeps a
	# missing Vivado from reading as a broken encoder, which is what
	# "donor prj missing" -> FAIL used to do on every fresh worktree.
	case $rc in
		0)  results+=("PASS  $g") ;;
		77) results+=("SKIP  $g") ;;
		78) results+=("TOOL  $g (toolchain/bootstrap, NOT a property failure)"); fail=1 ;;
		*)  results+=("FAIL  $g"); fail=1 ;;
	esac
done

if [ "${COVERAGE:-0}" = "1" ]; then
	echo "########## COVERAGE (Verilator-Union)"
	ABC_COV=1 make coverage || fail=1
fi

echo "========== GATE-SUMMARY =========="
printf '%s\n' "${results[@]}"
exit $fail
