#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Mint the reference artefacts for the final default configuration -- in
# particular trTeControl.SendConfig resetting to CFG_ONCE, so every stream
# starts with the vendor config message (TCODE 58). Phases:
#   1  full defaults: the whole suite plus the newer tests (all cli_* verdicts),
#      manifest bld/r2_final_manifest.txt and the test 06 md5 family
#      (off/on/nots) as the NEW reference anchors -- the previous family is
#      superseded by the config message, as intended.
#   2  ptsuite compact=0: the tests covering the newer message arms ->
#      manifest cmp0 plus message dumps.
#   3  ptsuite compact=1: the same tests -> manifest cmp1 plus message dumps.
#      The pair gate is MESSAGE SEQUENCE identity (NexRv deco-full without the
#      IDLE lines): the packer contract is a byte-identical wire stream at
#      MESSAGE level. The raw atb.bin is quantized to ATB beats and may shift
#      idle POSITIONS -- assembly latency differs between formatter and packer,
#      so the message bytes are identical and only the idle beat boundaries
#      move. The md5 manifests are kept as documentation.
#   4  restore the full profile and re-check test 06 (md5s == phase 1 values).
#
# Supersession bookkeeping (policy: doc/verification.adoc #ref-families): a
# re-mint REPLACES the pinned family, so the previous one must survive as
# documentation. The script therefore preserves the previous log/manifest
# (bld/r2_final_mint.prev.log, bld/r2_final_manifest.prev.txt), carries the
# previous REF_FINAL_06 line into the new log/manifest header and records
# WHY the family moved:
#     SUPERSEDE_REASON="CAPS 22 (P3 DF address compression, commit db4211a)" \
#       bash scripts/r2_final_mint.sh
#
# bld/ is gitignored and keeps exactly ONE generation, so two mints in a row
# used to destroy the older family for good -- including the family an
# already-closed package was measured against (P7 audit A-1: it happened,
# two minutes apart, and left that package's gate permanently red for the
# wrong reason). Every family is therefore ARCHIVED into verification/ref_final/
# before the next mint overwrites it, and again right after minting so the
# CURRENT pin is in the tree too. The archive is append-only
# (scripts/ref_family.py), and each manifest header now carries the CAPS
# word its profile emits -- that word is what lets a gate select the family
# it may legitimately compare against. REF_ARCHIVE_SKIP=1 opts out of the
# pre-mint archiving; it is a deliberate act of destroying evidence.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
ct_need_vivado
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
LOG="bld/r2_final_mint.log"
PREV_FAMILY=""
if [ -f "$LOG" ]; then
	cp "$LOG" "bld/r2_final_mint.prev.log"
	# ONLY the timestamped say() line -- the log also contains the tee'd
	# supersession record, whose "NEW     : REF_FINAL_06: ..." line is the
	# LAST match and used to end up verbatim in the next header ("supersedes
	# : NEW     : ..."). Anchoring on the timestamp picks the family line.
	PREV_FAMILY="$(grep -hE '^\[[0-9:]+\] REF_FINAL_06:' "$LOG" | tail -1 | sed 's/^\[[0-9:]*\] //')"
fi
if [ -f bld/r2_final_manifest.txt ]; then
	cp bld/r2_final_manifest.txt bld/r2_final_manifest.prev.txt
	# Archive the OUTGOING family before this run replaces it (A-1).
	if [ "${REF_ARCHIVE_SKIP:-0}" != 1 ]; then
		"$PYRDL" scripts/ref_family.py archive bld/r2_final_manifest.txt || {
			echo "ABORT: cannot archive the outgoing REF_FINAL family into" >&2
			echo "  verification/ref_final/ -- minting now would destroy it for good." >&2
			echo "  Fix the manifest header, or set REF_ARCHIVE_SKIP=1 if you" >&2
			echo "  really mean to discard it." >&2
			exit 3
		}
	fi
fi
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

PKG="rtl/pkg/ct_pkg.sv"
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }

ptsuite_profile () { # CF-only (compact-packer precondition), $1 = compact 0/1
	# CT_EN_DF_ADDR_COMPRESS must follow CT_EN_DATA_TRACE: the P3 formatter
	# guard ($fatal "CT_EN_DF_ADDR_COMPRESS requires CT_EN_DATA_TRACE",
	# ct_L2_nexus_formatter.sv) aborts elaboration otherwise. Found by the
	# CAPS-22 re-mint: with compact=0 (formatter instantiated) all four
	# phase-2 legs died in xelab, with compact=1 they passed because the
	# compact packer replaces the formatter -- and the pair gate then
	# compared a missing dump set against a real one.
	set_sw CT_EN_DAQ 0; set_sw CT_EN_DATA_TRACE 0; set_sw CT_EN_ACT 0; set_sw CT_EN_FILTERS 0; set_sw CT_EN_DF_DROP 0
	set_sw CT_EN_DF_ADDR_COMPRESS 0
	# Same class of dependency for P4: CT_EN_WATCHPOINT_MSG must follow
	# CT_EN_ACT (composer guard "$fatal CT_EN_WATCHPOINT_MSG requires
	# CT_EN_ACT" -- WPHIT comes from the ACT-ST command path).
	set_sw CT_EN_WATCHPOINT_MSG 0; set_sw CT_EN_AXIS_TS 0
	# ... and for P7: CT_EN_DF_DROP must follow CT_EN_DATA_TRACE (composer
	# guard "$fatal CT_EN_DF_DROP requires CT_EN_DATA_TRACE" -- there is no
	# data trace to drop). It rides on the CT_EN_DATA_TRACE lines above.
	set_sw CT_COMPACT_PACKER "$1"
	"$PYRDL" scripts/gen_rdl_profile.py >> "$LOG" 2>&1
}
full_profile () {
	set_sw CT_EN_DAQ 1; set_sw CT_EN_DATA_TRACE 1; set_sw CT_EN_ACT 1; set_sw CT_EN_FILTERS 1; set_sw CT_EN_DF_DROP 1
	set_sw CT_EN_DF_ADDR_COMPRESS 1
	set_sw CT_EN_WATCHPOINT_MSG 1; set_sw CT_EN_AXIS_TS 1
	set_sw CT_COMPACT_PACKER 0
	"$PYRDL" scripts/gen_rdl_profile.py >> "$LOG" 2>&1
}

ALL_TBS="implicit_return_tb repeated_history_tb repeat_branch_tb jtc_tb branch_predict_tb robustness_tb debug_events_tb ibhs_tb repeat_instr_tb trig_seq_own_tb config_msg_tb"
NEW_TBS="ibhs_tb repeat_instr_tb trig_seq_own_tb config_msg_tb"

manifest () { # $1 outfile, $2 tb list
	local out="$1"; shift
	: > "$out"; local d f
	for d in $@; do
		local x="bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"
		[ -d "$x" ] || continue
		for f in "$x"/atb_*.bin; do
			[ -f "$f" ] || continue
			echo "$(md5sum "$f" | cut -d' ' -f1)  ${d}/$(basename "$f")" >> "$out"
		done
	done
	sort -k2 -o "$out" "$out"
}
clean_atbs () { local d; for d in $@; do rm -f "bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"/atb_*.bin 2>/dev/null; done; }

msg_dumps () { # $1 = outdir, $2... = tb list; message-level dumps of all atb legs
	local out="$1"; shift
	rm -rf "$out"; mkdir -p "$out"; local d f
	for d in $@; do
		local x="bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"
		[ -d "$x" ] || continue
		for f in "$x"/atb_*.bin; do
			[ -f "$f" ] || continue
			# Keep only DECODED field lines ('=' -- TCODE/fields) + the Stat
			# line: raw per-byte echo lines and idle separators shift with
			# assembly latency (idle-position class) without a message delta.
			"bin/NexRv.exe" -deco "$f" -pcinfo "$x/${d}.nexrv.info" -pcout /dev/null -full 2>/dev/null \
				| grep -E '=|^Stat:' > "$out/${d}_$(basename "$f" .bin).txt"
		done
	done
}

run_cli () { # $1 = script tag, $2 = label
	if bash "scripts/cli_${1}_test.sh" >> "$LOG" 2>&1; then say "  cli_$1: PASS"; else say "  cli_$1: FAIL"; FAILS=$((FAILS+1)); fi
}

FAILS=0

say "=== Phase 1: full default (SendConfig=CFG_ONCE) -- Suite 06-16 ==="
clean_atbs $ALL_TBS
for t in ir rh rb jtc bp robust dbg ibhs rpti tso cfg; do run_cli "$t"; done
x06="bld/implicit_return_tb.abc.vivado/implicit_return_tb.abc.sim/sim_1/behav/xsim"
# Produce the timestamp-less leg FRESH: its own +NO_TSTAMP run, as in
# r2_mint.sh. cli_ir_test.sh only produces off/on, and a left-over atb_nots
# would be a stale artefact rather than evidence.
( cd "$x06" \
  && ct_xsim xsim_nots.log implicit_return_tb_snap -testplusarg NO_TSTAMP -tclbatch _runall.tcl \
  && cp implicit_return_tb.atb.bin atb_nots.bin ) || say "NO_TSTAMP leg: FAIL"
manifest "bld/r2_final_manifest.txt" $ALL_TBS
say "Manifest R2 final: $(grep -c . bld/r2_final_manifest.txt) artefacts"
REF_OFF=$(md5sum "$x06/atb_off.bin"  | cut -d' ' -f1)
REF_ON=$(md5sum  "$x06/atb_on.bin"   | cut -d' ' -f1)
REF_NOTS=$(md5sum "$x06/atb_nots.bin" | cut -d' ' -f1)
say "REF_FINAL_06: off=$REF_OFF on=$REF_ON nots=$REF_NOTS"

# --- supersession record: previous family stays readable next to the new one
{
	echo "==== SUPERSESSION RECORD (r2_final_mint.sh; policy doc/verification.adoc #ref-families) ===="
	echo "REASON  : ${SUPERSEDE_REASON:-<none given -- set SUPERSEDE_REASON when the family moves>}"
	if [ -n "$PREV_FAMILY" ]; then
		echo "PREVIOUS (superseded, kept for the record, DO NOT reuse):"
		echo "  $PREV_FAMILY"
		echo "  full previous run: bld/r2_final_mint.prev.log / bld/r2_final_manifest.prev.txt"
	else
		echo "PREVIOUS: none on this machine (first mint)"
	fi
	echo "NEW     : REF_FINAL_06: off=$REF_OFF on=$REF_ON nots=$REF_NOTS"
	echo "HEAD    : $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
	echo "===="
} | tee -a "$LOG"
# The CAPS word this profile emits -- the key a byte-neutrality gate uses to
# decide whether it may compare against this family at all (A-1).
CAPS_VALUE="$("$PYRDL" scripts/ref_family.py caps --pkg "$PKG" | sed -n 's/^CAPS_VALUE=//p')"
CAPS_WIDTH="$("$PYRDL" scripts/ref_family.py caps --pkg "$PKG" | sed -n 's/^CAPS_WIDTH=//p')"
[ -n "$CAPS_VALUE" ] || { say "FAIL: cannot compute the CAPS word of $PKG"; exit 3; }
say "CAPS of the minted profile: $CAPS_VALUE (width $CAPS_WIDTH)"
{
	printf '# REF_FINAL manifest -- minted %s, HEAD %s\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
	printf '# reason     : %s\n' "${SUPERSEDE_REASON:-<none given>}"
	printf '# supersedes : %s\n' "${PREV_FAMILY:-<none -- first mint>}"
	printf '# caps-value : %s (width %s) -- a build emitting a DIFFERENT CAPS word can never reproduce this family\n' \
		"$CAPS_VALUE" "$CAPS_WIDTH"
	printf '# previous   : bld/r2_final_manifest.prev.txt / bld/r2_final_mint.prev.log\n'
	cat bld/r2_final_manifest.txt
} > bld/r2_final_manifest.new && mv bld/r2_final_manifest.new bld/r2_final_manifest.txt

# ... and put the NEW family in the tree straight away, so the current pin is
# never the one generation that only lives in gitignored bld/.
"$PYRDL" scripts/ref_family.py archive bld/r2_final_manifest.txt 2>&1 | tee -a "$LOG"

say "=== Phase 2: ptsuite compact=0 -- new arms (tests 13-16) ==="
ptsuite_profile 0
clean_atbs $NEW_TBS
for t in ibhs rpti tso cfg; do run_cli "$t"; done
manifest "bld/r2_final_cmp0.txt" $NEW_TBS
msg_dumps "bld/r2f_dump_cmp0" $NEW_TBS

say "=== Phase 3: ptsuite compact=1 -- the same arms in the compact packer ==="
ptsuite_profile 1
clean_atbs $NEW_TBS
for t in ibhs rpti tso cfg; do run_cli "$t"; done
manifest "bld/r2_final_cmp1.txt" $NEW_TBS
msg_dumps "bld/r2f_dump_cmp1" $NEW_TBS

# The pair gate is at MESSAGE level (that is the contract); atb md5
# differences are the documented idle-position class -- assembly latency, see
# the header comment.
if diff -rq bld/r2f_dump_cmp0 bld/r2f_dump_cmp1 >> "$LOG" 2>&1; then
	say "compact pair: MESSAGE SEQUENCES IDENTICAL ($(ls bld/r2f_dump_cmp0 | wc -l) streams)"
	if diff -u bld/r2_final_cmp0.txt bld/r2_final_cmp1.txt >> "$LOG" 2>&1; then
		say "compact pair: additionally atb-byte-identical"
	else
		say "compact pair: atb md5s differ (the documented idle-position class)"
	fi
else
	say "compact pair: MESSAGE DIFFERENCES (real delta! see $LOG)"; FAILS=$((FAILS+1))
fi

say "=== Phase 4: restore the full profile + re-check test 06 ==="
full_profile
clean_atbs implicit_return_tb
run_cli ir
CHK_OFF=$(md5sum "$x06/atb_off.bin" | cut -d' ' -f1)
if [ "$CHK_OFF" = "$REF_OFF" ]; then say "full restore 06-off: EXACT ($CHK_OFF)"; else say "full restore 06-off: DRIFT ($CHK_OFF != $REF_OFF)"; FAILS=$((FAILS+1)); fi

# Generated-CSR hygiene: gen_rdl_profile.py emits the RAW PeakRDL output
# (modelines + tab canonicalisation are gen_rdl.sh's job), so a mint leaves
# the two generated files cosmetically dirty. Report it -- but a
# NON-whitespace diff is real profile drift and must never be checked out
# blindly.
GEN_CSR="rtl/pkg/ct_cs_cpuif.sv rtl/pkg/ct_cs_cpuif_pkg.sv"
if ! git diff --quiet -- $GEN_CSR 2>/dev/null; then
	# -w absorbs the tab/space reflow; what remains of the trap are the two
	# dropped editor modelines (whole removed comment lines, which -w cannot
	# ignore). Anything BEYOND those is real profile drift.
	REAL_DRIFT=$(git diff -w --ignore-blank-lines -U0 -- $GEN_CSR \
		| grep -E '^[-+]' | grep -vE '^(\+\+\+|---)' \
		| grep -vE '^[-+][[:space:]]*$' \
		| grep -vE '^[-+]// (vim: set ts=4 noet:|-\*- indent-tabs-mode: t; tab-width: 4 -\*-)' \
		| wc -l)
	if [ "$REAL_DRIFT" -eq 0 ]; then
		say "generated CSR files: whitespace/modeline diff only (raw-regen trap) -- 'git checkout' them"
	else
		say "generated CSR files: CONTENT diff vs HEAD ($REAL_DRIFT lines) -- profile drift, investigate!"
		FAILS=$((FAILS+1))
	fi
fi

say "=== R2-final: $FAILS Fails ==="
[ "$FAILS" -eq 0 ] && say "OVERALL: PASS" || say "OVERALL: FAIL"
exit $FAILS
