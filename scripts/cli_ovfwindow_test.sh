#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Cross-term guard: window edge x FIFO overflow x BP/JTC x dense periodic sync
# (tests/overflow/14_ovf_window). Found in hardware soak replays (
# randomized soak replays): "IBH resolved source to non-indirect", where the
# encoder undercounts six half-words at the FIFO_OVERRUN anchor, and an "ICNT
# adjustment ERROR" caused by a return JTC swallowed at the stop drain.
# Gates:
#   W0  Control leg (+NO_WINDOW): overflow + BP/JTC + dense sync WITHOUT
#       windows -> green (single-factor falsification; gates 09/10 cover it)
#   W1  Window leg: >=1 Nexus error message       -> overflow regime active
#   W2  Window leg: >=1 VendorBP and >=4 correlations -> cross term active
#   W3  NexRv "Decoded OK" (-bp) AND check_transitions legal
#       -- red means the class has regressed
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_python
ct_need_nexrv

tb=ovf_window_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/14_ovf_window/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
fail=0

# ---- Compile + Elaboration (EINMAL; Legs via xsim -testplusarg) -------------
rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -iE "^ERROR" xelab.log | head; exit 5; }

# ---- Leg A: control run (+NO_WINDOW): overflow x BP/JTC x dense sync, no windows ---
ct_xsim xsim_nw.log "${tb}_snap" -R -testplusarg NO_WINDOW || exit 6
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (Kontroll-Leg)"; grep -i "error" xsim_nw.log 2>/dev/null | head; exit 6; }
"$NEXRV" -dump "${tb}.atb.bin" > nw_dump.log 2>&1
nw_err=$(grep -ac "TCODE\[6\]=8 " nw_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout nw.pcout -bp -full > nw_deco.log 2>&1
nw_ok=0
grep -aq "Decoded OK" nw_deco.log && nw_ok=1
python3 "$here/scripts/check_transitions.py" nw.pcout "${tb}.expected.pcs" nw_deco.log > nw_trans.log 2>&1
nw_trans=$?
if [ "$nw_ok" -eq 1 ] && [ "$nw_trans" -eq 0 ] && [ "$nw_err" -ge 1 ]; then
	echo "W0 PASS: control leg: Decoded OK + transitions legal ($nw_err Overflow-Errors)"
else
	echo "W0 FAIL: Kontroll-Leg ok=$nw_ok trans=$nw_trans err=$nw_err deco=$(tail -2 nw_deco.log|tr '\n' ' ')"
	tail -3 nw_trans.log; fail=1
fi

# ---- Leg B: windows ---------------------------------------------------------
rm -f "${tb}.atb.bin"
ct_xsim xsim.log "${tb}_snap" -R || exit 6
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (window leg)"; grep -i "error" xsim.log 2>/dev/null | head; exit 6; }

"$NEXRV" -dump "${tb}.atb.bin" > w_dump.log 2>&1
w_err=$(grep -ac "TCODE\[6\]=8 " w_dump.log || true)
w_bp=$(grep -ac "TCODE\[6\]=56 " w_dump.log || true)
w_corr=$(grep -ac "TCODE\[6\]=33 " w_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout w.pcout -bp -full > w_deco.log 2>&1
echo "NEXRV: $w_err Errors, $w_bp VendorBP, $w_corr Correlations; deco: $(grep -a 'Decoded OK' w_deco.log | tail -1)"

if [ "$w_err" -ge 1 ]; then echo "W1 PASS: $w_err error messages (overflow regime active)";
else echo "W1 FAIL: no overflow reached -- increase the throttle or the workload"; fail=1; fi

if [ "$w_bp" -ge 1 ] && [ "$w_corr" -ge 4 ]; then echo "W2 PASS: $w_bp VendorBP, $w_corr correlations (cross term active)";
else echo "W2 FAIL: bp=$w_bp corr=$w_corr -- the cross-term stimulus had no effect"; fail=1; fi

w_ok=0
grep -aq "Decoded OK" w_deco.log && w_ok=1
python3 "$here/scripts/check_transitions.py" w.pcout "${tb}.expected.pcs" w_deco.log > w_trans.log 2>&1
w_trans=$?
if [ "$w_ok" -eq 1 ] && [ "$w_trans" -eq 0 ]; then
	echo "W3 PASS: Decoded OK ($(grep -ac 'PC: 0x' w_deco.log) PCs) + transitions legal"
else
	echo "W3 FAIL (= Klasse REPRODUZIERT?): ok=$w_ok trans=$w_trans"
	tail -3 w_deco.log | tr '\n' ' '; echo
	tail -3 w_trans.log
	fail=1
fi

exit $fail
