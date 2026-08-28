#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Reproducer: branch prediction x half-word periodic sync
# (tests/overflow/05_bp_hwsync). Found on hardware: the VendorBP walk ends
# after n of n+1 branches, WITHOUT any overflow.
# Gates:
#   H0  >=1 ProgTraceSync (TCODE 9) after the start sync -> periodic axis active
#   H1  >=1 VendorBP (TCODE 56)                          -> BP path active
#   H2  NexRv "Decoded OK" (-bp)                         -> the regression guard
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=bp_hwsync_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/05_bp_hwsync/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
fail=0

rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (xelab -R)"; grep -i "error" xelab.log xsim.log 2>/dev/null | head; exit 6; }
ct_no_sva_errors xelab.log xsim.log || { echo "FAIL: \$error/\$fatal in sim log"; exit 7; }

"$NEXRV" -dump "${tb}.atb.bin" > "nexrv_bphws_dump.log" 2>&1
syncs=$(grep -ac "TCODE\[6\]=9 " nexrv_bphws_dump.log || true)
bps=$(grep -ac "TCODE\[6\]=56 " nexrv_bphws_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.pcout" -bp -full > "nexrv_bphws.log" 2>&1
echo "NEXRV: $syncs ProgTraceSync, $bps VendorBP; deco: $(grep -a 'Decoded OK' nexrv_bphws.log | tail -1)"

if [ "$syncs" -ge 2 ]; then echo "H0 PASS: periodic syncs active ($syncs)";
else echo "H0 FAIL: no periodic sync -- axis not active"; fail=1; fi

if [ "$bps" -ge 1 ]; then echo "H1 PASS: BP path active ($bps VendorBP messages)";
else echo "H1 FAIL: no VendorBP message"; fail=1; fi

if grep -aq "Decoded OK" nexrv_bphws.log; then echo "H2 PASS: Decoded OK ($(grep -ac 'PC: 0x' nexrv_bphws.log) PCs)";
else
  echo "H2 FAIL (= B4 REPRODUZIERT): $(tail -3 nexrv_bphws.log | tr '\n' ' ')"
  fail=1
fi

exit $fail
