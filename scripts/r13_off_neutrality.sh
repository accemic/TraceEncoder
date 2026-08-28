#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# R1.3 byte-neutrality gate (CT_EN_BLOCK_TIP, block ingress).
#
# TWO claims, and the second is the stronger one:
#
#   off : the committed default (CT_EN_BLOCK_TIP = 0) reproduces the PINNED
#         reference family bit for bit -- adding the switch cost the default
#         build nothing. This is the direction a neighbouring ASIC-area
#         measurement depends on.
#   on  : the SAME reference streams come out byte-identical from a BLOCK
#         build too. Every reference testbench drives single retirements,
#         which a block ingress reports as a one-instruction block
#         (cpu_model's sr_iretire drives 2^ilastsize halfwords there). If the
#         derivations TipBeatHalfwords / TipLastIaddr / TipBlockNextIaddr are
#         exact, the degenerate case has to produce the historical bytes --
#         31 identical artefacts is a much sharper statement about them than
#         "the switch is off, so nothing happened".
#
# NO other switch is flipped. The reference family is not inherited from
# bld/, it is COMPUTED: scripts/ref_family.py select evaluates
# ct_cfgmsg_caps() for the worktree's own switch set and picks the archived
# family in verification/ref_final/ that carries exactly that CAPS word. A build can
# only ever reproduce a family whose CAPS set matches its own, and "whatever
# was minted last" is precisely what broke the P7 gate (P7 audit A-1, and
# this gate inherited the anti-pattern -- P8 audit B-1). R1.3 adds no CAPS bit,
# so both directions select the same family; the log names file, CAPS word
# and mint HEAD either way.
#
# The build runs in a DETACHED WORKTREE -- never flip profile switches in the
# working tree while another gate (formal, mint, OOC) reads them.
#
#   usage: bash scripts/r13_off_neutrality.sh on|off [worktree-path]
#
# REF=<path> overrides the selection (for reproducing an older comparison);
# it is logged as an override so a run can never look mechanical when it was
# not.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
# The inline xsim call below is NOT inside a cli script, so it needs the
# pinned toolchain itself: without this the first xsim on PATH wins, and a
# foreign Vivado cannot start a snapshot elaborated by the pinned one -- it
# fails with "Simulation engine failed to start", leaves the PREVIOUS leg's
# dump in place, and the manifest then reports a byte drift that is really a
# stale artefact (P7 finding, 2026-08-05).
. "$repo/scripts/ct_env.sh"
ct_need_vivado
ct_need_python   # abc's project generation is a Python consumer
ct_need_abc

MODE="${1:-on}"
case "$MODE" in on) SW=1 ;; off) SW=0 ;; *) echo "usage: $0 on|off [worktree]"; exit 2 ;; esac
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${2:-${CT_WORKTREE_ROOT:-$(dirname "$repo")/ctte_worktrees}/r13_neutrality}"
REF="${REF:-}"          # empty => computed by pick_family() below
LOG="$repo/bld/r13_neutrality_${MODE}.log"
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
[ -f "$LOG" ] && cp "$LOG" "${LOG%.log}.prev.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

[ -x "$PYRDL" ] || { say "FAIL: RDL venv python missing ($PYRDL)"; exit 3; }

# Pick the reference family by the CAPS word THIS build emits, and put the
# choice -- file, CAPS, mint HEAD -- in the log (doc/verification.adoc
# #ref-families). Same mechanism as scripts/p7_off_neutrality.sh; inheriting
# "the newest manifest in bld/" is what P7 audit A-1 abolished.
pick_family () {
	local out
	if ! out="$("$PYRDL" "$repo/scripts/ref_family.py" select \
			--pkg "$WT/rtl/pkg/ct_pkg.sv" 2>&1)"; then
		say "FAIL: no reference family matches this build's CAPS word"
		printf '%s\n' "$out" | tee -a "$LOG"
		exit 3
	fi
	printf '%s\n' "$out" >> "$LOG"
	REF="$(printf '%s\n' "$out" | sed -n 's/^FAMILY=//p')"
	say "reference family: $(printf '%s\n' "$out" | sed -n 's/^FAMILY_FILE=//p') \
(CAPS $(printf '%s\n' "$out" | sed -n 's/^FAMILY_CAPS=//p'), \
minted $(printf '%s\n' "$out" | sed -n 's/^FAMILY_MINTED=//p') \
at HEAD $(printf '%s\n' "$out" | sed -n 's/^FAMILY_HEAD=//p'))"
	say "this build emits CAPS $(printf '%s\n' "$out" | sed -n 's/^BUILD_CAPS=//p') \
-- CT_EN_BLOCK_TIP carries no CAPS bit, so on and off select the same family"
	[ -f "$REF" ] || { say "FAIL: selected family file missing ($REF)"; exit 3; }
}

head="$(git rev-parse --short HEAD)"
say "source tree HEAD $head; worktree $WT; mode $MODE (CT_EN_BLOCK_TIP=$SW)"
ALL_TBS="implicit_return_tb repeated_history_tb repeat_branch_tb jtc_tb branch_predict_tb robustness_tb debug_events_tb ibhs_tb repeat_instr_tb trig_seq_own_tb config_msg_tb"
FAILS=0

if [ ! -d "$WT" ]; then
	git worktree add --detach "$WT" "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree add"; exit 3; }
else
	git -C "$WT" checkout -f "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree checkout"; exit 3; }
fi
say "worktree at $(git -C "$WT" rev-parse --short HEAD)"

sed -i -E "s/(localparam bit CT_EN_BLOCK_TIP[[:space:]]*=[[:space:]]*)[01];/\1${SW};/" "$WT/rtl/pkg/ct_pkg.sv"
grep -nE "localparam bit CT_EN_BLOCK_TIP " "$WT/rtl/pkg/ct_pkg.sv" | tee -a "$LOG"

# After the flip, so the CAPS word is computed from the switch set that is
# actually going to be built.
if [ -n "$REF" ]; then
	say "reference OVERRIDE via REF=$REF (not the mechanical selection)"
	[ -f "$REF" ] || { say "FAIL: reference manifest missing ($REF)"; exit 3; }
else
	pick_family
fi
say "reference: $REF (md5 $(md5sum "$REF" | cut -d' ' -f1))"

# The cli scripts drive xsim, so abc has to generate a VIVADO project -- the
# committed sim_backend is `verilator`. This used to be a sed on the
# worktree's .abc.config, i.e. a dirty file in the very tree under test;
# ct_need_prj (scripts/ct_env.sh) now passes `--sim-backend vivado` on the
# command line instead, and the worktree stays clean.

# NO profile regeneration here, deliberately. P8 adds no CT_PROFILE_NO_*
# define (D-P8-8: trTeControl.InstSyncReq exists in every profile, with or
# without a consumer), so the committed generated CSR already IS the full
# profile this comparison needs -- and running gen_rdl_profile.py in a
# WORKTREE is a known trap: the script looks for the pinned venv next to
# itself, does not find one, and silently falls back to whatever peakrdl is
# on PATH. That version emits no addrmap localparams, and the whole battery
# then dies in xvlog with "'NUM_PERFCNT_IFETCH_TH_RANGES' is not declared"
# (reproduced 2026-08-05; same class as the P9 audit finding).
# What is asserted instead: the generated files are exactly the committed
# ones. That is the stronger statement anyway.
# (ct_pkg.sv is excluded on purpose -- the switch flip above is its only
#  modification and is the point of the run.)
GEN_FILES="rtl/pkg/ct_cs_cpuif.sv rtl/pkg/ct_cs_cpuif_pkg.sv rtl/pkg/ct_cs_cpuif_wb_pkg.sv rtl/pkg/ct_cs_cpuif_types_pkg.sv rdl"
# shellcheck disable=SC2086
if [ -n "$(git -C "$WT" status --porcelain $GEN_FILES)" ]; then
	say "FAIL: generated CSR / RDL differs from the commit in the worktree:"
	git -C "$WT" status --porcelain $GEN_FILES | tee -a "$LOG"
	exit 3
fi
say "generated CSR + RDL: identical to the commit (no profile surgery)"

cd "$WT"
# A FRESH worktree has no xsim projects, and the cli scripts do not generate
# them -- they clone the .prj of the two primary tests. Generate those two
# with abc first (its Vivado launch_simulation fails under this shell, which
# is the documented local quirk from scripts/cli_sim.sh; the .prj is written
# before that failure and is all the cli scripts need).
# The bootstrap itself lives in ct_need_prj (scripts/ct_env.sh) since the
# same three lines were needed by every cli gate. It is invoked through the
# WORKTREE's own copy so it generates the project there, not in the main
# tree: CT_ROOT is exported and would still name the main checkout, which is
# exactly why ct_env.sh recomputes CT_TREE on every source.
bootstrap_prj () { # $1 = tb name
	local tb="$1"
	( cd "$WT" && . "$WT/scripts/ct_env.sh" && ct_need_prj "$tb" ) >>"$LOG" 2>&1 \
		|| { say "FAIL: no prj for $tb (toolchain, not a byte drift -- see $LOG)"; return 1; }
	say "  prj ready: $tb"
}
bootstrap_prj implicit_return_tb  || exit 3
bootstrap_prj repeated_history_tb || exit 3

for d in $ALL_TBS; do
	rm -f "bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"/atb_*.bin 2>/dev/null
done
for t in ir rh rb jtc bp robust dbg ibhs rpti tso cfg; do
	if bash "scripts/cli_${t}_test.sh" >>"$LOG" 2>&1; then say "  cli_$t: PASS"
	else say "  cli_$t: FAIL"; FAILS=$((FAILS+1)); fi
done

# The timestamp-less leg has no cli script of its own (mirrors r2_final_mint.sh).
# It goes through ct_xsim: xsim reports a failed engine start through its LOG,
# not through the exit code, and the copy below would then promote the
# previous leg's artefact (P7 finding R4).
x06="bld/implicit_return_tb.abc.vivado/implicit_return_tb.abc.sim/sim_1/behav/xsim"
rm -f "$x06/atb_nots.bin" "$x06/implicit_return_tb.atb.bin"
nots_ok=1
( cd "$x06" && ct_xsim xsim_nots.log implicit_return_tb_snap \
	-testplusarg NO_TSTAMP -tclbatch _runall.tcl ) || nots_ok=0
if [ "$nots_ok" -eq 0 ]; then
	say "NO_TSTAMP leg: FAIL (xsim did not run -- see $x06/xsim_nots.log)"; FAILS=$((FAILS+1))
elif [ ! -f "$x06/implicit_return_tb.atb.bin" ]; then
	say "NO_TSTAMP leg: FAIL (no dump produced)"; FAILS=$((FAILS+1))
else
	cp "$x06/implicit_return_tb.atb.bin" "$x06/atb_nots.bin"
	say "NO_TSTAMP leg: ok ($(md5sum "$x06/atb_nots.bin" | cut -d' ' -f1))"
fi

out="$repo/bld/r13_manifest_${MODE}.txt"
: > "$out"
for d in $ALL_TBS; do
	x="bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"
	[ -d "$x" ] || continue
	for f in "$x"/atb_*.bin; do
		[ -f "$f" ] || continue
		echo "$(md5sum "$f" | cut -d' ' -f1)  ${d}/$(basename "$f")" >> "$out"
	done
done
sort -k2 -o "$out" "$out"
say "$MODE manifest: $(grep -c . "$out") artefacts"

# A manifest built from legs that did not run is not a drift verdict -- see
# the same block in p7_off_neutrality.sh (P4 closing audit B-2/B-3).
if [ "$FAILS" -ne 0 ]; then
	diff -u <(grep -v '^#' "$REF") "$out" >>"$LOG" 2>&1 || true
	say "BYTE NEUTRALITY ($MODE): INCONCLUSIVE -- $FAILS leg(s) failed before the"
	say "  comparison; the manifest is incomplete and says nothing about byte identity"
elif diff -u <(grep -v '^#' "$REF") "$out" >>"$LOG" 2>&1; then
	say "BYTE NEUTRALITY ($MODE): IDENTICAL ($(grep -c . "$out") of $(grep -vc '^#' "$REF") artefacts)"
else
	say "BYTE NEUTRALITY ($MODE): DRIFT (see $LOG)"; FAILS=$((FAILS+1))
fi
say "cli failures: $FAILS"
[ "$FAILS" -eq 0 ] && say "OVERALL: PASS" || say "OVERALL: FAIL"
exit $FAILS
