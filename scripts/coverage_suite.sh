#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Verilator line coverage over the WHOLE test suite:
# every .abc sim task (instruction 01-18, data, overflow, hsi, combined,
# lib decoder TB, rtl unit TBs) runs under `abc --sim-backend verilator
# --coverage`; afterwards scripts/coverage_report.sh merges every
# bld/*.vsim/coverage_*.dat into one union line-coverage rate
# (bld/coverage/merged.info + annotated sources per test dir).
#
# Windows notes (this workstation):
#   - verilator via MSYS2 ucrt64; verilator.exe/verilator_coverage.exe are
#     local copies of verilator_bin.exe / _coverage_bin_dbg.exe (the
#     no-extension perl wrappers were renamed *.pl -- shutil.which would
#     pick them and CreateProcess can't start them).
#   - VERILATOR_ROOT must be the Windows path of the msys share dir.
#   - abc = abc-flow github-main + local patches: core.py (bash for
#     abc-export) and verilator.py (ABC_VERILATOR_EXTRA_ARGS passthrough, for
#     example -fno-inline to work around the 5.040 codegen bug "jump to label
#     crosses initialization" during task inlining -- see robustness_tb).
#   - /c/msys64/usr/bin must NOT be prepended: its msys2-runtime coreutils
#     (timeout, bash) would then sit in the Git-bash->abc->verilator chain
#     and mangle the environment across the runtime boundary (VERILATOR_ROOT
#     C:/msys64/... -> /ucrt64/..., TMP dropped -> g++ "Cannot create
#     temporary file in C:\WINDOWS\"), and shutil.which('bash') would pick
#     the msys64 bash for abc-export, whose OWN HOME gitconfig lacks the
#     safe.directory exception -> `git -C <testdir> rev-parse` fails ->
#     abc_collector_detect_root falls back to the test dir -> every
#     @-anchored import "goes missing". Git-for-Windows provides timeout,
#     bash and git with the Windows HOME (safe.directory covered there).
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
ct_need_abc
# MSYS2's Verilator needs a native Windows VERILATOR_ROOT (see the Windows
# notes above); on Linux the binary's built-in default applies.
if [ "${OS:-}" = "Windows_NT" ]; then
	export VERILATOR_ROOT="${VERILATOR_ROOT:-C:/msys64/ucrt64/share/verilator}"
fi
LOG="bld/coverage_suite.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

TASKS=$(ls tests/instruction/*/[a-z]*.abc tests/data/*/[a-z]*.abc \
		   tests/overflow/*/[a-z]*.abc tests/hsi/*/[a-z]*.abc \
		   tests/combined/*/[a-z]*.abc tests/lib/test/*.abc \
		   rtl/test/*.abc rtl/mseo_mdo/test/*_tb.abc 2>/dev/null)

fails=0; n=0
for task in $TASKS; do
	n=$((n+1)); name="$(basename "$task" .abc)"
	# Resumable: a finished task left its log — skip it (delete
	# bld/cov_*.log for a full re-run). Guards against re-running ~4-min
	# tasks after a mid-suite abort.
	if [ -s "bld/cov_${name}.log" ] && grep -q "Total coverage" "bld/cov_${name}.log"; then
		say "cov $name: SKIP (already run)"
		continue
	fi
	# Hard per-task timeout: one abc/verilator hang must not stall the
	# whole suite (observed 2026-07-20: verilator idle-hung ~1 h on
	# repeat_branch_tb; 15 min is ~3x the slowest healthy task).
	# robustness_tb needs -fno-inline: Verilator 5.040 emits "jump to
	# label crosses initialization" C++ when inlining cpu_model tasks
	# into this TB's initial coroutine (g++ hard error; -fpermissive
	# does NOT downgrade it). Passed via the local abc-flow
	# verilator.py ABC_VERILATOR_EXTRA_ARGS patch.
	extra=""
	[ "$name" = "robustness_tb" ] && extra="-fno-inline"
	( cd bld && ABC_VERILATOR_EXTRA_ARGS="$extra" timeout 900 \
		abc --sim-backend verilator --coverage -sim "../$task" ) \
		> "bld/cov_${name}.log" 2>&1
	rc=$?
	rate=$(grep -oE "Total coverage \([0-9]+/[0-9]+\) [0-9.]+%" "bld/cov_${name}.log" | tail -1)
	if [ $rc -eq 0 ] && grep -qE "\] PASS|PASS \(sim\)|All tests passed|\bPASS\b" "bld/cov_${name}.log"; then
		say "cov $name: PASS  ${rate:-}"
	elif [ $rc -eq 0 ]; then
		say "cov $name: DONE (no explicit PASS tag)  ${rate:-}"
	else
		say "cov $name: FAIL (rc=$rc)"; fails=$((fails+1))
		tail -3 "bld/cov_${name}.log" | sed 's/^/    /' | tee -a "$LOG"
	fi
done

say "=== merge ($n Tasks, $fails Fails) ==="
bash scripts/coverage_report.sh bld/coverage 2>&1 | tee -a "$LOG" | tail -5
say "=== FERTIG ==="
exit $fails
