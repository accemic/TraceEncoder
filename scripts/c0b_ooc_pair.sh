#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# C0b resource cost: OOC synthesis pair for the watchpoint scaling step
# (M0_DIM 4 -> 10, 1023 slots, indirect load path). Unlike the switch-flip
# pairs (p7/p8) this one measures TWO COMMITTED TREES -- the committed full
# profile before and after C0b -- because the dimension is a localparam,
# not a CT_EN_* switch:
#   pre  : the C0a endpoint (M0_DIM = 4, direct 0x4100 window)
#   post : the C0b head    (M0_DIM = 10, indirect trWpIndex/trWpData* path)
# Both legs run in a DETACHED WORKTREE (never the tree under test); each
# util report is copied to bld/c0b_ooc_<tag>_util_*.rpt in the calling tree
# (per-run files -- the tcl output path is overwritten by the next run).
#   usage: bash scripts/c0b_ooc_pair.sh <pre-commit> <post-commit> \
#              [worktree-path] [part]
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
PRE="${1:?pre commit (C0a endpoint)}"
POST="${2:?post commit (C0b head)}"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${3:-${CT_WORKTREE_ROOT:-$(dirname "$repo")/ctte_worktrees}/c0b_ooc_meas}"
PART="${4:-xck26-sfvc784-2LV-c}"
LOG="$repo/bld/c0b_ooc_driver.log"
mkdir -p "$repo/bld"
: > "$LOG"
say () { echo "=== $(date +%H:%M:%S) $*" | tee -a "$LOG"; }

if [ ! -d "$WT" ]; then
	git worktree add --detach "$WT" "$PRE" >>"$LOG" 2>&1 || { say "FAIL: worktree add"; exit 3; }
fi

# Vivado 2022.1 as pinned in .abc.config (ct_env.sh discovery).
. "$repo/scripts/ct_env.sh"
ct_need_vivado
vivado_bin="$(command -v vivado || echo vivado)"

run_leg () { # $1 = tag, $2 = commit
	git -C "$WT" checkout -f "$2" >>"$LOG" 2>&1 || { say "$1: FAIL checkout $2"; return 1; }
	say "run $1 at $(git -C "$WT" rev-parse --short HEAD) (M0_DIM: $(grep -oE 'localparam int M0_DIM[[:space:]]*=[[:space:]]*[0-9]+' "$WT/rtl/pkg/ct_pkg.sv"))"
	( cd "$WT" && "$vivado_bin" -mode batch -nojournal -nolog \
		-source scripts/synth_encoder_ooc.tcl -tclargs "$PART" ) \
		> "$repo/bld/c0b_ooc_$1.log" 2>&1
	if [ -f "$WT/bld/synth_ooc/util_flat.rpt" ]; then
		cp "$WT/bld/synth_ooc/util_flat.rpt" "$repo/bld/c0b_ooc_$1_util_flat.rpt"
		[ -f "$WT/bld/synth_ooc/util_hier.rpt" ] && cp "$WT/bld/synth_ooc/util_hier.rpt" "$repo/bld/c0b_ooc_$1_util_hier.rpt"
		grep -E "CLB LUTs\*|CLB Registers|Register as Flip Flop|Block RAM Tile" "$repo/bld/c0b_ooc_$1_util_flat.rpt" \
			| sed "s/^/--- $1: /" | tee -a "$LOG"
		rm -f "$WT/bld/synth_ooc/util_flat.rpt" "$WT/bld/synth_ooc/util_hier.rpt"
	else
		say "$1: NO REPORT -- see bld/c0b_ooc_$1.log"; return 1
	fi
}

rc=0
run_leg pre  "$PRE"  || rc=1
run_leg post "$POST" || rc=1
say "done rc=$rc (reports: bld/c0b_ooc_{pre,post}_util_flat.rpt)"
exit $rc
