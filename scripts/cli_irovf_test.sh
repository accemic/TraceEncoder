#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Implicit-return stack across an overflow recovery
# (tests/overflow/04_ir_overflow). Regression guard for the "not enough entries
# on callstack" class found in hardware soak runs: calls and returns inside the
# drop window mutate the encoder's return stack while the decoder clears its
# own stack on the error message, so stale frames flag returns as "implicit"
# that the decoder cannot follow.
# Gates:
#   I0  CONTROL run (CALM_ONLY=1 via a wrapper top): must decode cleanly.
#   I1  >=1 Nexus error message            -> natural overflow reached
#   I2  InstEnImplicitReturn=1 in the log  -> the feature really was on
#   I3  NexRv "Decoded OK"                 -> the guard: ret_sp cleared at the
#                                             FIFO_OVERRUN anchor
#                                             (composer_etip)
# A wrapper top is used instead of '-generic_top NAME=VALUE': the Vivado .bat
# wrapper splits at the '=' even when quoted, so a generic override never
# reaches xelab on Windows.
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=ir_ovf_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/04_ir_overflow/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
fail=0

# ---------- Leg 1: control run (CALM_ONLY=1 via a wrapper top) ----------
printf '`default_nettype none\nmodule ir_ovf_calm_tb;\n  ir_ovf_tb #(.CALM_ONLY(1%sb1)) u_tb ();\nendmodule\n' "'" > ir_ovf_calm_wrap.sv
cp "${tb}_vlog.prj" ir_ovf_calm_vlog.prj
echo 'sv xil_defaultlib "ir_ovf_calm_wrap.sv"' >> ir_ovf_calm_vlog.prj

rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj ir_ovf_calm_vlog.prj -log xvlog_calm.log >/dev/null 2>&1 || { echo "FAIL xvlog (calm)"; grep -i error xvlog_calm.log|head; exit 4; }
xelab --relax --debug off -L uvm xil_defaultlib.ir_ovf_calm_tb xil_defaultlib.glbl -s calm_snap -log xelab_calm.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (calm leg)"; grep -i "error" xelab_calm.log | head; exit 6; }
ct_no_sva_errors xelab_calm.log xsim.log || { echo "FAIL: \$error/\$fatal in calm sim log"; exit 7; }
mv "${tb}.atb.bin" calm.atb.bin
cp "${tb}.nexrv.info" calm.nexrv.info
"$NEXRV" -deco calm.atb.bin -pcinfo calm.nexrv.info -pcout calm.pcout -full > nexrv_calm.log 2>&1
if grep -aq "Decoded OK" nexrv_calm.log; then
	echo "I0 PASS: control run without overflow decodes cleanly ($(grep -ac 'PC: 0x' nexrv_calm.log) PCs)"
else
	echo "I0 FAIL: control run aborts -- the storm leg proves nothing"
	tail -4 nexrv_calm.log
	exit 1
fi

# ---------- Leg 2: storm (natural overflow in the call/return ring) ----------
rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (xelab -R)"; grep -i "error" xelab.log | head; exit 6; }
ct_no_sva_errors xelab.log xsim.log || { echo "FAIL: \$error/\$fatal in sim log"; exit 7; }
grep -a "slot balance" xelab.log xsim.log 2>/dev/null | tail -1

if grep -aq "InstEnImplicitReturn=1" xelab.log xsim.log 2>/dev/null; then
	echo "I2 PASS: implicit return active"
else
	echo "I2 FAIL: implicit return was not enabled"; fail=1
fi

"$NEXRV" -dump "${tb}.atb.bin" > "nexrv_irovf_dump.log" 2>&1
errors=$(grep -ac "TCODE\[6\]=8 " nexrv_irovf_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.pcout" -full > "nexrv_irovf.log" 2>&1
echo "NEXRV: $errors Error messages (from -dump); deco: $(grep -a 'Decoded OK' nexrv_irovf.log | tail -1)"

if [ "$errors" -ge 1 ]; then echo "I1 PASS: natural overflow reached ($errors Error messages)";
else echo "I1 FAIL: no error message -- the storm did not overflow"; fail=1; fi

if grep -aq "Decoded OK" nexrv_irovf.log; then echo "I3 PASS: Decoded OK ($(grep -ac 'PC: 0x' nexrv_irovf.log) PCs across the overflow recovery)";
else
  echo "I3 FAIL: Decode abgebrochen -- $(tail -3 nexrv_irovf.log | tr '\n' ' ')"
  fail=1
fi

exit $fail
