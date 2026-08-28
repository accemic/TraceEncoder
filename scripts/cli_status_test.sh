#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P4 status-message verification (Device ID TCODE 1 + Watchpoint TCODE 15).
# Runs tests/instruction/31_status_msgs seven times:
#   off    : reset defaults          -> no TCODE 1, no TCODE 15 (runtime-off)
#   did    : SendDeviceId=DID_ONCE   -> exactly one TCODE 1 as MSG #0, ID ==
#                                       the CT_DEVICE_ID parameter
#   didoff : illegal SendDeviceId=2  -> WARL legalizes to DID_NONE, no TCODE 1
#   wp     : WEM=0xFFFF              -> three TCODE 15 (WPHIT 1 / 2 / 8001)
#   wpmask : WEM=0x0002              -> exactly ONE TCODE 15 (WPHIT 2)
#   both   : DID + WEM + Context     -> both messages plus ownership pressure
#   src    : like both, InhibitSrc=0 -> both messages carry the SRC field
#   didtwice: DID + a trace pause    -> TWO TCODE 1 (DID_ONCE fires on EVERY
#                                       trace-on edge, not once per session)
#   wpaxis : WEM + the 3rd command on ACT_CAP_ST_SINK_AXIS_NEXUS -> the
#                                       stream must stay byte-identical to wp
#   wpdaq  : WEM + the 2nd command is a DAQ command -> two TCODE 15 AND one
#                                       TCODE 7 in ONE run (the only leg that
#                                       exercises a_p4_wp_daq_exclusive with a
#                                       design that really raises DAQ slots)
# All legs must decode PC-lossless against the same reference, and no leg may
# produce a Data Acquisition message (the watchpoint command must not fall
# through into the DAQ arm).
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=status_msgs_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/31_status_msgs/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_sim () { # $1 = tag, $2... = extra xsim args
	local tag="$1"; shift
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin" "atb_${tag}.bin"
}
deco () { # $1 = atb tag, $2 = out tag, $3... = extra NexRv args
	local atag="$1" otag="$2"; shift 2
	"$NEXRV" -deco "atb_${atag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${otag}.pcout" "$@" -full > "nexrv_${otag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${otag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${otag}.pcs"
}

echo "### run OFF   ";  run_sim off;                              deco off    off
echo "### run DID   ";  run_sim did    -testplusarg DIDLEG;       deco did    did
echo "### run DIDOFF";  run_sim didoff -testplusarg DIDOFFLEG;    deco didoff didoff
echo "### run WP    ";  run_sim wp     -testplusarg WPLEG;        deco wp     wp
echo "### run WPMASK";  run_sim wpmask -testplusarg WPMASKLEG;    deco wpmask wpmask
echo "### run BOTH  ";  run_sim both   -testplusarg BOTHLEG;      deco both   both
echo "### run SRC   ";  run_sim src    -testplusarg SRCLEG;       deco src    src -src 4
echo "### run DID2  ";  run_sim didtwice -testplusarg DIDTWICELEG; deco didtwice didtwice
echo "### run WPAXIS";  run_sim wpaxis -testplusarg WPAXISLEG;    deco wpaxis wpaxis
echo "### run WPDAQ ";  run_sim wpdaq  -testplusarg WPDAQLEG;     deco wpdaq  wpdaq

exp="${tb}.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp" > exp.norm
for t in off did didoff wp wpmask both src didtwice wpaxis wpdaq; do norm "$t.pcs" > "$t.norm"; done
n_exp=$(grep -c . exp.norm)

cnt () { grep -cE "$1" "$2" || true; }

verdict=0
chk_pfx () { # $1 = tag; PC-lossless vs reference (full-length prefix match)
	local n; n=$(grep -c . "$1.norm")
	local m=$(( n < n_exp ? n : n_exp ))
	if [ "$m" -gt 20 ] && head -n "$m" exp.norm | cmp -s - <(head -n "$m" "$1.norm"); then
		echo "$1 lossless ($m PCs)      : PASS"
	else
		echo "$1 lossless               : FAIL (n=$n exp=$n_exp)"; verdict=1
	fi
}
chk () { # $1 = label, $2 = actual, $3 = expected
	if [ "$2" = "$3" ]; then printf '%-40s: PASS (%s)\n' "$1" "$2"
	else printf '%-40s: FAIL (got %s, want %s)\n' "$1" "$2" "$3"; verdict=1; fi
}

echo "======================================================"
echo "expected PCs: $n_exp"
echo "------------------------------------------------------"
# --- simulator-side assertions are part of the verdict --------------------
# xsim writes $error/$fatal into the per-leg log, and the runs above are
# silenced (>/dev/null). Without this scan an RTL assertion -- e.g. the
# composer's eTIP slot bound, whose violation drops messages silently --
# fires into a file nobody reads and the gate still says PASS. The P4 audit
# found exactly that hole (finding A-1).
for t in off did didoff wp wpmask both src didtwice wpaxis wpdaq; do
	n=$(grep -cE '^(Error|Fatal):' "xsim_${t}.log" || true)
	if [ "$n" != "0" ]; then
		printf '%-40s: FAIL (%s)\n' "no RTL assertion fired ($t)" "$n"
		grep -m1 -E '^(Error|Fatal):' "xsim_${t}.log"
		verdict=1
	else
		printf '%-40s: PASS (0)\n' "no RTL assertion fired ($t)"
	fi
done
echo "------------------------------------------------------"
for t in off did didoff wp wpmask both src didtwice wpaxis wpdaq; do chk_pfx "$t"; done
echo "------------------------------------------------------"
# --- Device ID (TCODE 1) --------------------------------------------------
chk "OFF has no TCODE 1"        "$(cnt 'TCODE\[6\]=1 ' nexrv_off.log)"    0
chk "DIDOFF (WARL) has no TCODE 1" "$(cnt 'TCODE\[6\]=1 ' nexrv_didoff.log)" 0
chk "DID exactly one TCODE 1"   "$(cnt 'TCODE\[6\]=1 ' nexrv_did.log)"    1
chk "DID TCODE 1 is MSG #0"     "$(cnt 'TCODE\[6\]=1 \(MSG #0\)' nexrv_did.log)" 1
chk "DID ID == CT_DEVICE_ID"    "$(cnt '\. DEVID 0xacce5001' nexrv_did.log)" 1
chk "BOTH: TCODE 1 before 58"   "$(awk '/TCODE\[6\]=1 /{d=NR} /TCODE\[6\]=58 /{c=NR} END{print (d>0 && c>0 && d<c) ? 1 : 0}' nexrv_both.log)" 1
# --- Watchpoint (TCODE 15) ------------------------------------------------
chk "OFF has no TCODE 15"       "$(cnt 'TCODE\[6\]=15 ' nexrv_off.log)"   0
chk "DID has no TCODE 15"       "$(cnt 'TCODE\[6\]=15 ' nexrv_did.log)"   0
chk "WP three TCODE 15"         "$(cnt 'TCODE\[6\]=15 ' nexrv_wp.log)"    3
chk "WP WPHIT 0x0001"           "$(cnt '\. WPHIT 0x0001' nexrv_wp.log)"   1
chk "WP WPHIT 0x0002"           "$(cnt '\. WPHIT 0x0002' nexrv_wp.log)"   1
chk "WP WPHIT 0x8001"           "$(cnt '\. WPHIT 0x8001' nexrv_wp.log)"   1
chk "WPMASK exactly one TCODE 15" "$(cnt 'TCODE\[6\]=15 ' nexrv_wpmask.log)" 1
chk "WPMASK WPHIT 0x0002 only"  "$(cnt '\. WPHIT 0x0002' nexrv_wpmask.log)" 1
chk "BOTH three TCODE 15"       "$(cnt 'TCODE\[6\]=15 ' nexrv_both.log)"  3
chk "SRC three TCODE 15"        "$(cnt 'TCODE\[6\]=15 ' nexrv_src.log)"   3
chk "SRC one TCODE 1"           "$(cnt 'TCODE\[6\]=1 ' nexrv_src.log)"    1
# --- second trace-on edge: DID_ONCE is per EDGE, not per session -----------
# The correlation message (TCODE 33) is the proof that the pause really
# happened -- without it the "two Device IDs" check would be vacuous.
chk "DIDTWICE two TCODE 1"      "$(cnt 'TCODE\[6\]=1 ' nexrv_didtwice.log)" 2
chk "DIDTWICE pause happened (33)" "$(( $(cnt 'TCODE\[6\]=33 ' nexrv_didtwice.log) > 0 ? 1 : 0 ))" 1
# --- the second legal sink of the watchpoint arm ---------------------------
# Same program, same commands, only the third command's Sink differs: the
# sink routes the ACT payload, it does not touch the Nexus message, so the
# whole stream must come out byte-identical to the wp leg.
chk "WPAXIS three TCODE 15"     "$(cnt 'TCODE\[6\]=15 ' nexrv_wpaxis.log)"  3
chk "WPAXIS WPHIT 0x8001"       "$(cnt '\. WPHIT 0x8001' nexrv_wpaxis.log)" 1
if cmp -s atb_wp.bin atb_wpaxis.bin; then
	printf '%-40s: PASS\n' "WPAXIS stream == WP stream (sink-neutral)"
else
	printf '%-40s: FAIL\n' "WPAXIS stream == WP stream (sink-neutral)"; verdict=1
fi
# --- the watchpoint command must not also produce a DAQ message ------------
# (wpdaq is excluded on purpose: there the SECOND command IS a DAQ command.)
for t in off did wp wpmask both src didtwice wpaxis; do
	chk "no DAQ message ($t)"   "$(cnt 'TCODE\[6\]=7 ' nexrv_$t.log)"     0
done
# --- slot sharing (A-2 cost argument), measured instead of argued ----------
# The wpdaq leg carries BOTH message kinds, so the composer's
# a_p4_wp_daq_exclusive property is checked against a design that really
# raises DAQ slots -- and the per-run watermark below shows that the beat
# demand does NOT grow when the two kinds coexist.
chk "WPDAQ two TCODE 15"        "$(cnt 'TCODE\[6\]=15 ' nexrv_wpdaq.log)"  2
chk "WPDAQ WPHIT 0x0001"        "$(cnt '\. WPHIT 0x0001' nexrv_wpdaq.log)"  1
chk "WPDAQ WPHIT 0x8001"        "$(cnt '\. WPHIT 0x8001' nexrv_wpdaq.log)"  1
chk "WPDAQ exactly one DAQ (7)" "$(cnt 'TCODE\[6\]=7 ' nexrv_wpdaq.log)"   1
# --- ownership coexists (both/src legs run with Context=1) -----------------
chk "BOTH has ownership (TCODE 2)" "$(( $(cnt 'TCODE\[6\]=2 ' nexrv_both.log) > 0 ? 1 : 0 ))" 1
# --- flow neutrality: the decoder's -pcout file is BYTE-identical with and
#     without the new messages (stronger than the normalized PC compare) ----
for t in did didoff wp wpmask both src didtwice wpaxis wpdaq; do
	if cmp -s "${tb}.off.pcout" "${tb}.${t}.pcout"; then
		printf '%-40s: PASS\n' "pcout byte-identical to off ($t)"
	else
		printf '%-40s: FAIL\n' "pcout byte-identical to off ($t)"; verdict=1
	fi
done
# --- CTXP export + TSTAMP accumulation on the wp leg -----------------------
# The Watchpoint message is exported as a CTXP record (WPHIT in value2); both
# new messages are NON-synchronizing, so their TSTAMP is a delta the decoder
# must accumulate. A wrong/absent accumulation shows up as a non-monotonic or
# all-zero timestamp column here (the Ownership arm carried exactly that bug
# until 2026-08-04).
CTXP_TEXT_TRACEFILE="wp.ctxp.txt" "$NEXRV" -deco atb_wp.bin -pcinfo "${tb}.nexrv.info" \
	-pcout /dev/null -none > nexrv_wp_ctxp.log 2>&1 || true
chk "CTXP WATCHPOINT records"    "$(cnt '^#0:WATCHPOINT::' wp.ctxp.txt)"        3
chk "CTXP WPHIT values"          "$(cnt '^#0:WATCHPOINT::0x(1|2|8001) @' wp.ctxp.txt)" 3
ts_seq=$(grep -vE '^(HDR|META):' wp.ctxp.txt | sed -nE 's/.*@[[:space:]]*([0-9]+)[[:space:]]*$/\1/p')
ts_max=$(printf '%s\n' "$ts_seq" | sort -n | tail -1)
if [ -n "$ts_max" ] && [ "$ts_max" -gt 0 ] \
   && printf '%s\n' "$ts_seq" | awk 'NR>1 && $1 < prev { bad=1 } { prev=$1 } END { exit bad }'; then
	printf '%-40s: PASS (max=%s over %s records)\n' "CTXP timestamps monotonic > 0" \
		"$ts_max" "$(printf '%s\n' "$ts_seq" | grep -c .)"
else
	printf '%-40s: FAIL (max=%s)\n' "CTXP timestamps monotonic > 0" "$ts_max"; verdict=1
fi
echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
