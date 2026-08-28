#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P10-B: timing per build profile, out of context, at TWO clock budgets.
#
# The verification table asks for "no timing violation in the target
# configuration". Until now nothing in this tree measured it: every package
# OOC run used scripts/synth_encoder_ooc.tcl, which knows neither
# `create_clock` nor `report_timing`, and the only WNS figures in the
# documentation came from a placed-and-routed reference DESIGN of
# 2026-08-01 -- older than P2..P9. This driver runs the timing variant of
# the OOC script, once per profile and budget, and files the reports in the
# tree so a number can be followed back to a report (verification/evidence/README.md).
#
# Two budgets, because a slack figure without its budget means nothing:
#   75mhz   13.333 ns -- the board budget of the KV260 reference design,
#                        i.e. "slack in the target configuration";
#   200mhz  5.0 ns    -- headroom, and the budget phase_d_matrix_v2.sh used.
# Utilization is identical between the two runs of one profile by
# construction (the constraints are applied AFTER synth_design), which makes
# the second run a free reproducibility control on the synthesis itself.
#
# Profiles come from scripts/ct_profiles.sh -- the canonical definitions that
# phase_d_matrix_v2.sh also sources. Never hand-edit rtl/pkg/ct_pkg.sv for a
# measurement: the flip happens in a DETACHED WORKTREE, because a parallel
# formal/mint/sim gate reads the package in the working tree.
#
#   usage: bash scripts/p10_timing_matrix.sh [profile...]
#          CT_P10_WT=<path>     worktree to flip in
#          CT_P10_BUDGETS="75mhz:13.333 200mhz:5.0"
#
# Vivado tolerates no second vivado.exe on this machine (two concurrent
# synthesis runs die in "couldn't read file .../retarget_vhdl.tcl"), so the
# driver WAITS for a free slot instead of failing -- a package that gives up
# because somebody else was compiling produces no evidence at all.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
. "$repo/scripts/ct_profiles.sh"

# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${CT_P10_WT:-${CT_WORKTREE_ROOT:-$(dirname "$repo")/ctte_worktrees}/p10b_timing}"
PART="${CT_P10_PART:-xck26-sfvc784-2LV-c}"
BUDGETS="${CT_P10_BUDGETS:-75mhz:13.333 200mhz:5.0}"
PROFILES="${*:-$(ct_profile_names)}"
EVID="$repo/verification/evidence/P10"
LOG="$repo/bld/p10_timing_driver.log"
mkdir -p "$repo/bld" "$EVID"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# The commit every leg is measured at. It defaults to HEAD, but a matrix that
# takes an hour outlives a branch that other packages keep committing to, and
# a set of reports carrying two different stamps is exactly the finding this
# campaign collected twice (P4 audit B-1, P8 closing audit B-N2). Pin it, and
# re-runs land on the same tree as the first pass.
head="$(git rev-parse --short "${CT_P10_HEAD:-HEAD}")" || { echo "unknown commit ${CT_P10_HEAD:-HEAD}" >&2; exit 3; }
ct_need_python
ct_need_vivado
vivado_bin="$(command -v vivado || echo vivado)"
vivado_ver="$(ct_vivado_version)"
say "P10-B timing matrix: HEAD $head, Vivado $vivado_ver (pinned in .abc.config), part $PART"
say "profiles: $PROFILES | budgets: $BUDGETS"

if [ ! -d "$WT" ]; then
	git worktree add --detach "$WT" "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree add"; exit 3; }
fi

# Wait for the single Vivado slot. Windows only knows tasklist here; on any
# other host the check is a no-op and the caller serializes.
wait_for_vivado_slot () {
	local waited=0
	command -v tasklist >/dev/null 2>&1 || return 0
	while tasklist //FI "IMAGENAME eq vivado.exe" 2>/dev/null | grep -q vivado.exe; do
		[ "$waited" -eq 0 ] && say "vivado.exe is busy -- waiting for the slot (not aborting)"
		sleep 30; waited=$((waited + 30))
		[ $((waited % 300)) -eq 0 ] && say "  still waiting ($((waited / 60)) min)"
	done
	[ "$waited" -gt 0 ] && say "slot free after $((waited / 60)) min $((waited % 60)) s"
	return 0
}

# WNS of the "Design Timing Summary" block: the first floating-point column
# of the first data row. Read from the REPORT, never from the driver's own
# arithmetic -- a number in a handoff has to be findable in a file.
wns_of () { awk '/Design Timing Summary/{f=1} f && $1 ~ /^-?[0-9]+\.[0-9]+$/ {print $1; exit}' "$1"; }
# Row label match on the TRIMMED cell, not on a fixed indentation: the report
# indents "Register as Flip Flop" by three spaces as a sub-row of
# "CLB Registers", and "CLB Registers" counts latches too (P9 audit F7).
util_of () { awk -F'|' -v want="$2" '/^\|/ { l=$2; gsub(/^[ \t]+|[ \t]+$/,"",l); v=$3; gsub(/[ \t]/,"",v); if (l==want) { print v; exit } }' "$1"; }

rc=0
# One synthesis leg. .Xil goes with the previous run's output: Vivado keeps
# its realtime scripts there and a leftover directory is what the "invalid
# argument" hiccup reads from.
synth_leg () { # $1 profile, $2 budget tag, $3 period in ns
	wait_for_vivado_slot
	say "$1 @ $2 ($3 ns): synthesizing"
	( cd "$WT" && rm -rf bld/synth_ooc_t .Xil \
	  && "$vivado_bin" -mode batch -nojournal -nolog \
	     -source scripts/synth_encoder_ooc_timing.tcl -tclargs "$PART" "$3" ) \
	     > "$repo/bld/p10_${1}_${2}.log" 2>&1
}

run_profile () {
	local prof="$1" tag ns out
	say "=== profile $prof ==="
	git -C "$WT" checkout -f "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree checkout"; return 3; }
	ct_profile_in "$WT/rtl/pkg/ct_pkg.sv" "$prof" || return 2
	( cd "$WT" && python scripts/gen_rdl_profile.py ) >>"$LOG" 2>&1 \
		|| { say "$prof: FAIL -- gen_rdl_profile.py"; return 4; }
	# What the profile actually changed, in the log, so the run is auditable.
	git -C "$WT" diff --stat -- rtl/pkg >>"$LOG" 2>&1
	say "$prof: ct_pkg switches differing from the committed full profile: $(git -C "$WT" diff -U0 -- rtl/pkg/ct_pkg.sv | grep -c '^+\s*localparam')"

	mkdir -p "$EVID/$prof"
	for spec in $BUDGETS; do
		tag="${spec%%:*}"; ns="${spec##*:}"
		out="$WT/bld/synth_ooc_t"
		synth_leg "$prof" "$tag" "$ns"
		# One retry: Vivado intermittently cannot read its own realtime tcl
		# out of .Xil ("invalid argument") when a run starts right after the
		# previous one released it -- a tool hiccup, not a result, and the
		# documented remedy in scripts/p8_ooc_pair.sh is to repeat the leg.
		if [ ! -f "$out/timing_summary.rpt" ] || [ ! -f "$out/util_flat.rpt" ]; then
			say "$prof @ $tag: no report on the first attempt -- retrying"
			tail -4 "$repo/bld/p10_${prof}_${tag}.log" | tee -a "$LOG"
			sleep 30
			synth_leg "$prof" "$tag" "$ns"
		fi
		if [ ! -f "$out/timing_summary.rpt" ] || [ ! -f "$out/util_flat.rpt" ]; then
			say "$prof @ $tag: NO REPORT -- see bld/p10_${prof}_${tag}.log"
			tail -5 "$repo/bld/p10_${prof}_${tag}.log" | tee -a "$LOG"
			rc=1; continue
		fi
		cp "$out/timing_summary.rpt" "$EVID/$prof/timing_${tag}_summary.rpt"
		cp "$out/util_flat.rpt"      "$EVID/$prof/timing_${tag}_util_flat.rpt"
		cp "$out/util_hier.rpt"      "$EVID/$prof/timing_${tag}_util_hier.rpt"
		local w l f b fmax
		w="$(wns_of "$EVID/$prof/timing_${tag}_summary.rpt")"
		l="$(util_of "$EVID/$prof/timing_${tag}_util_flat.rpt" 'CLB LUTs*')"
		f="$(util_of "$EVID/$prof/timing_${tag}_util_flat.rpt" 'Register as Flip Flop')"
		b="$(util_of "$EVID/$prof/timing_${tag}_util_flat.rpt" 'Block RAM Tile')"
		fmax="$(awk -v w="${w:-}" -v p="$ns" 'BEGIN{ if (w != "") printf "%.1f", 1000.0/(p-w) }')"
		say "$prof @ $tag: WNS=${w:-?} ns (budget $ns ns) -> Fmax~${fmax:-?} MHz | CLB LUTs*=${l:-?} Register as Flip Flop=${f:-?} BRAM=${b:-?}"
		[ -z "$w" ] && { say "$prof @ $tag: WNS not parsable from the report"; rc=1; }
	done
	git -C "$WT" checkout -f "$head" >>"$LOG" 2>&1
	return 0
}

for p in $PROFILES; do
	run_profile "$p" || { say "profile $p: aborted (rc=$?)"; rc=1; }
done
say "=== done (rc=$rc) ==="
exit $rc
