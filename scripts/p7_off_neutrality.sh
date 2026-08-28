#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P7 byte-neutrality gate: with CT_EN_TRIG_REGS = 0 and CT_EN_DF_DROP = 0 the
# encoder must produce a PINNED reference family bit for bit
# (policy doc/verification.adoc #ref-families).
#
# The build runs in a DETACHED WORKTREE -- never flip profile switches in the
# working tree while another gate (formal, mint, OOC) reads them.
#
# Two further switches are turned off with P7's own:
#   CT_EN_DEVICE_ID / CT_EN_WATCHPOINT_MSG (P4)
# Each occupies a CAPS bit (19/20), so a build carrying them can never equal a
# family minted before them. Turning them off reproduces exactly the profile
# the family was minted from, which is what makes the comparison meaningful:
# everything P7 adds must then be invisible.
#
# WHICH family (P7 audit A-1): NOT "the one minted last". This gate used to
# pin bld/r2_final_manifest.txt; a re-mint by another package two minutes
# after the green run put P7's OWN CAPS bit 22 into that file, and from then
# on the gate reported a permanent DRIFT although nothing had drifted -- a
# build with P7 compiled out cannot reach a family containing P7's CAPS bit,
# by construction. The family is therefore SELECTED mechanically: the CAPS
# word is a pure function of the CT_EN_* switches (ct_pkg::ct_cfgmsg_caps),
# and scripts/ref_family.py picks the archived family carrying exactly that
# word. The choice is printed into the log (file, CAPS, mint HEAD) so a
# reader can see the reference without reconstructing it.
#
#   usage: bash scripts/p7_off_neutrality.sh [worktree-path]
#          bash scripts/p7_off_neutrality.sh <worktree> nots
#            re-runs ONLY the timestamp-less leg + the comparison (the eleven
#            cli legs keep their artefacts)
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
# The inline xsim call below is NOT inside a cli script, so it needs the
# pinned toolchain itself: without this the first xsim on PATH wins, and a
# foreign Vivado cannot start a snapshot elaborated by the pinned one -- it
# fails with "Simulation engine failed to start", leaves the PREVIOUS leg's
# dump in place, and the manifest then reports a byte drift that is really a
# stale artefact (seen 2026-08-05, Vivado 2020.2 vs the 2022.1 snapshot).
. "$repo/scripts/ct_env.sh"
ct_need_vivado
# The eleven cli legs below need more than xsim: `python`/`python3` (the
# Microsoft Store stubs on a fresh Windows shell answer with an installation
# hint instead of running) and the abc driver that generates their xsim
# projects. Pre-flight the WHOLE toolchain here, at second one, instead of
# discovering it leg by leg forty minutes in -- a run that dies half-way
# reports "BYTE NEUTRALITY: DRIFT / OVERALL: FAIL" over a partial manifest,
# which reads as an encoder defect and is a missing interpreter
# (P4 closing audit B-3; p8_off_neutrality.sh already did this).
ct_need_python
ct_need_abc
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${1:-${CT_WORKTREE_ROOT:-$(dirname "$repo")/ctte_worktrees}/p7_off}"
ONLY="${2:-all}"
REF=""            # set by pick_family() from the worktree's own switch set
LOG="$repo/bld/p7r_off_neutrality.log"
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
# Keep the previous run readable -- a repair run must not erase the evidence
# of the run that made it necessary (r2_final_mint.sh does the same).
[ -f "$LOG" ] && cp "$LOG" "${LOG%.log}.prev.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

[ -x "$PYRDL" ] || { say "FAIL: RDL venv python missing ($PYRDL)"; exit 3; }

# Select the reference family by the CAPS word THIS build emits, and put the
# choice in the log. A build can only ever reproduce a family whose CAPS set
# matches its own -- picking "the newest" is what broke this gate (A-1).
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
-- switches off: CT_EN_TRIG_REGS CT_EN_DF_DROP CT_EN_DEVICE_ID CT_EN_WATCHPOINT_MSG"
	[ -f "$REF" ] || { say "FAIL: selected family file missing ($REF)"; exit 3; }
}

head="$(git rev-parse --short HEAD)"
say "main tree HEAD $head; worktree $WT (mode: $ONLY)"
ALL_TBS="implicit_return_tb repeated_history_tb repeat_branch_tb jtc_tb branch_predict_tb robustness_tb debug_events_tb ibhs_tb repeat_instr_tb trig_seq_own_tb config_msg_tb"
FAILS=0
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$WT/rtl/pkg/ct_pkg.sv"; }

if [ "$ONLY" = "all" ]; then
	if [ ! -d "$WT" ]; then
		git worktree add --detach "$WT" "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree add"; exit 3; }
	else
		git -C "$WT" checkout -f "$head" >>"$LOG" 2>&1 || { say "FAIL: worktree checkout"; exit 3; }
	fi
	say "worktree at $(git -C "$WT" rev-parse --short HEAD)"

	set_sw CT_EN_TRIG_REGS      0
	set_sw CT_EN_DF_DROP        0
	set_sw CT_EN_DEVICE_ID      0
	set_sw CT_EN_WATCHPOINT_MSG 0
	say "switches in the worktree:"
	grep -nE "localparam bit CT_EN_(TRIG_REGS|DF_DROP|DEVICE_ID|WATCHPOINT_MSG) " "$WT/rtl/pkg/ct_pkg.sv" | tee -a "$LOG"

	# The cli scripts drive xsim, so abc has to generate a VIVADO project --
	# the committed sim_backend is `verilator`. This used to be a sed on the
	# worktree's .abc.config, i.e. a dirty file in the tree under test;
	# ct_need_prj (scripts/ct_env.sh) now passes `--sim-backend vivado` on
	# the command line instead, and the worktree stays clean.

	"$PYRDL" scripts/gen_rdl_profile.py --pkg "$WT/rtl/pkg/ct_pkg.sv" \
		--rdl-dir "$WT/rdl" --out-dir "$WT/rtl/pkg" >>"$LOG" 2>&1 \
		|| { say "FAIL: profile regen"; exit 3; }
	say "profile regenerated: $(grep -c '^`define' "$WT/rdl/ct_profile.inc.rdl") define(s)"
	pick_family

	cd "$WT"
	for d in $ALL_TBS; do
		rm -f "bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"/atb_*.bin 2>/dev/null
	done
	for t in ir rh rb jtc bp robust dbg ibhs rpti tso cfg; do
		if bash "scripts/cli_${t}_test.sh" >>"$LOG" 2>&1; then say "  cli_$t: PASS"
		else say "  cli_$t: FAIL"; FAILS=$((FAILS+1)); fi
	done
elif [ "$ONLY" = "ir" ]; then
	# Repair mode: re-establish the OFF profile and redo the implicit-return
	# legs (off/on/nots) only. The other testbenches keep the artefacts of
	# the full run -- they were produced under this very profile and no
	# other gate touches their dumps.
	set_sw CT_EN_TRIG_REGS      0
	set_sw CT_EN_DF_DROP        0
	set_sw CT_EN_DEVICE_ID      0
	set_sw CT_EN_WATCHPOINT_MSG 0
	set_sw CT_EN_DAQ 1; set_sw CT_EN_DATA_TRACE 1; set_sw CT_EN_ACT 1; set_sw CT_EN_FILTERS 1
	set_sw CT_EN_DF_ADDR_COMPRESS 1; set_sw CT_COMPACT_PACKER 0
	grep -nE "localparam bit CT_EN_(TRIG_REGS|DF_DROP|DEVICE_ID|WATCHPOINT_MSG|DATA_TRACE|DAQ|ACT|FILTERS|DF_ADDR_COMPRESS) |localparam bit CT_COMPACT_PACKER " "$WT/rtl/pkg/ct_pkg.sv" | tee -a "$LOG"
	"$PYRDL" scripts/gen_rdl_profile.py --pkg "$WT/rtl/pkg/ct_pkg.sv" \
		--rdl-dir "$WT/rdl" --out-dir "$WT/rtl/pkg" >>"$LOG" 2>&1 \
		|| { say "FAIL: profile regen"; exit 3; }
	say "profile regenerated: $(grep -c '^`define' "$WT/rdl/ct_profile.inc.rdl") define(s)"
	pick_family
	cd "$WT"
	rm -f bld/implicit_return_tb.abc.vivado/implicit_return_tb.abc.sim/sim_1/behav/xsim/atb_*.bin
	if bash scripts/cli_ir_test.sh >>"$LOG" 2>&1; then say "  cli_ir: PASS"
	else say "  cli_ir: FAIL"; FAILS=$((FAILS+1)); fi
else
	pick_family
	cd "$WT"
	say "reusing the existing cli artefacts; re-running the NO_TSTAMP leg only"
fi

# The timestamp-less leg has no cli script of its own (mirrors r2_final_mint.sh).
# xsim reports a failed engine start through the LOG, not through its exit
# code, so the verdict comes from ct_xsim (scripts/ct_env.sh) -- otherwise the
# copy below silently promotes the previous leg's artefact.
x06="bld/implicit_return_tb.abc.vivado/implicit_return_tb.abc.sim/sim_1/behav/xsim"
rm -f "$x06/atb_nots.bin" "$x06/implicit_return_tb.atb.bin"
xsim_rc=0
( cd "$x06" && ct_xsim xsim_nots.log implicit_return_tb_snap \
	-testplusarg NO_TSTAMP -tclbatch _runall.tcl ) || xsim_rc=$?
if [ "$xsim_rc" -ne 0 ]; then
	say "NO_TSTAMP leg: FAIL (xsim did not run -- see $x06/xsim_nots.log)"; FAILS=$((FAILS+1))
elif [ ! -f "$x06/implicit_return_tb.atb.bin" ]; then
	say "NO_TSTAMP leg: FAIL (no dump produced)"; FAILS=$((FAILS+1))
else
	cp "$x06/implicit_return_tb.atb.bin" "$x06/atb_nots.bin"
	say "NO_TSTAMP leg: ok ($(md5sum "$x06/atb_nots.bin" | cut -d' ' -f1))"
fi

out="$repo/bld/p7r_off_manifest.txt"
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
say "OFF manifest: $(grep -c . "$out") artefacts"

# A manifest built from legs that did not run is not a drift verdict. When a
# leg failed, artefacts are missing or stale and the diff below is guaranteed
# to differ -- reporting that as DRIFT blames the encoder for a broken
# toolchain, which is exactly what a fresh worktree without bld/ used to
# produce (P4 closing audit B-2/B-3). Say INCONCLUSIVE instead: still red,
# but red about the right thing.
if [ "$FAILS" -ne 0 ]; then
	diff -u <(grep -v '^#' "$REF") "$out" >>"$LOG" 2>&1 || true
	say "BYTE NEUTRALITY: INCONCLUSIVE -- $FAILS leg(s) failed before the comparison;"
	say "  the manifest is incomplete, so it says nothing about byte identity (see $LOG)"
elif diff -u <(grep -v '^#' "$REF") "$out" >>"$LOG" 2>&1; then
	say "BYTE NEUTRALITY: IDENTICAL ($(grep -c . "$out") of $(grep -vc '^#' "$REF") artefacts)"
else
	say "BYTE NEUTRALITY: DRIFT (see $LOG)"; FAILS=$((FAILS+1))
fi
say "cli failures: $FAILS"
[ "$FAILS" -eq 0 ] && say "OVERALL: PASS" || say "OVERALL: FAIL"
exit $FAILS
