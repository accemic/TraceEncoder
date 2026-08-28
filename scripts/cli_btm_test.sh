#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# BTM (Branch Trace Messaging, InstMode=3) verification (seq 24; local
# bring-up aid, cli_* pattern). Runs tests/instruction/17_btm twice with
# identical stimulus:
#   htm : reset default InstMode=6 -> Branch-History (TCODE 28 IBH + HIST);
#         no TCODE 3/4.
#   btm : +BTMLEG (InstMode=3)     -> DirectBranch (TCODE 3, per taken
#         conditional branch) + IndirectBranch (TCODE 4, per indirect CF);
#         no IndirectBranchHist (28).
# Both legs PC-lossless against the same cpu_model reference -> both N-Trace
# 1.0 instruction-trace modes implemented and equivalent (Table 8 "3 OR 6").
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=btm_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/17_btm/${tb}.sv|" \
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

echo "### run HTM"; run_one htm
echo "### run BTM"; run_one btm -testplusarg BTMLEG

exp="${tb}.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp" > exp.norm
for t in htm btm; do norm "$t.pcs" > "$t.norm"; done
n_exp=$(grep -c . exp.norm); n_htm=$(grep -c . htm.norm); n_btm=$(grep -c . btm.norm)

cnt () { grep -cE "$1" "$2" || true; }
t3_htm=$(cnt 'TCODE\[6\]=3 '  nexrv_htm.log); t4_htm=$(cnt 'TCODE\[6\]=4 '  nexrv_htm.log)
t28_htm=$(cnt 'TCODE\[6\]=28 ' nexrv_htm.log)
t3_btm=$(cnt 'TCODE\[6\]=3 '  nexrv_btm.log); t4_btm=$(cnt 'TCODE\[6\]=4 '  nexrv_btm.log)
t28_btm=$(cnt 'TCODE\[6\]=28 ' nexrv_btm.log)
pb_htm=$(sed -nE 's/^Stat: ([0-9]+) bytes, ([0-9]+) messages.*/\1 \2/p' nexrv_htm.log)
pb_btm=$(sed -nE 's/^Stat: ([0-9]+) bytes, ([0-9]+) messages.*/\1 \2/p' nexrv_btm.log)

pfx=$(( n_htm < n_btm ? n_htm : n_btm )); [ "$n_exp" -lt "$pfx" ] && pfx=$n_exp
head -n "$pfx" exp.norm > exp.pfx
for t in htm btm; do head -n "$pfx" "$t.norm" > "$t.pfx"; done

echo "======================================================"
echo "expected PCs   : $n_exp"
echo "HTM: $n_htm PCs, T3=$t3_htm T4=$t4_htm T28=$t28_htm, payload [$pb_htm]"
echo "BTM: $n_btm PCs, T3=$t3_btm T4=$t4_btm T28=$t28_btm, payload [$pb_btm]"
echo "verified prefix: $pfx PCs"
echo "------------------------------------------------------"
verdict=0
for t in htm btm; do
	if cmp -s exp.pfx "$t.pfx"; then echo "$t prefix == reference   : PASS"; else echo "$t prefix == reference   : FAIL"; verdict=1; diff exp.pfx "$t.pfx" | head; fi
done
if [ "$t3_htm" -eq 0 ] && [ "$t4_htm" -eq 0 ] && [ "$t28_htm" -ge 1 ]; then echo "HTM: IBH(28), no 3/4     : PASS ($t28_htm)"; else echo "HTM: IBH(28), no 3/4     : FAIL (t3=$t3_htm t4=$t4_htm t28=$t28_htm)"; verdict=1; fi
if [ "$t3_btm" -ge 3 ]; then echo "BTM: DirectBranch(3) >=3 : PASS ($t3_btm)"; else echo "BTM: DirectBranch(3) >=3 : FAIL ($t3_btm)"; verdict=1; fi
if [ "$t4_btm" -ge 2 ]; then echo "BTM: IndirectBranch(4)>=2: PASS ($t4_btm)"; else echo "BTM: IndirectBranch(4)>=2: FAIL ($t4_btm)"; verdict=1; fi
if [ "$t28_btm" -eq 0 ]; then echo "BTM: no IBH(28)          : PASS"; else echo "BTM: no IBH(28)          : FAIL ($t28_btm)"; verdict=1; fi
echo "======================================================"
[ $verdict -eq 0 ] && [ "$pfx" -gt 40 ] && echo "OVERALL: PASS" || { echo "OVERALL: FAIL (prefix=$pfx)"; verdict=1; }
exit $verdict
