#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P7 resource cost: OOC synthesis pair for CT_EN_TRIG_REGS / CT_EN_DF_DROP.
# Both legs run in a DETACHED WORKTREE -- never flip profile switches in the
# working tree (a parallel formal/mint/sim gate reads them).
#   on  : the committed full profile
#   off : the same profile with the two P7 switches at 0 (RDL profile
#         regenerated, so the CSR block loses the fields as well)
# The tcl always writes bld/synth_ooc/util_flat.rpt, which the NEXT run
# overwrites; each leg is therefore copied to bld/p7_ooc_<tag>_util_*.rpt in
# the MAIN tree (P4 audit finding B-2: a documentation reference must point at
# a per-run file, not at a path that the next run replaces).
#   usage: bash scripts/p7_ooc_pair.sh [worktree-path] [part]
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${1:-${CT_WORKTREE_ROOT:-$(dirname "$repo")/ctte_worktrees}/p7_ooc}"
PART="${2:-xck26-sfvc784-2LV-c}"
LOG="$repo/bld/p7_ooc_driver.log"
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
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
vivado_bin="$(command -v vivado || echo vivado)"

run_leg () { # $1 = tag, $2 = switch value
	set_sw CT_EN_TRIG_REGS "$2"
	set_sw CT_EN_DF_DROP   "$2"
	"$PYRDL" scripts/gen_rdl_profile.py --pkg "$WT/rtl/pkg/ct_pkg.sv" \
		--rdl-dir "$WT/rdl" --out-dir "$WT/rtl/pkg" >>"$LOG" 2>&1 \
		|| { say "$1: FAIL profile regen"; return 1; }
	say "run $1 (CT_EN_TRIG_REGS=$2 CT_EN_DF_DROP=$2, profile defines: $(grep -c '^`define' "$WT/rdl/ct_profile.inc.rdl"))"
	grep -nE "localparam bit CT_EN_(TRIG_REGS|DF_DROP) " "$WT/rtl/pkg/ct_pkg.sv" | tee -a "$LOG"
	( cd "$WT" && "$vivado_bin" -mode batch -nojournal -nolog \
		-source scripts/synth_encoder_ooc.tcl -tclargs "$PART" ) \
		> "$repo/bld/p7_ooc_$1.log" 2>&1
	if [ -f "$WT/bld/synth_ooc/util_flat.rpt" ]; then
		cp "$WT/bld/synth_ooc/util_flat.rpt" "$repo/bld/p7_ooc_$1_util_flat.rpt"
		[ -f "$WT/bld/synth_ooc/util_hier.rpt" ] && cp "$WT/bld/synth_ooc/util_hier.rpt" "$repo/bld/p7_ooc_$1_util_hier.rpt"
		grep -E "CLB LUTs\*|CLB Registers|Register as Flip Flop" "$repo/bld/p7_ooc_$1_util_flat.rpt" \
			| sed "s/^/--- $1: /" | tee -a "$LOG"
		rm -f "$WT/bld/synth_ooc/util_flat.rpt" "$WT/bld/synth_ooc/util_hier.rpt"
	else
		say "$1: NO REPORT -- see bld/p7_ooc_$1.log"; return 1
	fi
}

rc=0
run_leg off 0 || rc=1
run_leg on  1 || rc=1
say "done (rc=$rc)"
exit $rc
