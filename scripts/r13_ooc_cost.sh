#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# R1.3 resource cost of the block ingress: OOC synthesis of ct_encoder with
# CT_EN_BLOCK_TIP = 0 (the committed default, i.e. the pre-R1.3 netlist) and
# = 1, same tool, same part, same commit. Both legs run in DETACHED
# WORKTREES so neither touches the working tree.
#
# The OFF leg is not a formality: the derivations in tip_pkg are localparam
# ternaries, so the claim is that the OFF netlist is IDENTICAL, not merely
# cheap. An OFF number that differs from the pre-R1.3 baseline would be a
# finding, and this is where it would show.
#
#   usage: bash scripts/r13_ooc_cost.sh [part]
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
PART="${1:-xck26-sfvc784-2LV-c}"
head="$(git rev-parse --short HEAD)"
echo "[r13-ooc] HEAD $head, part $PART"

run_leg () { # $1 = 0|1, $2 = worktree
	local sw="$1" wt="$2"
	if [ ! -d "$wt" ]; then
		git worktree add --detach "$wt" "$head" >/dev/null 2>&1 || { echo "SKIP: worktree $wt"; return 77; }
	else
		git -C "$wt" checkout -f "$head" >/dev/null 2>&1 || { echo "SKIP: checkout $wt"; return 77; }
	fi
	sed -i -E "s/(localparam bit CT_EN_BLOCK_TIP = )[01];/\1${sw};/" "$wt/rtl/pkg/ct_pkg.sv"
	grep -qE "localparam bit CT_EN_BLOCK_TIP = ${sw};" "$wt/rtl/pkg/ct_pkg.sv" \
		|| { echo "FAIL: switch flip to $sw did not take"; return 3; }
	echo "[r13-ooc] leg CT_EN_BLOCK_TIP=$sw in $wt"

	# Both report paths are cleared BEFORE the run, so "the file is there"
	# can only mean "this run wrote it". Measured 2026-08-13 on the state
	# this script was in: with a synthesis that produced no report at all,
	# the unchecked `cp` below failed, `echo` set the function's status back
	# to 0, `|| exit $?` never fired -- and the summary printed the util
	# numbers of a run from 2026-08-09 (26283 / 27578 CLB LUTs) as this
	# run's result, rc=0. Resource numbers are exactly what the doc-evidence
	# guard makes documentation quote, so a stale one does not stay local.
	# Clearing beats a timestamp comparison: it has no clock semantics and
	# cannot mistake a fast run for an old file.
	local rpt="$wt/bld/synth_ooc/util_flat.rpt"
	local out="$here/bld/r13_ooc_${sw}_util_flat.rpt"
	rm -f "$rpt" "$out"

	( cd "$wt" && vivado -mode batch -nojournal -nolog \
		-source scripts/synth_encoder_ooc.tcl -tclargs "$PART" ) \
		> "$here/bld/r13_ooc_${sw}.log" 2>&1
	if ! grep -q "^OK" "$here/bld/r13_ooc_${sw}.log"; then
		echo "FAIL: synthesis did not finish (see bld/r13_ooc_${sw}.log)"; return 4
	fi
	[ -s "$rpt" ] || {
		echo "FAIL: synthesis said OK but wrote no $rpt -- no numbers for leg $sw"
		return 5; }
	cp "$rpt" "$out" || { echo "FAIL: cannot copy $rpt to $out"; return 6; }
	echo "[r13-ooc] leg $sw done"
}

# Scratch worktrees: a "ctte_worktrees" directory next to the repository
# by default, overridable with CT_WORKTREE_ROOT.
wtroot="${CT_WORKTREE_ROOT:-$(dirname "$here")/ctte_worktrees}"
run_leg 0 "$wtroot/r13_ooc_off" || exit $?
run_leg 1 "$wtroot/r13_ooc_on"  || exit $?

echo "======================================================"
# The loop used to be the last statement of the script, so the process status
# was `head`'s -- 0 whatever the greps found. It reports now.
rc=0
for sw in 0 1; do
	echo "--- CT_EN_BLOCK_TIP=$sw ---"
	if [ ! -s "$here/bld/r13_ooc_${sw}_util_flat.rpt" ]; then
		echo "FAIL: no utilization report for leg $sw"; rc=1; continue
	fi
	grep -E "CLB LUTs|CLB Registers|Block RAM Tile|DSPs|CARRY8" \
		"$here/bld/r13_ooc_${sw}_util_flat.rpt" | head -8
done
exit "$rc"
