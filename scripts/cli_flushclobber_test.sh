#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Flush-clobber guard (tests/overflow/15_flush_clobber): ATB flush pulses in
# the middle of a dense JTC stream under backpressure. Found on hardware as a
# silent single-message loss -- one JTC hit vanished and the target ring
# slipped by one position. Mechanism: written as a trailing if,
# send_flush_msg() overwrote the message composed in the same cycle. The same
# mechanism is the candidate behind the losses seen at enable-off edges
# (do_flush = atb_afvalid || EnableFall || CorrDisable).
# Gates:
#   F0  Control leg (+NO_FLUSH): ring x throttle x periodic sync -> green
#   F1  Flush leg: >=1 VendorJTC and >=1 VendorBP -> stimulus active
#   F2  NexRv "Decoded OK" (-bp) AND check_transitions legal.
#       Red -- a ring slip or an illegal transition -- means a regression.
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_python
ct_need_nexrv

tb=flush_clobber_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/15_flush_clobber/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
fail=0

# ---- Compile + Elaboration (EINMAL; Legs via xsim -testplusarg) -------------
rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -iE "^ERROR" xelab.log | head; exit 5; }

# ---- Leg A: control run (+NO_FLUSH) -----------------------------------------
ct_xsim xsim_nf.log "${tb}_snap" -R -testplusarg NO_FLUSH || exit 6
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (Kontroll-Leg)"; grep -i "error" xsim_nf.log 2>/dev/null | head; exit 6; }
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout nf.pcout -bp -full > nf_deco.log 2>&1
nf_ok=0; grep -aq "Decoded OK" nf_deco.log && nf_ok=1
python3 "$here/scripts/check_transitions.py" nf.pcout "${tb}.expected.pcs" nf_deco.log > nf_trans.log 2>&1
nf_trans=$?
if [ "$nf_ok" -eq 1 ] && [ "$nf_trans" -eq 0 ]; then
	echo "F0 PASS: control leg: Decoded OK + transitions legal"
else
	echo "F0 FAIL: ok=$nf_ok trans=$nf_trans deco=$(tail -2 nf_deco.log|tr '\n' ' ')"; tail -3 nf_trans.log; fail=1
fi

# ---- Leg B: flush pulses in mid-stream --------------------------------------
rm -f "${tb}.atb.bin"
ct_xsim xsim.log "${tb}_snap" -R || exit 6
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (Flush-Leg)"; grep -i "error" xsim.log 2>/dev/null | head; exit 6; }
"$NEXRV" -dump "${tb}.atb.bin" > f_dump.log 2>&1
f_jtc=$(grep -ac "TCODE\[6\]=57 " f_dump.log || true)
f_bp=$(grep -ac "TCODE\[6\]=56 " f_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout f.pcout -bp -full > f_deco.log 2>&1
echo "NEXRV: $f_jtc VendorJTC, $f_bp VendorBP; deco: $(grep -a 'Decoded OK' f_deco.log | tail -1)"

if [ "$f_jtc" -ge 1 ] && [ "$f_bp" -ge 0 ]; then echo "F1 PASS: $f_jtc VendorJTC (JTC density reached)";
else echo "F1 FAIL: jtc=$f_jtc -- Stimulus wirkungslos"; fail=1; fi

f_ok=0; grep -aq "Decoded OK" f_deco.log && f_ok=1
python3 "$here/scripts/check_transitions.py" f.pcout "${tb}.expected.pcs" f_deco.log > f_trans.log 2>&1
f_trans=$?
if [ "$f_ok" -eq 1 ] && [ "$f_trans" -eq 0 ]; then
	echo "F2 PASS: Decoded OK ($(grep -ac 'PC: 0x' f_deco.log) PCs) + transitions legal"
else
	echo "F2 FAIL (= Klasse REPRODUZIERT?): ok=$f_ok trans=$f_trans"
	tail -3 f_deco.log | tr '\n' ' '; echo
	tail -3 f_trans.log
	fail=1
fi

exit $fail
