#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P8 resource cost: OOC synthesis pair for CT_EN_INST_SYNC_REQ.
# Both legs run in a DETACHED WORKTREE -- never flip profile switches in the
# working tree (a parallel formal/mint/sim gate reads them).
#   on  : the committed full profile
#   off : the same profile with the P8 switch at 0
# No RDL profile regeneration: P8 adds no CT_PROFILE_NO_* define (D-P8-8),
# so both legs synthesize the SAME committed CSR block and the delta is
# exactly the encoder-side logic. (Regenerating in a worktree would also hit
# the silent PATH-peakrdl fallback -- see scripts/p8_off_neutrality.sh.)
# The tcl always writes bld/synth_ooc/util_flat.rpt, which the NEXT run
# overwrites; each leg is therefore copied to bld/p8_ooc_<tag>_util_*.rpt in
# the MAIN tree (P4 audit finding B-2: a documentation reference must point at
# a per-run file, not at a path that the next run replaces).
#   usage: bash scripts/p8_ooc_pair.sh [both|off|on] [worktree-path] [part]
# A single leg can be repeated on its own: Vivado occasionally fails to read
# its own realtime tcl under parallel load ("couldn't read file
# .Xil/.../realtime\ct_encoder.tcl: invalid argument", seen 2026-08-05 with
# a simulation battery on the same machine), and that is a tool hiccup, not a
# result -- the leg is simply repeated.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
LEGS="${1:-both}"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${2:-${CT_WORKTREE_ROOT:-$(dirname "$repo")/ctte_worktrees}/p8_ooc}"
PART="${3:-xck26-sfvc784-2LV-c}"
LOG="$repo/bld/p8_ooc_driver_${LEGS}.log"
: > "$LOG"
say () { echo "=== $(date +%H:%M:%S) $*" | tee -a "$LOG"; }

head="$(git rev-parse --short HEAD)"
if [ ! -d "$WT" ]; then
	git worktree add --detach "$WT" "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree add"; exit 3; }
else
	git -C "$WT" checkout -f "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree checkout"; exit 3; }
fi
say "worktree $WT at $(git -C "$WT" rev-parse --short HEAD), part $PART"

set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$WT/rtl/pkg/ct_pkg.sv"; }

# Vivado 2022.1 as pinned in .abc.config (ct_env.sh discovery).
. "$repo/scripts/ct_env.sh"
ct_need_vivado
vivado_bin="$(command -v vivado || echo vivado)"

run_leg () { # $1 = tag, $2 = switch value
	set_sw CT_EN_INST_SYNC_REQ "$2"
	say "run $1 (CT_EN_INST_SYNC_REQ=$2)"
	grep -nE "localparam bit CT_EN_INST_SYNC_REQ " "$WT/rtl/pkg/ct_pkg.sv" | tee -a "$LOG"
	( cd "$WT" && "$vivado_bin" -mode batch -nojournal -nolog \
		-source scripts/synth_encoder_ooc.tcl -tclargs "$PART" ) \
		> "$repo/bld/p8_ooc_$1.log" 2>&1
	if [ -f "$WT/bld/synth_ooc/util_flat.rpt" ]; then
		cp "$WT/bld/synth_ooc/util_flat.rpt" "$repo/bld/p8_ooc_$1_util_flat.rpt"
		[ -f "$WT/bld/synth_ooc/util_hier.rpt" ] && cp "$WT/bld/synth_ooc/util_hier.rpt" "$repo/bld/p8_ooc_$1_util_hier.rpt"
		grep -E "CLB LUTs\*|CLB Registers|Register as Flip Flop" "$repo/bld/p8_ooc_$1_util_flat.rpt" \
			| sed "s/^/--- $1: /" | tee -a "$LOG"
		rm -f "$WT/bld/synth_ooc/util_flat.rpt" "$WT/bld/synth_ooc/util_hier.rpt"
	else
		say "$1: NO REPORT -- see bld/p8_ooc_$1.log"; return 1
	fi
}

rc=0
case "$LEGS" in
	both) run_leg off 0 || rc=1; run_leg on 1 || rc=1 ;;
	off)  run_leg off 0 || rc=1 ;;
	on)   run_leg on  1 || rc=1 ;;
	*)    say "unknown leg selection: $LEGS"; exit 2 ;;
esac
say "done (rc=$rc)"
exit $rc
