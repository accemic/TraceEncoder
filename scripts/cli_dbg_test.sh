#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# B1 debug/power/EVTI verification (seq 24; local bring-up aid, cli_* pattern).
# Runs tests/instruction/12_debug_power_events, decodes with NexRv and gates:
#   - decode_and_check.sh --pc (HARD, strict full match: debug-window PCs in
#     neither stream nor reference)
#   - SYNC[4]=0x3 (exit from debug), 0x9 (exit from powerdown), 0x0 (EVTI
#     marker) each present in the -full decode
#   - Correlation EVCODE 0x0 (debug entry), 0x1 (low-power entry), 0x4
#     (trace-off) each present
# Self-contained: clones the 07 test's xsim .prj (abc @-resolver broken in
# the vendored tree). NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=debug_events_tb
src_tb=repeated_history_tb   # donor project (same env, same libs)

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/12_debug_power_events/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl
ct_xsim xsim.log "${tb}_snap" -tclbatch _runall.tcl || exit 6
cp -f xsim.log "${tb}.sim.log" 2>/dev/null || true
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin"; exit 6; }
cp "${tb}.atb.bin" "atb_dbg.bin"

"$NEXRV" -deco "atb_dbg.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.dbg.pcout" -full > "nexrv_dbg.log" 2>&1

verdict=0
chk () { # $1 = label, $2 = grep pattern, $3 = min count
	local n
	n=$(grep -cE "$2" nexrv_dbg.log || true)
	if [ "$n" -ge "$3" ]; then
		echo "$1 : PASS ($n found)"
	else
		echo "$1 : FAIL (need >= $3, got $n)"; verdict=1
	fi
}

echo "======================================================"
chk "SYNC=3 exit-from-debug      " 'SYNC\[4\]=0x3\b' 1
chk "SYNC=9 exit-from-powerdown  " 'SYNC\[4\]=0x9\b' 1
chk "SYNC=0 EVTI marker          " 'SYNC\[4\]=0x0\b' 1
chk "EVCODE=0 debug-entry corr   " 'EVCODE\[4\]=0x0\b' 1
chk "EVCODE=1 low-power corr     " 'EVCODE\[4\]=0x1\b' 1
chk "EVCODE=4 trace-off corr     " 'EVCODE\[4\]=0x4\b' 1
echo "------------------------------------------------------"

cd "$here"
if scripts/decode_and_check.sh --pc "$tb"; then
	echo "PC lossless                  : PASS"
else
	echo "PC lossless                  : FAIL"; verdict=1
fi
echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
