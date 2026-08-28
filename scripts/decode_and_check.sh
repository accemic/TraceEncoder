#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Unified post-simulation NexRv decode check.
#
# Locates the test's xsim CWD under bld/, decodes the ATB binary trace ONCE
# with the NexRv reference decoder, then runs whichever checks are requested
# against that single decode:
#
#   --pc          decoded PC stream EXACTLY matches <test>.expected.pcs
#                 (strict full match by default; a divergent prefix or a short
#                 decode — stopped early — fails; use --soft to allow it)
#   --data        decoded data-access sequence (DataRead/DataWrite 5/6 and
#                 the synchronizing 13/14 forms; XOR-compressed addresses
#                 are compared reconstructed) matches <test>.expected.data
#   --ctxp        CTTD's CTXP export (CTTE eXPort format,
#                 https://github.com/accemic/CTXP-format: SYNC /
#                 BRANCH_* / CALL / RETURN / MEMREAD_n / MEMWRITE_n / DAQ_*
#                 records) matches
#                 <test>.expected.ctxp, normalized for the trailing "@ <cycle>"
#                 and hex leading zeros. This is the value-aware data/DAQ check
#                 (it compares the captured data values, not just addr+size).
#   --tsmono      the reconstructed absolute timestamps in the CTXP export are
#                 monotonic (non-decreasing) across the message stream. Catches
#                 a wrong sync timestamp (e.g. a CSR-induced ACT-CAP sync that
#                 emits a stale/zero absolute) as a backwards jump. Requires the
#                 test to enable the timestamp unit (trTsControl Type=SYSTEM);
#                 an all-zero timestamp column means timestamps were off and is
#                 reported as a failure, not a vacuous pass. Co-timed messages
#                 may share a timestamp, so the invariant is non-decreasing, not
#                 strictly increasing.
#   --sync N      at least N synchronization messages present
#   --hist N      at least N branch-history messages (IndirectBranchHist,
#                 TCODE 28) present — the messages that carry indirect
#                 jumps/returns/interrupts. Guards against a configuration
#                 that silently degrades to sync-only traces (e.g. a raw
#                 trTeControl write clearing InstMode; the trace still
#                 "decodes OK" but all control flow is gone).
#   --disabled    a trace-off Program Trace Correlation Message
#                 (TCODE 33, EVCODE=Program Trace Disabled) is present
#   --overflow    a Nexus Error message (TCODE 8) with ETYPE=QueueOverrun (0x0)
#                 is present — i.e. the encoder actually emitted the overflow
#                 indication after ATB backpressure saturated its FIFOs.
#                 Hard check (not relaxed by --soft): the whole point of the
#                 overflow test is to confirm this message lands.
#   --soft        PC / data / ctxp divergence is reported as WARN, not a failure
#                 (for tests that intentionally lose trace bytes, e.g. overflow)
#
# If no check flag is given, --pc is assumed. Exit status is non-zero iff a
# requested (non-soft) check fails.
#
# Usage:  decode_and_check.sh [--soft] [--pc] [--data] [--ctxp] [--tsmono] [--sync N] [--hist N] [--disabled] [--overflow] <test_name>

set -euo pipefail

soft=0; do_pc=0; do_data=0; do_ctxp=0; do_disabled=0; do_overflow=0; do_tsmono=0; sync_min=""; hist_min=""
test_name=""
while [ $# -gt 0 ]; do
	case "$1" in
		--soft)     soft=1;        shift;;
		--pc)       do_pc=1;       shift;;
		--data)     do_data=1;     shift;;
		--ctxp)     do_ctxp=1;     shift;;
		--disabled) do_disabled=1; shift;;
		--overflow) do_overflow=1; shift;;
		--tsmono)   do_tsmono=1;   shift;;
		--sync)     sync_min="${2:?--sync needs a count}"; shift 2;;
		--hist)     hist_min="${2:?--hist needs a count}"; shift 2;;
		--*)        echo "[decode] ERROR: unknown option $1"; exit 2;;
		*)          test_name="$1"; shift;;
	esac
done
: "${test_name:?usage: $0 [--soft] [--pc] [--data] [--ctxp] [--tsmono] [--sync N] [--hist N] [--disabled] [--overflow] <test_name>}"

# Default to the PC check when none was requested.
if [ "$do_pc" -eq 0 ] && [ "$do_data" -eq 0 ] && [ "$do_ctxp" -eq 0 ] && [ "$do_disabled" -eq 0 ] && [ "$do_overflow" -eq 0 ] && [ "$do_tsmono" -eq 0 ] && [ -z "$sync_min" ] && [ -z "$hist_min" ]; then
	do_pc=1
fi

# Script-relative root, NOT `git rev-parse --show-toplevel`: this tree may be
# vendored inside a superproject without its own .git, in which case the git
# toplevel would resolve to the superproject root and bld/ + bin/ would not be
# found. ct_env.sh applies the same rule and picks the NexRv build (ELF vs
# .exe) that this platform can execute.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_root/scripts/ct_env.sh"
# This is the post-check of every `make sim-*`, so it is the single most
# expensive place to trust an unverified tool. Measured 2026-08-13 with a
# NEXRV pointing nowhere: on a cold tree this script said
# "FAIL -- NexRv produced no pcout" (a red verdict naming the encoder); on a
# WARM tree it said "PASS -- all 26 PCs match", because the pcout of the
# previous run was still on disk and the failed decode overwrote nothing.
# A broken decoder therefore did not just slander the encoder, it certified it.
#
# CT_DECODE_OPTIONAL=1 is the ONE sanctioned way past this, and it buys exactly
# one thing: a run on a machine that cannot obtain CTTD at all (the pinned
# build lives on an Accemic host, see scripts/cttd.pin) still executes the
# simulations instead of dying in the post-check. It does NOT soften any
# verdict: the decode is not attempted, the test name is recorded in
# bld/.decode_skipped, and `make sim` prints what was left unverified. Every
# OTHER decoder problem -- present but broken, wrong build, missing switches --
# still dies in ct_need_nexrv below, because those are the cases where a
# skipped verdict would be a lie rather than an absence.
if [ "${CT_DECODE_OPTIONAL:-0}" = "1" ] && [ ! -f "${NEXRV:-/nonexistent}" ]; then
	mkdir -p "$repo_root/bld"
	echo "$test_name" >> "$repo_root/bld/.decode_skipped"
	echo "[decode] SKIP -- $test_name: no reference decoder on this machine."
	echo "[decode]         The simulation RAN; its decode verdict was NOT taken."
	echo "[decode]         Provision CTTD (py scripts/fetch_cttd.py) for a real verdict."
	exit 0
fi
ct_need_nexrv
nexrv="$NEXRV"

# Locate the simulator working directory by finding the ATB dump it produced.
# abc-flow's layout varies by version (bld/<t>.vsim/ in newer releases,
# bld/<t>.abc.vivado/.../xsim/ in older ones), so search rather than hardcode.
atb_bin="$(find "$repo_root/bld" -name "${test_name}.atb.bin" -printf '%T@ %p\n' 2>/dev/null \
			| sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "$atb_bin" ]; then
	echo "[decode] ERROR: no ${test_name}.atb.bin found under bld/"
	exit 2
fi
sim_dir="$(dirname "$atb_bin")"

atb_bin="$sim_dir/${test_name}.atb.bin"
pcinfo="$sim_dir/${test_name}.nexrv.info"
pcout="$sim_dir/${test_name}.decoded.pcout"
log="$sim_dir/${test_name}.nexrv.log"

for f in "$atb_bin" "$pcinfo"; do
	if [ ! -s "$f" ]; then
		echo "[decode] ERROR: missing or empty: $f"
		exit 2
	fi
done

# ------------------------------------------------------------------
# Oracle sanity — a comparison against garbage must be NOTICED.
#
# Every text artefact below is written by the simulator's cpu_model and is
# either the reference this script diffs against or the program map the
# decoder is handed. If one of them is malformed, the comparison downstream
# still produces a verdict — and that verdict says nothing. On 2026-08-09
# (D1-F2) exactly that happened: on the .abc.config default backend
# (Verilator) cpu_model built every address with a NON-LITERAL $sformatf
# format, which Verilator does not substitute, so `expected.pcs` and the
# PCInfo began with the eleven characters `0x%08x` and a decimal number.
# NexRv could not parse the map, decoded 1 of 26 PCs, and the failure read
# like an encoder that loses trace.
#
# So the oracles are checked BEFORE they are used, and the check is HARD:
# --soft exists for tests that intentionally lose trace BYTES (overflow), not
# for a broken reference file. A malformed oracle is a tooling defect and
# must never be downgraded to a warning.
#
#   $1 = file   $2 = label   $3 = ERE that every non-empty line must match
#   $4 = what a well-formed line looks like (shown on failure)
ref_sane() {
	local f="$1" label="$2" re="$3" shape="$4" bad n
	# 1. an unsubstituted format specifier. None of these files ever contains
	#    a legitimate '%', so this is an unambiguous signature and it names
	#    the cause directly instead of leaving a grammar mismatch to puzzle
	#    over.
	if grep -qE '%[-+ #0]*[0-9]*(\.[0-9]+)?[bcdefghmostuxzBCDEFGHMOSTUXZ%]' "$f"; then
		echo "[decode-ref] $test_name: FAIL — $label contains an UNSUBSTITUTED format specifier: $f"
		echo "[decode-ref]   first offending line: $(grep -nE '%[-+ #0]*[0-9]*(\.[0-9]+)?[bcdefghmostuxzBCDEFGHMOSTUXZ%]' "$f" | head -1)"
		echo "[decode-ref]   cause class: a \$display/\$sformatf/... whose format argument is not a"
		echo "[decode-ref]   string LITERAL. Verilator does not substitute those (XSIM does), so the"
		echo "[decode-ref]   simulator wrote the format string itself. scripts/check_sim_fmt.py catches"
		echo "[decode-ref]   this statically; see D1-F2 and tests/lib/cpu_model.sv pc_hex()."
		return 1
	fi
	# 2. the grammar itself. Catches the same class from any other cause
	#    (truncated write, wrong separator, a stray log line in the file).
	n=$(grep -cvE "^[[:space:]]*$" "$f" || true); n="${n:-0}"
	bad=$(grep -vE "^[[:space:]]*$" "$f" | grep -cvE "$re" || true); bad="${bad:-0}"
	if [ "$bad" -gt 0 ]; then
		echo "[decode-ref] $test_name: FAIL — $label is malformed: $bad of $n line(s) are not $shape"
		grep -vE "^[[:space:]]*$" "$f" | grep -nvE "$re" | head -5
		echo "[decode-ref]   file: $f"
		return 1
	fi
	echo "[decode-ref] $test_name: $label OK ($n line(s), $shape)"
	return 0
}

# The PCInfo is checked unconditionally: it is the decoder's INPUT, so a
# malformed one corrupts every check in this script, not only --pc.
# Grammar (cpu_model write_nexrv_info): "0x<hex>,<TYPE><len>[,0x<hex>]".
pcinfo_lf="$pcinfo.lf"
tr -d '\r' < "$pcinfo" > "$pcinfo_lf"
ref_sane "$pcinfo_lf" "NexRv PCInfo" \
	'^0x[0-9a-fA-F]+,[A-Za-z]+[0-9]+(,0x[0-9a-fA-F]+)?$' \
	'"0x<hex>,<TYPE><len>[,0x<hex>]"' || exit 2

# ------------------------------------------------------------------
# Single NexRv decode shared by every check below.
# -full gives the per-message field detail the data/sync/disabled greps
# need; -pcout gives the reconstructed PC stream the --pc check diffs.
# A non-zero NexRv exit is tolerated (e.g. an undrained trace tail, or no
# instruction trace at all); the individual checks judge the output.
#
# -csstrict (W4, 2026-08-08): the decoder no longer aborts when the call-stack
# mirror mispredicts a return -- that change was needed so a preemptively
# multitasking kernel stays decodable past its first context switch. In THIS
# path the streams are single-task simulation corpora, where such a mismatch is
# a defect and not a scheduler event, so we keep the strict reading. Measured
# byte-free over all 56 frozen corpora, and it restores the two one-byte
# mutations the lenient mode lets through (25 -> 27 of 40).
# A test that legitimately switches context must set NEXRV_CS_LENIENT=1;
# without the opt-out it would fail at exactly the event it is testing.
# ------------------------------------------------------------------
cs_mode="-csstrict"
if [ -n "${NEXRV_CS_LENIENT:-}" ]; then
	cs_mode=""
	echo "[decode] NEXRV_CS_LENIENT set -- call-stack mismatches are re-anchors, not errors"
fi
echo "[decode] $test_name: running NexRv -deco -full $cs_mode"
"$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" -pcout "$pcout" -full $cs_mode > "$log" 2>&1 || {
	rc=$?
	echo "[decode] WARN: NexRv exited rc=$rc (often an undrained trace tail / no inst trace)"
}

fail=0

# On Windows hosts the simulator writes the expected.* reference files with
# CRLF while every decoder-side artefact is LF, so a raw whole-file compare
# reports a bogus full divergence. Every check that diffs a simulator-written
# reference runs it through this first.
#   $1 = file to normalize; echoes the path of the LF copy
norm_lf() {
	tr -d '\r' < "$1" > "$1.lf" && echo "$1.lf" || echo "$1"
}

# ------------------------------------------------------------------
# --pc : decoded PC stream vs expected.pcs
# ------------------------------------------------------------------
if [ "$do_pc" -eq 1 ]; then
	exp_pcs="$sim_dir/${test_name}.expected.pcs"
	got_pcs="$sim_dir/${test_name}.decoded.pcs"
	if [ ! -s "$exp_pcs" ]; then
		echo "[decode-pc] $test_name: ERROR — missing or empty: $exp_pcs"; fail=1
	elif [ ! -s "$pcout" ]; then
		if [ "$soft" -eq 1 ]; then
			echo "[decode-pc] $test_name: WARN — NexRv produced no pcout (see $log) (soft mode)"; tail -5 "$log"
		else
			echo "[decode-pc] $test_name: FAIL — NexRv produced no pcout (see $log)"; tail -5 "$log"; fail=1
		fi
	else
		cut -d, -f1 "$pcout" | tr -d '\r' > "$got_pcs"
		exp_pcs="$(norm_lf "$exp_pcs")"
		# Hard, and before the diff: a reference whose lines are not
		# addresses cannot decide anything (see ref_sane above).
		ref_sane "$exp_pcs" "expected.pcs" '^0x[0-9a-fA-F]+$' '"0x<hex>"' || exit 2
		n_exp=$(wc -l < "$exp_pcs")
		n_got=$(wc -l < "$got_pcs")
		n_cmp=$(( n_got < n_exp ? n_got : n_exp ))
		echo "[decode-pc] $test_name: expected $n_exp PCs, decoded $n_got PCs"
		# Strict by default: the decoded stream must EXACTLY equal the expected
		# one. A divergent prefix, or a short decode (the stream stopped early —
		# e.g. an undrained tail or a mid-stream decoder error), is a failure.
		# --soft downgrades any mismatch to a WARN (for tests that intentionally
		# lose trace bytes, e.g. overflow).
		pc_msg=""
		if [ "$n_cmp" -eq 0 ]; then
			pc_msg="nothing decoded"
		elif ! diff -q <(head -n "$n_cmp" "$exp_pcs") <(head -n "$n_cmp" "$got_pcs") > /dev/null; then
			pc_msg="first $n_cmp PCs diverge"
		elif [ "$n_got" -ne "$n_exp" ]; then
			pc_msg="prefix matches but stream is incomplete ($n_got of $n_exp PCs)"
		fi
		if [ -z "$pc_msg" ]; then
			echo "[decode-pc] $test_name: PASS — all $n_exp PCs match"
		else
			if [ "$soft" -eq 1 ]; then
				echo "[decode-pc] $test_name: WARN — $pc_msg (soft mode, not a failure)"
			else
				echo "[decode-pc] $test_name: FAIL — $pc_msg"
				fail=1
			fi
			if [ "$n_cmp" -gt 0 ]; then
				diff -u --label expected --label decoded \
					<(head -n "$n_cmp" "$exp_pcs") <(head -n "$n_cmp" "$got_pcs") | head -20 || true
			fi
		fi
	fi
fi

# ------------------------------------------------------------------
# --data : decoded DataRead/DataWrite sequence vs expected.data
# ------------------------------------------------------------------
if [ "$do_data" -eq 1 ]; then
	exp_data="$sim_dir/${test_name}.expected.data"
	got_data="$sim_dir/${test_name}.decoded.data"
	if [ ! -s "$exp_data" ]; then
		echo "[decode-data] $test_name: ERROR — missing or empty: $exp_data"; fail=1
	else
		# NexRv prints one authoritative ". DFEVT KIND,0x<addr>,<bytes>" line
		# per decoded data-trace message (TCODE 5/6 AND the synchronizing
		# 13/14 forms), already in expected.data format. Keying on that line
		# instead of the raw field lines is required for correctness: with
		# DataAddrCompress = XOR the on-wire DADDR field of 5/6 is a delta
		# against the previous data message — only the decoder's
		# reconstruction is comparable to the cpu_model oracle. (In mode
		# FULL the line equals the raw field, so legacy streams are
		# unchanged.) This also closes the silent-event-loss hole where an
		# unrecognized data TCODE simply produced no output line.
		awk '/^\. DFEVT /{ sub(/^\. DFEVT /, ""); print }' "$log" > "$got_data"
		exp_data="$(norm_lf "$exp_data")"
		ref_sane "$exp_data" "expected.data" \
			'^(LOAD|STORE),0x[0-9a-fA-F]+,[0-9]+$' \
			'"(LOAD|STORE),0x<hex>,<bytes>"' || exit 2
		n_exp=$(wc -l < "$exp_data")
		n_got=$(wc -l < "$got_data")
		echo "[decode-data] $test_name: expected $n_exp data events, decoded $n_got"
		if [ "$n_got" -eq 0 ]; then
			echo "[decode-data] $test_name: $([ "$soft" -eq 1 ] && echo WARN || echo FAIL) — NexRv produced no data messages"
			[ "$soft" -eq 1 ] || fail=1
		elif ! diff -q "$exp_data" "$got_data" > /dev/null; then
			if [ "$soft" -eq 1 ]; then
				echo "[decode-data] $test_name: WARN — data sequence diverges (soft mode)"
			else
				echo "[decode-data] $test_name: FAIL — data sequence does not match"; fail=1
			fi
			diff -u --label expected --label decoded "$exp_data" "$got_data" | head -30 || true
		else
			echo "[decode-data] $test_name: PASS — all $n_exp data events match"
		fi
	fi
fi

# ------------------------------------------------------------------
# --ctxp : NexRv CTXP export vs expected.ctxp (normalized)
# NexRv writes the CTXP text export when CTXP_TEXT_TRACEFILE is set (with
# -none). We normalize both files — drop the HDR/META header, strip the
# trailing "@ <cycle>", lowercase, and strip hex leading zeros — then diff.
# ------------------------------------------------------------------
if [ "$do_ctxp" -eq 1 ]; then
	exp_ctxp="$sim_dir/${test_name}.expected.ctxp"
	got_ctxp="$sim_dir/${test_name}.decoded.ctxp.txt"
	ctxp_log="$sim_dir/${test_name}.ctxp.log"
	if [ ! -s "$exp_ctxp" ]; then
		echo "[decode-ctxp] $test_name: ERROR — missing or empty: $exp_ctxp"; fail=1
	else
		exp_ctxp_lf="$exp_ctxp.lf"
		tr -d '\r' < "$exp_ctxp" > "$exp_ctxp_lf"
		ref_sane "$exp_ctxp_lf" "expected.ctxp" \
			'^#[0-9]+:[A-Za-z_0-9]+:(0x[0-9a-fA-F]+)?:(0x[0-9a-fA-F]+)?$' \
			'"#<n>:<RECORD>:[0x<hex>]:[0x<hex>]"' || exit 2
		CTXP_TEXT_TRACEFILE="$got_ctxp" "$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" \
			-pcout "$pcout" -none > "$ctxp_log" 2>&1 || true
		if [ ! -s "$got_ctxp" ]; then
			echo "[decode-ctxp] $test_name: FAIL — NexRv produced no CTXP export (see $ctxp_log)"
			tail -5 "$ctxp_log" || true; fail=1
		else
			# Canonicalize: drop header, strip "@ <cycle>", lowercase, strip 0x leading zeros.
			ctxp_norm() {
				grep -vE '^(HDR|META):' "$1" \
					| tr -d '\r' \
					| sed -E 's/[[:space:]]*@[[:space:]]*[0-9]+[[:space:]]*$//' \
					| tr 'A-F' 'a-f' \
					| sed -E 's/0x0*([0-9a-f])/0x\1/g'
			}
			exp_n="$sim_dir/${test_name}.expected.ctxp.norm"
			got_n="$sim_dir/${test_name}.decoded.ctxp.norm"
			ctxp_norm "$exp_ctxp" > "$exp_n"
			ctxp_norm "$got_ctxp" > "$got_n"
			n_exp=$(wc -l < "$exp_n"); n_got=$(wc -l < "$got_n")
			echo "[decode-ctxp] $test_name: expected $n_exp CTXP records, decoded $n_got"
			if diff -q "$exp_n" "$got_n" > /dev/null; then
				echo "[decode-ctxp] $test_name: PASS — all $n_exp CTXP records match"
			else
				if [ "$soft" -eq 1 ]; then
					echo "[decode-ctxp] $test_name: WARN — CTXP records diverge (soft mode)"
				else
					echo "[decode-ctxp] $test_name: FAIL — CTXP records do not match"; fail=1
				fi
				diff -u --label expected --label decoded "$exp_n" "$got_n" | head -40 || true
			fi
		fi
	fi
fi

# ------------------------------------------------------------------
# --sync N : at least N synchronization messages
# Synchronizing messages carry a "...Sync" label (ProgTraceSync,
# DirectBranchSync, IndirectBranchSync, IndirectBranchHistSync,
# RepeatInstructionSync, and — with DataAddrCompress != FULL — the data
# re-anchors DataWriteSync/DataReadSync, TCODE 13/14); plain messages do
# not. Tests that pass a --sync floor should pick N accordingly when
# they enable DF address compression.
# ------------------------------------------------------------------
if [ -n "$sync_min" ]; then
	n_sync=$(grep -cE 'TCODE\[6\]=[0-9]+.*Sync' "$log" || true)
	echo "[decode-sync] $test_name: $n_sync synchronization message(s) decoded (need >= $sync_min)"
	if [ "$n_sync" -lt "$sync_min" ]; then
		echo "[decode-sync] $test_name: FAIL — fewer than $sync_min sync messages"
		grep -nE 'TCODE\[6\]=[0-9]+' "$log" | head -20 || true
		fail=1
	else
		echo "[decode-sync] $test_name: PASS — $n_sync sync messages (>= $sync_min)"
	fi
fi

# ------------------------------------------------------------------
# --hist N : at least N branch-history messages (IndirectBranchHist,
# TCODE 28) -- the carriers of indirect jumps, returns and interrupts.
# A sync-only trace decodes without errors but reconstructs no real
# control flow, so require these explicitly where flow matters.
#
# Came from the examples branch and was half-lost in the AP0 merge: the
# variable and the usage string arrived (non-conflicting hunks), the option
# case and this block did not (conflicting ones), so --hist parsed as an
# unknown option and killed the PS-flow example leg.
# ------------------------------------------------------------------
if [ -n "$hist_min" ]; then
	n_hist=$(grep -cE 'TCODE\[6\]=28 ' "$log" || true)
	echo "[decode-hist] $test_name: $n_hist branch-history message(s) decoded (need >= $hist_min)"
	if [ "$n_hist" -lt "$hist_min" ]; then
		echo "[decode-hist] $test_name: FAIL — fewer than $hist_min IndirectBranchHist messages"
		grep -nE 'TCODE\[6\]=[0-9]+' "$log" | head -20 || true
		fail=1
	else
		echo "[decode-hist] $test_name: PASS — $n_hist branch-history messages (>= $hist_min)"
	fi
fi

# ------------------------------------------------------------------
# --disabled : trace-off Program Trace Correlation (EVCODE=Program Trace Disabled)
# ------------------------------------------------------------------
if [ "$do_disabled" -eq 1 ]; then
	n_corr=$(grep -cE 'TCODE\[6\]=33 .*ProgTraceCorrelation' "$log" || true)
	n_off=$(grep -cE 'EVCODE\[4\]=0x4' "$log" || true)
	echo "[decode-off] $test_name: $n_corr ProgTraceCorrelation msg(s), $n_off with EVCODE=Program Trace Disabled"
	if [ "$n_corr" -lt 1 ] || [ "$n_off" -lt 1 ]; then
		echo "[decode-off] $test_name: FAIL — no Program Trace Disabled correlation message emitted on trace-off"
		grep -nE 'TCODE\[6\]=[0-9]+' "$log" | tail -10 || true
		fail=1
	else
		echo "[decode-off] $test_name: PASS — trace-off emits ProgTraceCorrelation(EVCODE=Program Trace Disabled)"
	fi
fi

# ------------------------------------------------------------------
# --overflow : the encoder's ct_L2_nexus_formatter must compose at least
# one NEXUS_MSG_ERROR — i.e. the QueueOverrun injector in
# ct_L23_preproc_composer_etip actually fired because the sideband FIFO
# saturated under ATB backpressure.
#
# We grep the tee'd simulator log (<test>.sim.log) rather than the NexRv
# decode of the ATB dump: a heavy overrun cascade desyncs NexRv at the
# ATB framing layer, so the decode log is unreliable here. The
# formatter's per-message printout is a direct signal that the overflow
# path executed.
#
# Hard check — the whole point of the overflow test is to confirm this
# message is produced, so we do not relax it under --soft.
# ------------------------------------------------------------------
if [ "$do_overflow" -eq 1 ]; then
	sim_log="$sim_dir/${test_name}.sim.log"
	if [ ! -s "$sim_log" ]; then
		echo "[decode-overflow] $test_name: FAIL — missing sim log $sim_log (Makefile must tee abc -sim output)"
		fail=1
	else
		n_err=$(grep -cE 'NEXUS_MSG_ERROR' "$sim_log" || true)
		echo "[decode-overflow] $test_name: $n_err NEXUS_MSG_ERROR message(s) emitted by nexus_formatter"
		if [ "$n_err" -lt 1 ]; then
			echo "[decode-overflow] $test_name: FAIL — encoder did not emit a Nexus Error message (QueueOverrun path never fired)"
			grep -nE 'NEXUS_MSG_[A-Z_]+' "$sim_log" | tail -20 || true
			fail=1
		else
			echo "[decode-overflow] $test_name: PASS — encoder emitted $n_err Nexus Error message(s) under backpressure"
		fi
	fi
fi

# ------------------------------------------------------------------
# --tsmono : reconstructed absolute timestamps are monotonic (non-decreasing)
# NexRv annotates every CTXP record with the absolute time it reconstructed
# ("... @ <cycle>"): sync messages carry an absolute timestamp, non-sync
# messages a delta the decoder accumulates. Real time only advances, so that
# column must never step backwards. A CSR-induced (ACT-CAP) sync that emits a
# wrong absolute (stale/zero) shows up here as a decrease. Co-timed messages
# may share a timestamp (prescale 0), so the invariant is non-decreasing.
# An all-zero column means the timestamp unit was off (Type != SYSTEM) and the
# check is vacuous — that is a failure, not a silent pass.
# ------------------------------------------------------------------
if [ "$do_tsmono" -eq 1 ]; then
	got_ctxp="$sim_dir/${test_name}.decoded.ctxp.txt"
	ts_log="$sim_dir/${test_name}.tsmono.log"
	CTXP_TEXT_TRACEFILE="$got_ctxp" "$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" \
		-pcout "$pcout" -none > "$ts_log" 2>&1 || true
	if [ ! -s "$got_ctxp" ]; then
		echo "[decode-tsmono] $test_name: FAIL — NexRv produced no CTXP export (see $ts_log)"
		tail -5 "$ts_log" || true; fail=1
	else
		# Pull the trailing "@ <cycle>" off each record, in stream order.
		ts_seq=$(grep -vE '^(HDR|META):' "$got_ctxp" \
				 | sed -nE 's/.*@[[:space:]]*([0-9]+)[[:space:]]*$/\1/p')
		if [ -z "$ts_seq" ]; then
			echo "[decode-tsmono] $test_name: FAIL — no timestamped CTXP records found (see $ts_log)"
			fail=1
		else
			n_ts=$(printf '%s\n' "$ts_seq" | wc -l)
			ts_max=$(printf '%s\n' "$ts_seq" | sort -n | tail -1)
			echo "[decode-tsmono] $test_name: $n_ts timestamped records, max=$ts_max"
			if [ "$ts_max" -eq 0 ]; then
				echo "[decode-tsmono] $test_name: FAIL — all timestamps are 0 (timestamp unit not enabled: set trTsControl Type=SYSTEM before trTeControl.Enable)"
				fail=1
			elif printf '%s\n' "$ts_seq" | awk '
					NR>1 && $1 < prev { printf "  backwards: record %d ts=%d < prev=%d\n", NR, $1, prev; bad=1 }
					{ prev=$1 } END { exit bad }'; then
				echo "[decode-tsmono] $test_name: PASS — timestamps monotonic non-decreasing (0..$ts_max over $n_ts records)"
			else
				echo "[decode-tsmono] $test_name: $([ "$soft" -eq 1 ] && echo WARN || echo FAIL) — timestamps step backwards (non-monotonic)"
				[ "$soft" -eq 1 ] || fail=1
			fi
		fi
	fi
fi

exit "$fail"
