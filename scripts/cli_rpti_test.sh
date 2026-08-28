#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# B3 RepeatInstruction verification (seq 24; local bring-up aid, cli_* pattern).
# Runs tests/instruction/14_repeat_instr three times:
#   off : reset defaults        -> no TCODE 31/32, HIST-overflow forms
#   on  : +RPTI                 -> TCODE 31 (run close) AND TCODE 32 (sync
#                                  lands on the loop branch mid-run)
#   rh  : +RPTI_RH (contrast)   -> the third repeat form: RCODE=2 windows,
#                                  no TCODE 31/32
# All legs PC-lossless against the same cpu_model reference; ON payload
# strictly smaller than OFF (NexRv stat line; atb.bin is beat-quantized).
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=repeat_instr_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/14_repeat_instr/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_one () { # $1 = tag, $2... = extra xsim args
	local tag="$1"; shift
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin" "atb_${tag}.bin"
	"$NEXRV" -deco "atb_${tag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${tag}.pcout" -full > "nexrv_${tag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
}

echo "### run OFF"; run_one off
echo "### run ON ";  run_one on -testplusarg RPTI
echo "### run RH ";  run_one rh -testplusarg RHLEG

exp="${tb}.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp"   > exp.norm
for t in off on rh; do norm "$t.pcs" > "$t.norm"; done
n_exp=$(grep -c . exp.norm); n_off=$(grep -c . off.norm); n_on=$(grep -c . on.norm); n_rh=$(grep -c . rh.norm)

cnt () { grep -cE "$1" "$2" || true; }
t31_off=$(cnt 'TCODE\[6\]=31 ' nexrv_off.log); t32_off=$(cnt 'TCODE\[6\]=32 ' nexrv_off.log)
t31_on=$(cnt 'TCODE\[6\]=31 ' nexrv_on.log);   t32_on=$(cnt 'TCODE\[6\]=32 ' nexrv_on.log)
t31_rh=$(cnt 'TCODE\[6\]=31 ' nexrv_rh.log);   t32_rh=$(cnt 'TCODE\[6\]=32 ' nexrv_rh.log)
r2_rh=$(cnt 'RCODE\[4\]=0x2\b' nexrv_rh.log)
pb_off=$(sed -nE 's/^Stat: ([0-9]+) bytes, ([0-9]+) messages.*/\1 \2/p' nexrv_off.log)
pb_on=$(sed -nE 's/^Stat: ([0-9]+) bytes, ([0-9]+) messages.*/\1 \2/p' nexrv_on.log)
bytes_off=${pb_off% *}; msgs_off=${pb_off#* }
bytes_on=${pb_on% *};  msgs_on=${pb_on#* }

pfx3=$(( n_off < n_on ? n_off : n_on )); pfx=$(( pfx3 < n_rh ? pfx3 : n_rh ))
head -n "$pfx" exp.norm > exp.pfx
for t in off on rh; do head -n "$pfx" "$t.norm" > "$t.pfx"; done

echo "======================================================"
echo "expected PCs   : $n_exp"
echo "OFF: $n_off PCs, T31=$t31_off T32=$t32_off"
echo "ON : $n_on PCs, T31=$t31_on T32=$t32_on, payload $bytes_on B/$msgs_on msgs (OFF $bytes_off B/$msgs_off msgs)"
echo "RH : $n_rh PCs, T31=$t31_rh T32=$t32_rh RCODE2=$r2_rh"
echo "verified prefix: $pfx PCs"
echo "------------------------------------------------------"
verdict=0
for t in off on rh; do
	if cmp -s exp.pfx "$t.pfx"; then echo "$t prefix == reference  : PASS"; else echo "$t prefix == reference  : FAIL"; verdict=1; diff exp.pfx "$t.pfx" | head; fi
done
if [ "$t31_off" -eq 0 ] && [ "$t32_off" -eq 0 ]; then echo "OFF has no TCODE 31/32  : PASS"; else echo "OFF has no TCODE 31/32  : FAIL"; verdict=1; fi
if [ "$t31_on" -ge 1 ]; then echo "ON  TCODE 31 >= 1       : PASS ($t31_on)"; else echo "ON  TCODE 31 >= 1       : FAIL"; verdict=1; fi
if [ "$t32_on" -ge 1 ]; then echo "ON  TCODE 32 >= 1       : PASS ($t32_on)"; else echo "ON  TCODE 32 >= 1       : FAIL"; verdict=1; fi
if [ "$t31_rh" -eq 0 ] && [ "$t32_rh" -eq 0 ] && [ "$r2_rh" -ge 1 ]; then echo "RH contrast (RCODE2)    : PASS ($r2_rh)"; else echo "RH contrast (RCODE2)    : FAIL (t31=$t31_rh t32=$t32_rh r2=$r2_rh)"; verdict=1; fi
if [ "$bytes_on" -lt "$bytes_off" ] && [ "$msgs_on" -lt "$msgs_off" ]; then
	pct=$(( 100 - bytes_on*100/bytes_off ))
	echo "ON payload < OFF        : PASS ($bytes_off -> $bytes_on B, -$pct%; $msgs_off -> $msgs_on msgs)"
else
	echo "ON payload < OFF        : FAIL (bytes $bytes_off -> $bytes_on, msgs $msgs_off -> $msgs_on)"; verdict=1
fi
echo "======================================================"
[ $verdict -eq 0 ] && [ "$pfx" -gt 50 ] && echo "OVERALL: PASS" || { echo "OVERALL: FAIL (prefix=$pfx)"; verdict=1; }
exit $verdict
