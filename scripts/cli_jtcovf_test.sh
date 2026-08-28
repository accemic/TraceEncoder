#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Jump-target-cache state across an overflow recovery
# (tests/overflow/03_jtc_overflow). Regression guard for a defect found on
# hardware: after a FIFO_OVERRUN recovery the encoder kept referencing JTC
# entries whose install message fell inside the discarded window.
# Two legs, with the control run FIRST and hard:
#   J0  CONTROL run (CALM_ONLY=1, ring traffic without an overflow): must decode
#       cleanly. Red means the storm leg says nothing about the recovery, so the
#       script aborts.
#   J1  >=1 Nexus error message   -> a natural overflow was reached
#   J2  >=1 VendorJTC (TCODE 57)  -> the cache path was active at all
#   J3  NexRv "Decoded OK"        -> the guard: the encoder clears JtcValid and
#                                    the decoder re-initializes its JTC on the
#                                    FIFO_OVERRUN recovery sync
# CALM_ONLY=1 is passed through a wrapper top (calm_wrap): the Vivado .bat
# wrapper splits '-generic_top NAME=VALUE' at the '=' even when quoted, so a
# generic override
# passed on the command line never reaches xelab on Windows.
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=jtc_ovf_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/03_jtc_overflow/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
fail=0

# ---------- Leg 1: control run (CALM_ONLY=1 via a wrapper top) ----------
printf '`default_nettype none\nmodule jtc_ovf_calm_tb;\n  jtc_ovf_tb #(.CALM_ONLY(1%sb1)) u_tb ();\nendmodule\n' "'" > jtc_ovf_calm_wrap.sv
cp "${tb}_vlog.prj" jtc_ovf_calm_vlog.prj
echo 'sv xil_defaultlib "jtc_ovf_calm_wrap.sv"' >> jtc_ovf_calm_vlog.prj

rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj jtc_ovf_calm_vlog.prj -log xvlog_calm.log >/dev/null 2>&1 || { echo "FAIL xvlog (calm)"; grep -i error xvlog_calm.log|head; exit 4; }
xelab --relax --debug off -L uvm xil_defaultlib.jtc_ovf_calm_tb xil_defaultlib.glbl -s calm_snap -log xelab_calm.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (calm leg)"; grep -i "error" xelab_calm.log | head; exit 6; }
ct_no_sva_errors xelab_calm.log xsim.log || { echo "FAIL: \$error/\$fatal in calm sim log"; exit 7; }
mv "${tb}.atb.bin" calm.atb.bin
cp "${tb}.nexrv.info" calm.nexrv.info
"$NEXRV" -deco calm.atb.bin -pcinfo calm.nexrv.info -pcout calm.pcout -full > nexrv_calm.log 2>&1
if grep -aq "Decoded OK" nexrv_calm.log; then
	echo "J0 PASS: control run without overflow decodes cleanly ($(grep -ac 'PC: 0x' nexrv_calm.log) PCs)"
else
	echo "J0 FAIL: control run aborts -- the storm leg proves nothing"
	tail -4 nexrv_calm.log
	exit 1
fi

# ---------- Leg 2: storm (natural overflow during ring traffic) ----------
rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
# xelab -R (compile+run in one): the separate xsim.exe snapshot load hangs
# 2022.1 on this TB (empty hs_err stub, log frozen before TB start) — the
# in-process runner is immune. Sim output lands in xsim.log.
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (xelab -R)"; grep -i "error" xelab.log | head; exit 6; }
ct_no_sva_errors xelab.log xsim.log || { echo "FAIL: \$error/\$fatal in sim log"; exit 7; }
grep -a "slot balance" xelab.log xsim.log 2>/dev/null | tail -1

# Error count from -dump (robust: the -deco pass aborts on the wedge and
# then prints no Stat line).
"$NEXRV" -dump "${tb}.atb.bin" > "nexrv_jtcovf_dump.log" 2>&1
errors=$(grep -ac "TCODE\[6\]=8 " nexrv_jtcovf_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.pcout" -full > "nexrv_jtcovf.log" 2>&1
echo "NEXRV: $errors Error messages (from -dump); deco: $(grep -a 'Decoded OK' nexrv_jtcovf.log | tail -1)"

jtc=$(grep -ac "TCODE\[6\]=57 " nexrv_jtcovf_dump.log || true)
if [ "$errors" -ge 1 ]; then echo "J1 PASS: natural overflow reached ($errors error messages)";
else echo "J1 FAIL: no error message -- the storm did not overflow"; fail=1; fi

if [ "$jtc" -ge 1 ]; then echo "J2 PASS: JTC path active ($jtc VendorJTC messages)";
else echo "J2 FAIL: no VendorJTC message -- ring or feature misconfigured"; fail=1; fi

if grep -aq "Decoded OK" nexrv_jtcovf.log; then echo "J3 PASS: Decoded OK ($(grep -ac 'PC: 0x' nexrv_jtcovf.log) PCs across the overflow recovery)";
else
  echo "J3 FAIL: Decode abgebrochen -- $(tail -3 nexrv_jtcovf.log | tr '\n' ' ')"
  fail=1
fi

exit $fail
