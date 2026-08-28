#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# JTC x periodic sync x backpressure x InstTracing going low on a running core
# (tests/overflow/13_jtc_stopdrain). Teil-Soak-Klasse 2026-08-01 (soak/00056):
# a stale VendorJTC overtakes the sync / ResourceFull at the stop drain, the
# decoder re-bases on the sync and dies ("resolved source PC to a non-indirect
# instruction").
# Gates:
#   J0  Control run (throttle off): "Decoded OK" and transition-exact
#   J1  >=1 error message   -> overflow / backpressure pressure present
#   J2  >=100 VendorJTC     -> the JTC path carries the stream
#   J3  Decoded OK and every transition legal (= Klassen-Guard)
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_python
ct_need_nexrv

tb=jtc_stopdrain_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/13_jtc_stopdrain/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
fail=0

# ---- Leg 1: control run (throttle off) --------------------------------------
printf '`default_nettype none\nmodule jtc_stopdrain_calm_tb;\n  jtc_stopdrain_tb #(.ATB_HALF_NS(5)) u_tb ();\nendmodule\n' > jtc_stopdrain_calm_wrap.sv
cp "${tb}_vlog.prj" jtc_stopdrain_calm_vlog.prj
echo 'sv xil_defaultlib "jtc_stopdrain_calm_wrap.sv"' >> jtc_stopdrain_calm_vlog.prj

rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj jtc_stopdrain_calm_vlog.prj -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog (calm)"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm xil_defaultlib.jtc_stopdrain_calm_tb xil_defaultlib.glbl -s calm_snap -log xelab_calm.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (control run)"; grep -iE "^ERROR|Error:" xelab_calm.log 2>/dev/null | head; exit 6; }
# V2-F1: xsim.log, not just xelab_calm.log -- the latter is elaboration only.
ct_no_sva_errors xelab_calm.log xsim.log || { echo "FAIL: \$error/\$fatal im Kontroll-Leg"; fail=1; }
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout calm.pcout -full > calm_deco.log 2>&1
if grep -aq "Decoded OK" calm_deco.log \
   && python3 "$here/scripts/check_transitions.py" calm.pcout "${tb}.expected.pcs" calm_deco.log >/dev/null 2>&1; then
	echo "J0 PASS: control run decodes transition-exactly ($(grep -ac 'PC: 0x' calm_deco.log) PCs)"
else
	echo "J0 FAIL: control run is red"; tail -3 calm_deco.log; fail=1
fi

# ---- Leg 2: storm (40 ns throttle + stop edges) -----------------------------
rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (storm leg)"; grep -iE "^ERROR|Error:" xelab.log 2>/dev/null | head; exit 6; }
ct_no_sva_errors xelab.log xsim.log || { echo "FAIL: \$error/\$fatal in the storm leg (SVA?)"; fail=1; }

"$NEXRV" -dump "${tb}.atb.bin" > storm_dump.log 2>&1
errs=$(grep -ac "TCODE\[6\]=8 " storm_dump.log || true)
jtcs=$(grep -ac "VendorJTC" storm_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout storm.pcout -full > storm_deco.log 2>&1
echo "NEXRV: $errs Error messages, $jtcs VendorJTC; deco: $(grep -a 'Decoded OK' storm_deco.log | tail -1)"

if [ "$errs" -ge 1 ]; then echo "J1 PASS: pressure present ($errs Error messages)";
else echo "J1 FAIL: no overflow"; fail=1; fi
if [ "$jtcs" -ge 100 ]; then echo "J2 PASS: JTC path active ($jtcs VendorJTC)";
else echo "J2 FAIL: zu wenig JTC ($jtcs)"; fail=1; fi
if grep -aq "Decoded OK" storm_deco.log \
   && python3 "$here/scripts/check_transitions.py" storm.pcout "${tb}.expected.pcs" storm_deco.log >/dev/null 2>&1; then
	echo "J3 PASS: Decoded OK and every transition legal ($(grep -ac 'PC: 0x' storm_deco.log) PCs)"
else
	echo "J3 FAIL (= Klasse REPRODUZIERT?): $(tail -3 storm_deco.log | tr '\n' ' ' | cut -c1-160)"; fail=1
fi

exit $fail
