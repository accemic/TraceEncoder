#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Recovery-anchor variant (tests/overflow/09_bp_ovfanchor): a FIFO_OVERRUN
# anchor landing on a branch retire that was discarded in the emission cycle,
# combined with branch prediction. Regression guard for a class found on
# hardware: inject_hold let NOT_TAKEN_BRANCH retires through, so the outcome
# was discarded while the anchor pointed AT the branch and the decoder consumed
# an outcome the encoder never counted (BCNT/HIST shift).
# Gates:
#   A0  CONTROL run (CALM_ONLY=1 via a wrapper top): decodes cleanly and
#       transition-exactly.
#   A1  >=1 Nexus error message                 -> natural overflow reached
#   A2  InstEnBranchPrediction=1 and >=1 VendorBP -> BP path active
#   A3  NexRv "Decoded OK" AND check_transitions.py OK. "Decoded OK" on its own
#       greenwashes this class -- one hardware run decoded OK with wrong PCs.
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_python
ct_need_nexrv

tb=bp_ovfanchor_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/09_bp_ovfanchor/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
fail=0

# ---------- Leg 1: control run (CALM_ONLY=1 via a wrapper top) ----------
printf '`default_nettype none\nmodule bp_ovfanchor_calm_tb;\n  bp_ovfanchor_tb #(.CALM_ONLY(1%sb1)) u_tb ();\nendmodule\n' "'" > bp_ovfanchor_calm_wrap.sv
cp "${tb}_vlog.prj" bp_ovfanchor_calm_vlog.prj
echo 'sv xil_defaultlib "bp_ovfanchor_calm_wrap.sv"' >> bp_ovfanchor_calm_vlog.prj

rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj bp_ovfanchor_calm_vlog.prj -log xvlog_calm.log >/dev/null 2>&1 || { echo "FAIL xvlog (calm)"; grep -i error xvlog_calm.log|head; exit 4; }
xelab --relax --debug off -L uvm xil_defaultlib.bp_ovfanchor_calm_tb xil_defaultlib.glbl -s calm_snap -log xelab_calm.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (calm leg)"; grep -i "error" xelab_calm.log | head; exit 6; }
ct_no_sva_errors xelab_calm.log xsim.log || { echo "FAIL: \$error/\$fatal in calm sim log"; exit 7; }
mv "${tb}.atb.bin" calm.atb.bin
cp "${tb}.nexrv.info" calm.nexrv.info
cp "${tb}.expected.pcs" calm.expected.pcs
"$NEXRV" -deco calm.atb.bin -pcinfo calm.nexrv.info -pcout calm.pcout -bp -full > nexrv_calm.log 2>&1
if grep -aq "Decoded OK" nexrv_calm.log \
   && python "$here/scripts/check_transitions.py" calm.pcout calm.expected.pcs nexrv_calm.log > check_calm.log 2>&1; then
	echo "A0 PASS: control run decodes cleanly and transition-exactly ($(grep -ac 'PC: 0x' nexrv_calm.log) PCs)"
else
	echo "A0 FAIL: control run aborts or returns wrong PCs -- the storm leg proves nothing"
	tail -4 nexrv_calm.log; tail -4 check_calm.log 2>/dev/null
	exit 1
fi

# ---------- Leg 2: storm (natural overflow in the not-taken branch ring) ----------
rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (xelab -R)"; grep -i "error" xelab.log | head; exit 6; }
ct_no_sva_errors xelab.log xsim.log || { echo "FAIL: \$error/\$fatal in sim log"; exit 7; }

if grep -aq "InstEnBranchPrediction=1" xelab.log xsim.log 2>/dev/null; then
	echo "A2a PASS: branch prediction active"
else
	echo "A2a FAIL: branch prediction was not enabled"; fail=1
fi

"$NEXRV" -dump "${tb}.atb.bin" > "nexrv_bpova_dump.log" 2>&1
errors=$(grep -ac "TCODE\[6\]=8 " nexrv_bpova_dump.log || true)
bps=$(grep -ac "TCODE\[6\]=56 " nexrv_bpova_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.pcout" -bp -full > "nexrv_bpova.log" 2>&1
echo "NEXRV: $errors Error messages, $bps VendorBP; deco: $(grep -a 'Decoded OK' nexrv_bpova.log | tail -1)"

if [ "$errors" -ge 1 ]; then echo "A1 PASS: natural overflow reached ($errors Error messages)";
else echo "A1 FAIL: no error message -- the storm did not overflow"; fail=1; fi
if [ "$bps" -ge 1 ]; then echo "A2b PASS: VendorBP im Strom ($bps)";
else echo "A2b FAIL: no VendorBP -- the BP path never fired"; fail=1; fi

if grep -aq "Decoded OK" nexrv_bpova.log; then
	if python "$here/scripts/check_transitions.py" "${tb}.pcout" "${tb}.expected.pcs" nexrv_bpova.log > check_storm.log 2>&1; then
		echo "A3 PASS: Decoded OK and every transition legal ($(grep -ac 'PC: 0x' nexrv_bpova.log) PCs across $errors recoveries)"
	else
		echo "A3 FAIL: Decoded OK, but ILLEGAL transitions (the silently-wrong-PC signature):"
		head -6 check_storm.log
		fail=1
	fi
else
	echo "A3 FAIL: Decode abgebrochen -- $(tail -3 nexrv_bpova.log | tr '\n' ' ')"
	fail=1
fi

# ---------- Leg 3: storm with the FULL suite (the hardware configuration) ----------
printf '`default_nettype none\nmodule bp_ovfanchor_suite_tb;\n  bp_ovfanchor_tb #(.SUITE(1%sb1), .ATB_HALF_NS(40)) u_tb ();\nendmodule\n' "'" > bp_ovfanchor_suite_wrap.sv
cp "${tb}_vlog.prj" bp_ovfanchor_suite_vlog.prj
echo 'sv xil_defaultlib "bp_ovfanchor_suite_wrap.sv"' >> bp_ovfanchor_suite_vlog.prj

rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj bp_ovfanchor_suite_vlog.prj -log xvlog_suite.log >/dev/null 2>&1 || { echo "FAIL xvlog (suite)"; grep -i error xvlog_suite.log|head; exit 4; }
xelab --relax --debug off -L uvm xil_defaultlib.bp_ovfanchor_suite_tb xil_defaultlib.glbl -s suite_snap -log xelab_suite.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (suite leg)"; grep -i "error" xelab_suite.log | head; exit 6; }
ct_no_sva_errors xelab_suite.log xsim.log || { echo "FAIL: \$error/\$fatal in suite sim log"; exit 7; }
mv "${tb}.atb.bin" suite.atb.bin
cp "${tb}.nexrv.info" suite.nexrv.info
cp "${tb}.expected.pcs" suite.expected.pcs

"$NEXRV" -dump suite.atb.bin > "nexrv_suite_dump.log" 2>&1
serrors=$(grep -ac "TCODE\[6\]=8 " nexrv_suite_dump.log || true)
"$NEXRV" -deco suite.atb.bin -pcinfo suite.nexrv.info -pcout suite.pcout -bp -full > "nexrv_suite.log" 2>&1
echo "NEXRV(suite): $serrors Error messages; deco: $(grep -a 'Decoded OK' nexrv_suite.log | tail -1)"
if [ "$serrors" -ge 1 ]; then echo "A4a PASS: Overflow im Suite-Leg ($serrors)";
else echo "A4a FAIL: suite leg produced no overflow"; fail=1; fi
if grep -aq "Decoded OK" nexrv_suite.log; then
	if python "$here/scripts/check_transitions.py" suite.pcout suite.expected.pcs nexrv_suite.log > check_suite.log 2>&1; then
		echo "A4 PASS: suite leg: Decoded OK and transition-exact ($(grep -ac 'PC: 0x' nexrv_suite.log) PCs across $serrors recoveries)"
	else
		echo "A4 FAIL: Suite-Leg Decoded OK, but ILLEGAL transitions (the silently-wrong-PC signature):"
		head -6 check_suite.log
		fail=1
	fi
else
	echo "A4 FAIL: Suite-Leg Decode abgebrochen -- $(tail -3 nexrv_suite.log | tr '\n' ' ')"
	fail=1
fi

exit $fail
