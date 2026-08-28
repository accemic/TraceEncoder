#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# X2a resource cost: out-of-context synthesis pair for the address width.
#
#   32 : the committed profile (ct_pkg::CT_XLEN = 32)
#   64 : the same profile with the knob at 64
#
# The delta is what widening the address path costs: the eTIP FIFO entry
# (every queued event carries an address), the comparator chain (twice the
# compare width), the JTC cache (64 entries x address width) and the Nexus
# message union / field arrays.
#
# Both legs run in a DETACHED WORKTREE -- never flip a profile switch in the
# working tree while another gate reads it (p8_ooc_pair.sh discipline). No
# RDL profile regeneration: CT_XLEN emits no CT_PROFILE_NO_* define, so both
# legs synthesize the SAME committed CSR block and the delta is the encoder
# logic alone.
#
# NOTE on the stimulus top: tests/lib/ct_encoder_top.sv drives the TIP
# address from an LFSR whose upper half only exists in a 64-bit build. That
# is deliberate -- a constant-zero upper half would let synthesis trim the
# entire upper datapath and the "64-bit" number would describe a 32-bit
# encoder.
#
# Reports are copied into the tree (verification/evidence/R1_1/<profile>_xlen<w>/),
# because a documented cost number whose report is not versioned is a number
# nobody can check (verification/evidence/README.md, scripts/check_doc_evidence.py).
#
#   usage: bash scripts/r11_ooc_xlen_pair.sh [both|32|64] [profile] [worktree] [part]
#          profile: a name ct_profiles.sh knows, or "committed" (default) to
#                   synthesize the tree's own switch set unchanged.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_profiles.sh"

LEGS="${1:-both}"
PROFILE="${2:-committed}"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${3:-${CT_WORKTREE_ROOT:-$(dirname "$repo")/ctte_worktrees}/r11_ooc}"
PART="${4:-xck26-sfvc784-2LV-c}"
EVID="$repo/verification/evidence/R1_1"
LOG="$repo/bld/r11_ooc_driver_${LEGS}.log"
mkdir -p "$repo/bld" "$EVID"
: > "$LOG"
say () { echo "=== $(date +%H:%M:%S) $*" | tee -a "$LOG"; }

head="$(git rev-parse --short HEAD)"
if [ ! -d "$WT" ]; then
	git worktree add --detach "$WT" "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree add"; exit 3; }
else
	git -C "$WT" checkout -f "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree checkout"; exit 3; }
fi
say "worktree $WT at $(git -C "$WT" rev-parse --short HEAD), part $PART, profile $PROFILE"

. "$repo/scripts/ct_env.sh"
ct_need_vivado
vivado_bin="$(command -v vivado || echo vivado)"

set_xlen () { sed -i -E "s/(localparam int unsigned CT_XLEN = )[0-9]+;/\1${1};/" "$WT/rtl/pkg/ct_pkg.sv"; }

run_leg () { # $1 = width
	local w="$1" tag dst
	tag="${PROFILE}_xlen${w}"
	dst="$EVID/$tag"
	git -C "$WT" checkout -f -- rtl/pkg/ct_pkg.sv >>"$LOG" 2>&1
	[ "$PROFILE" = committed ] || ct_profile_in "$WT/rtl/pkg/ct_pkg.sv" "$PROFILE" || return 2
	set_xlen "$w"
	say "run $tag"
	grep -nE "localparam int unsigned CT_XLEN = " "$WT/rtl/pkg/ct_pkg.sv" | tee -a "$LOG"
	( cd "$WT" && "$vivado_bin" -mode batch -nojournal -nolog \
		-source scripts/synth_encoder_ooc.tcl -tclargs "$PART" ) \
		> "$repo/bld/r11_ooc_$tag.log" 2>&1
	if [ ! -f "$WT/bld/synth_ooc/util_flat.rpt" ]; then
		say "$tag: NO REPORT -- see bld/r11_ooc_$tag.log"; return 1
	fi
	mkdir -p "$dst"
	cp "$WT/bld/synth_ooc/util_flat.rpt" "$dst/util_flat.rpt"
	[ -f "$WT/bld/synth_ooc/util_hier.rpt" ] && cp "$WT/bld/synth_ooc/util_hier.rpt" "$dst/util_hier.rpt"
	grep -E "CLB LUTs\*|CLB Registers|Register as Flip Flop|Block RAM Tile" "$dst/util_flat.rpt" \
		| sed "s/^/--- $tag: /" | tee -a "$LOG"
	rm -f "$WT/bld/synth_ooc/util_flat.rpt" "$WT/bld/synth_ooc/util_hier.rpt"
	return 0
}

rc=0
case "$LEGS" in
	both) run_leg 32 || rc=1; run_leg 64 || rc=1 ;;
	32)   run_leg 32 || rc=1 ;;
	64)   run_leg 64 || rc=1 ;;
	*)    say "unknown leg selection: $LEGS"; exit 2 ;;
esac
git -C "$WT" checkout -f -- rtl/pkg/ct_pkg.sv >>"$LOG" 2>&1
say "done (rc=$rc); reports in verification/evidence/R1_1/"
exit $rc
