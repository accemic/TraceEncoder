#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# P0-02 sync-cadence PRODUCTION-DEFAULT gate (tests/instruction/37_sync_cadence).
#
# The question is not whether periodic sync works (tests 04/29/30 cover that)
# but whether the value the encoder comes out of RESET with is one a product
# can ship. The natural programming path is ONE write to trTeControl
# ("periodic sync, counted in instructions") -- InstSyncMode comes from
# software, InstSyncMax from the reset. Both legs walk exactly that path over
# the same 100 000-retire workload in the equal-rate drain regime (the
# KV260/MBV integration shape, the only one where a too-tight cadence shows up
# as trace LOSS rather than as mere bandwidth).
#
#   pos    sync_default_tb -- InstSyncMax NOT written, i.e. the reset value.
#          P1  ZERO Nexus Error messages (TCODE 8)  -- no overflow announced
#          P2  NexRv "Decoded OK" and every expected PC decoded  -- lossless
#          P3  the config message on the wire carries the reset cadence
#              (VendorConfig P1[12] bits [10:7] = InstSyncMax)
#   neg    sync_cadence_sweep_tb +SYNCMAX=0 -- the minimum period, same
#          workload. Must STILL reproduce the stress case: >= 1 TCODE 8.
#          Without this leg the sentence "the minimum period is kept as an
#          explicit stress configuration" is unbacked.
#   sweep  +SYNCMAX in 0 2 4 6 8 10 -- the bandwidth curve behind the choice
#          of the reset value. Reported, not asserted.
#
# usage: bash scripts/cli_synccadence_test.sh [pos|neg|sweep|full]   (default full)
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_python
ct_need_abc
ct_need_nexrv

mode="${1:-full}"
pos_tb=sync_default_tb
swp_tb=sync_cadence_sweep_tb
tdir=tests/instruction/37_sync_cadence
verdict=0

# The expected cadence is READ FROM THE SOURCE, never hard-coded here: the
# point of leg P3 is that RDL, generated RTL and the on-wire config message
# agree, and a gate carrying its own copy of the number could not detect them
# drifting apart.
rdl_max="$(sed -n 's/^[[:space:]]*} InstSyncMax\[23:20\][[:space:]]*=[[:space:]]*\([0-9]*\);.*/\1/p' rdl/ct_cs_cpuif.rdl)"
rtl_max="$(sed -n "s/.*field_storage\.te\.trTeControl\.InstSyncMax\.value <= 4'h\([0-9a-fA-F]\);.*/\1/p" rtl/pkg/ct_cs_cpuif.sv | head -1)"
rtl_max="$((16#${rtl_max:-x}))" 2>/dev/null || rtl_max=-1
echo "### reset cadence declared: RDL InstSyncMax = ${rdl_max:-?} | generated RTL = ${rtl_max}"

chk () { # $1 = label, $2 = rc
	if [ "$2" -eq 0 ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; verdict=1; fi
}

# Build + run one testbench through abc (Verilator backend). Prints the
# simulator working directory on stdout.
build_run () { # $1 = tb, $2 = abc file
	local tb="$1" abcf="$2"
	local log="$here/bld/synccad_${tb}.log"
	( cd "$here/bld" && abc -sim "../${abcf}" ) >"$log" 2>&1 || {
		echo "FAIL: abc -sim $abcf (see $log)" >&2; return 3; }
	# The SVA channel. abc's Verilator backend runs the testbench in-process
	# and writes its $error/$fatal lines as `%Error`/`%Fatal` into THIS log --
	# and until 2026-08-13 nobody read them: every verdict of this gate is a
	# byte count, a TCODE-8 count or a decoded PC, so an assertion that fires
	# without corrupting the stream was invisible. Same rule as the xsim
	# gates, one road (ct_no_sva_errors, scripts/ct_env.sh); expectation is an
	# exact zero, measured on a healthy tree (0 matching lines in both
	# bld/synccad_*.log).
	ct_no_sva_errors "$log" || {
		echo "FAIL: assertion/fatal line(s) during $tb (see $log)" >&2; return 3; }
	local d
	d="$(find "$here/bld" -name "${tb}.atb.bin" -printf '%T@ %p\n' 2>/dev/null \
		| sort -rn | head -1 | cut -d' ' -f2-)"
	[ -n "$d" ] || { echo "FAIL: no ${tb}.atb.bin produced" >&2; return 3; }
	dirname "$d"
}

# Re-run an already built Verilator binary with plusargs (the abc flow has no
# way to pass them). Artifacts land in the .vsim dir, i.e. exactly where the
# abc run left them, so decode_and_check.sh finds them unchanged.
rerun () { # $1 = tb, $2 = sim dir, $3.. = plusargs
	local tb="$1" d="$2"; shift 2
	( cd "$d" && "./obj_${tb}/${tb}.exe" "$@" ) >"$here/bld/synccad_${tb}_rerun.log" 2>&1
	# Second simulation of this gate, same channel, same road: the plusarg
	# re-run is a separate execution of the Verilator binary and writes its
	# own log, so it needs its own check -- the build_run check above says
	# nothing about it.
	ct_no_sva_errors "$here/bld/synccad_${tb}_rerun.log" || return 1
	[ -s "$d/${tb}.atb.bin" ]
}

# Count Nexus Error messages (TCODE 8) from the raw dump. Read from -dump and
# not from -deco on purpose: a decode that aborts prints no statistics, and
# the count is exactly what tells us whether it aborted for lack of trace.
count_errors () { # $1 = sim dir, $2 = tb, $3 = tag
	local d="$1" tb="$2" tag="$3"
	"$NEXRV" -dump "$d/${tb}.atb.bin" > "$d/nexrv_${tag}_dump.log" 2>&1
	grep -ac "TCODE\[6\]=8 " "$d/nexrv_${tag}_dump.log" || true
}

# The cadence as it appears ON THE WIRE: VendorConfig PARAM1 is
# {InhibitSrc[11], InstSyncMax[10:7], InstSyncMode[6:3], InstMode[2:0]}
# (rtl/ct_L2_nexus_formatter.sv:180). Printing the field is the check that
# RDL, RTL and stream agree -- reading the source would only re-state it.
wire_cadence () { # $1 = sim dir, $2 = tag  -> "P1hex max mode"
	local d="$1" tag="$2" p1 v
	p1="$(grep -a -o 'P1\[12\]=0x[0-9a-f]*' "$d/nexrv_${tag}_dump.log" | head -1 | sed 's/.*=//')"
	[ -n "$p1" ] || { echo "none -1 -1"; return; }
	v=$((p1))
	echo "$p1 $(( (v >> 7) & 0xF )) $(( (v >> 3) & 0xF ))"
}

bits_per_instr () { awk -v b="$1" -v n="$2" 'BEGIN{ if (n>0) printf "%.3f", 8*b/n; else printf "n/a" }'; }

report_leg () { # $1 = sim dir, $2 = tb, $3 = tag
	local d="$1" tb="$2" tag="$3" bytes instrs errs
	bytes=$(wc -c < "$d/${tb}.atb.bin" | tr -d ' ')
	instrs=$(grep -c . "$d/${tb}.expected.pcs" | tr -d ' ')
	errs=$(count_errors "$d" "$tb" "$tag")
	echo "$bytes $instrs $errs"
}

# ----------------------------------------------------------------- pos ----
if [ "$mode" = full ] || [ "$mode" = pos ]; then
	echo "### leg pos -- InstSyncMax at its RESET value, sustained run"
	d="$(build_run "$pos_tb" "$tdir/${pos_tb}.abc")" || exit 3
	read -r bytes instrs errs <<<"$(report_leg "$d" "$pos_tb" pos)"
	grep -a "trTeControl =" "$here/bld/synccad_${pos_tb}.log" | tail -1 | sed 's/^/  /'
	echo "  retired instructions: $instrs | ATB bytes: $bytes | Nexus Error messages: $errs"
	echo "  bits/instruction: $(bits_per_instr "$bytes" "$instrs")"

	[ "$errs" -eq 0 ]; chk "P1: no overflow announced (TCODE 8 count = $errs)" $?
	scripts/decode_and_check.sh --pc "$pos_tb" > "$here/bld/synccad_pos_decode.log" 2>&1
	chk "P2: NexRv decodes the whole run losslessly" $?
	grep -aE 'PASS|FAIL|ERROR|decoded' "$here/bld/synccad_pos_decode.log" | tail -2 | sed 's/^/    /'

	read -r p1 wmax wmode <<<"$(wire_cadence "$d" pos)"
	echo "  VendorConfig P1[12]=$p1 -> InstSyncMax=$wmax InstSyncMode=$wmode"
	[ "$wmax" = "$rdl_max" ] && [ "$wmax" = "$rtl_max" ]
	chk "P3: RDL ($rdl_max), generated RTL ($rtl_max) and the stream ($wmax) agree on the reset cadence" $?
fi

# ----------------------------------------------------------------- neg ----
if [ "$mode" = full ] || [ "$mode" = neg ]; then
	echo "### leg neg -- COUNTER-PROOF: minimum period (+SYNCMAX=0), same workload"
	d="$(build_run "$swp_tb" "$tdir/${swp_tb}.abc")" || exit 3   # default SYNCMAX=0
	read -r bytes instrs errs <<<"$(report_leg "$d" "$swp_tb" neg)"
	grep -a "trTeControl =" "$here/bld/synccad_${swp_tb}.log" | tail -1 | sed 's/^/  /'
	echo "  retired instructions: $instrs | ATB bytes: $bytes | Nexus Error messages: $errs"
	[ "$errs" -ge 1 ]
	chk "N1: the minimum period still reproduces the stress case ($errs Error messages)" $?
fi

# --------------------------------------------------------------- sweep ----
if [ "$mode" = full ] || [ "$mode" = sweep ]; then
	echo "### sweep -- bandwidth over the period (same workload, reported)"
	d="$(build_run "$swp_tb" "$tdir/${swp_tb}.abc")" || exit 3
	printf '  %-5s %-10s %-9s %-9s %s\n' Max Periode ATB-Bytes bit/Instr TCODE-8
	for m in 0 2 4 6 8 10; do
		rerun "$swp_tb" "$d" "+SYNCMAX=$m" || { echo "  FAIL rerun SYNCMAX=$m"; verdict=1; continue; }
		read -r bytes instrs errs <<<"$(report_leg "$d" "$swp_tb" "m$m")"
		printf '  %-5s %-10s %-9s %-9s %s\n' "$m" "$((1 << (m + 4)))" "$bytes" \
			"$(bits_per_instr "$bytes" "$instrs")" "$errs"
		cp "$d/${swp_tb}.atb.bin" "$d/atb_m${m}.bin"
	done
fi

[ $verdict -eq 0 ] && echo "### SYNCCADENCE GATES PASS" || echo "### SYNCCADENCE GATES RED"
exit $verdict
