#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# BP vendor TCODE 56 OFF-vs-ON verification (local bring-up aid).
# Self-contained: clones the 07 test's xsim .prj (abc's @-resolver is broken
# since the tree was vendored) with the TB source swapped, then runs the
# snapshot twice and NexRv-decodes both (the ON decode needs -bp so NexRv
# runs the mirrored predictor model). NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=branch_predict_tb
src_tb=repeated_history_tb   # donor project (same env, same libs)

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/10_branch_predict/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_one () { # $1 = tag, $2 = extra NexRv flags (may be empty), $3... = extra xsim args
	local tag="$1"; shift
	local decoflags="$1"; shift
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin" "atb_${tag}.bin"
	# shellcheck disable=SC2086
	"$NEXRV" -deco "atb_${tag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${tag}.pcout" -full $decoflags > "nexrv_${tag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
}

echo "### run OFF"; run_one off ""
echo "### run ON ";  run_one on "-bp" -testplusarg BP

exp="${tb}.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp"   > exp.norm
norm off.pcs  > off.norm
norm on.pcs   > on.norm
n_exp=$(grep -c . exp.norm); n_off=$(grep -c . off.norm); n_on=$(grep -c . on.norm)
sz_off=$(stat -c%s atb_off.bin); sz_on=$(stat -c%s atb_on.bin)
err_off=$(grep -c -i error nexrv_off.log); err_on=$(grep -c -i error nexrv_on.log)
bp_on=$(grep -c 'VendorBP' nexrv_on.log || true)

pfx=$(( n_off < n_on ? n_off : n_on ))
head -n "$pfx" exp.norm > exp.pfx
head -n "$pfx" off.norm > off.pfx
head -n "$pfx" on.norm  > on.pfx

echo "======================================================"
echo "expected PCs   : $n_exp"
echo "OFF decoded    : $n_off PCs, atb $sz_off B, errors $err_off"
echo "ON  decoded    : $n_on PCs, atb $sz_on B, errors $err_on"
echo "verified prefix: $pfx PCs (tail beyond this lost to host ATB truncation)"
echo "VendorBP       : $bp_on msgs in ON decode"
echo "------------------------------------------------------"
verdict=0
if cmp -s exp.pfx off.pfx; then echo "OFF prefix == reference : PASS"; else echo "OFF prefix == reference : FAIL"; verdict=1; diff exp.pfx off.pfx | head; fi
if cmp -s exp.pfx on.pfx;  then echo "ON  prefix == reference : PASS"; else echo "ON  prefix == reference : FAIL"; verdict=1; diff exp.pfx on.pfx | head; fi
if cmp -s off.pfx on.pfx;  then echo "OFF prefix == ON prefix : PASS (lossless fold)"; else echo "OFF prefix == ON prefix : FAIL"; verdict=1; fi
if [ "$err_off" -eq 0 ] && [ "$err_on" -eq 0 ]; then echo "decode errors           : PASS (none)"; else echo "decode errors           : note off=$err_off on=$err_on (tail truncation)"; fi
if [ "$sz_on" -lt "$sz_off" ]; then
	pct=$(( 100 - sz_on*100/sz_off ))
	echo "ON atb < OFF atb        : PASS (compression $sz_off -> $sz_on B, -$pct%)"
else
	echo "ON atb < OFF atb        : FAIL ($sz_off -> $sz_on)"; verdict=1
fi
echo "======================================================"
[ $verdict -eq 0 ] && [ "$pfx" -gt 50 ] && echo "OVERALL: PASS" || { echo "OVERALL: FAIL (prefix=$pfx)"; verdict=1; }
exit $verdict
