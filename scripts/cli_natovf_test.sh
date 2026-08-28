#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Natural-overflow reproducer gate (tests/overflow/02_natural_overflow,
# cli_* pattern; first found on a KV260 SoC integration flow). Gates:
#   G1  >=1 Nexus Error message      -> natural overflow actually reached
#   G2  NexRv "Decoded OK"           -> the regression guard
#   G3  no wedge: at most 3x as many Error messages as storm bursts would
#       justify per episode-with-thrash-free recovery (heuristic: errors
#       must NOT exceed 40; the wedge produces hundreds, load-invariantly)
# Repro coverage note: this testbench reproduces facet (a) of the original
# finding, a decode abort after the first natural overflow. Facet (b), the
# persistent load-invariant drop-recover cycle, has only ever been observed on
# the KV260 SoC integration flow, whose own gate stays the final arbiter.
# Self-contained: clones the overrun test's xsim .prj. NOT for upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=natural_ovf_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/02_natural_overflow/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
# xelab -R (compile+run in one): the separate xsim.exe snapshot load hangs
# 2022.1 on this TB (empty hs_err stub, log frozen before TB start) — the
# in-process runner is immune. Sim output lands in xelab.log.
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (xelab -R)"; grep -i "error" xelab.log | head; exit 6; }
# V2-F1: this used to grep xelab.log -- the ELABORATION transcript. The run
# that `xelab -R` spawns writes xsim.log, so the check could never see an
# $error and `slot balance` never printed either (0 hits, measured).
ct_no_sva_errors xelab.log xsim.log || { echo "FAIL: \$error/\$fatal in sim log"; exit 7; }
grep -a "slot balance" xsim.log | tail -1

# Error count from -dump (robust: the -deco pass aborts on the wedge and
# then prints no Stat line).
"$NEXRV" -dump "${tb}.atb.bin" > "nexrv_natovf_dump.log" 2>&1
errors=$(grep -ac "TCODE\[6\]=8 " nexrv_natovf_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.pcout" -full > "nexrv_natovf.log" 2>&1
echo "NEXRV: $errors Error messages (from -dump); deco: $(grep -a 'Decoded OK' nexrv_natovf.log | tail -1)"

fail=0
if [ "$errors" -ge 1 ]; then echo "G1 PASS: natural overflow reached ($errors Error messages)";
else echo "G1 FAIL: no Error message - storm did not overflow (raise STORM_JUMPS?)"; fail=1; fi

if grep -aq "Decoded OK" nexrv_natovf.log; then echo "G2 PASS: Decoded OK";
else echo "G2 FAIL: decode aborted (known wedge defect until core fix)"; fail=1; fi

if [ "$errors" -le 40 ]; then echo "G3 PASS: errors bounded ($errors <= 40, no persistent drop-recover cycle)";
else echo "G3 FAIL: $errors error messages - persistent drop-recover wedge"; fail=1; fi

[ $fail -eq 0 ] && echo "### NATOVF ALL GATES PASS" || echo "### NATOVF GATES RED -- regression"
exit $fail
