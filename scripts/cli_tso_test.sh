#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# B4/B5/B6 trigger-sync / seq-sync / ownership verification (seq 24; local
# bring-up aid, cli_* pattern). Runs tests/instruction/15_trig_seq_own four
# times with identical stimulus:
#   off : reset defaults  -> no SYNC 4/6, no TCODE 2; ICNT cap drains via
#                            ResourceFull (RCODE=0)
#   trig: +TRIGLEG        -> tip.trigger pulse upgrades next retire to SYNC=6
#   seq : +SEQLEG         -> ICNT-cap pre-drain becomes SYNC=4 re-anchor
#                            (no RCODE=0 left in the stream)
#   own : +OWNLEG         -> Ownership TCODE 2 after every sync (FORMAT=0)
#                            + one FORMAT=2 for the ctype=2 context report
# All legs PC-lossless against the same cpu_model reference.
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=trig_seq_own_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/15_trig_seq_own/${tb}.sv|" \
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

echo "### run OFF ";  run_one off
echo "### run TRIG";  run_one trig -testplusarg TRIGLEG
echo "### run SEQ ";  run_one seq  -testplusarg SEQLEG
echo "### run OWN ";  run_one own  -testplusarg OWNLEG

exp="${tb}.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp" > exp.norm
for t in off trig seq own; do norm "$t.pcs" > "$t.norm"; done
n_exp=$(grep -c . exp.norm)
n_off=$(grep -c . off.norm); n_trig=$(grep -c . trig.norm)
n_seq=$(grep -c . seq.norm); n_own=$(grep -c . own.norm)

cnt () { grep -cE "$1" "$2" || true; }
s6_off=$(cnt 'SYNC\[4\]=0x6\b' nexrv_off.log);  s4_off=$(cnt 'SYNC\[4\]=0x4\b' nexrv_off.log)
t2_off=$(cnt 'TCODE\[6\]=2 '   nexrv_off.log);  r0_off=$(cnt 'RCODE\[4\]=0x0\b' nexrv_off.log)
s6_trig=$(cnt 'SYNC\[4\]=0x6\b' nexrv_trig.log)
s4_seq=$(cnt 'SYNC\[4\]=0x4\b'  nexrv_seq.log); r0_seq=$(cnt 'RCODE\[4\]=0x0\b' nexrv_seq.log)
t2_own=$(cnt 'TCODE\[6\]=2 '    nexrv_own.log)
# Exact PROCESS values. nexus_process_t = {_context[43:0], v, prv[1:0],
# format[1:0]}, so PROCESS = (ctx << 5) | (v << 4) | (prv << 2) | format.
#   FORMAT=0 after a sync -> {ctx=0,v=0,prv=3,fmt=0}          = 0xc
#   ctype=2 report with ctx='1 -> {ctx='1,v=0,prv=3,fmt=2}
# The second value depends on ct_pkg::CT_CONTEXT_WIDTH (W2) and is COMPUTED
# from the package, not hard-coded: a build knob whose expected value has to
# be edited by hand is a knob that will be measured against a stale number
# (at the default width 2 this is 0x6e, exactly as before).
ctxw=$(sed -nE 's/^[[:space:]]*localparam int unsigned CT_CONTEXT_WIDTH[[:space:]]*=[[:space:]]*([0-9]+);.*/\1/p' \
	"$here/rtl/pkg/ct_pkg.sv" | head -1)
[ -n "$ctxw" ] || { echo "FAIL: CT_CONTEXT_WIDTH not readable from rtl/pkg/ct_pkg.sv"; exit 3; }
f2_hex=$(printf '%x' $(( (((1 << ctxw) - 1) << 5) | (3 << 2) | 2 )))
p_f0=$(cnt 'PROCESS\[[0-9]+\]=0xc \(' nexrv_own.log)
p_f2=$(cnt "PROCESS\\[[0-9]+\\]=0x${f2_hex} \\(" nexrv_own.log)

pfx=$n_off
for n in $n_trig $n_seq $n_own; do [ "$n" -lt "$pfx" ] && pfx=$n; done
head -n "$pfx" exp.norm > exp.pfx
for t in off trig seq own; do head -n "$pfx" "$t.norm" > "$t.pfx"; done

echo "======================================================"
echo "expected PCs   : $n_exp"
echo "OFF : $n_off PCs, SYNC6=$s6_off SYNC4=$s4_off TCODE2=$t2_off RCODE0=$r0_off"
echo "TRIG: $n_trig PCs, SYNC6=$s6_trig"
echo "SEQ : $n_seq PCs, SYNC4=$s4_seq RCODE0=$r0_seq"
echo "OWN : $n_own PCs, TCODE2=$t2_own"
echo "verified prefix: $pfx PCs"
echo "------------------------------------------------------"
verdict=0
for t in off trig seq own; do
	if cmp -s exp.pfx "$t.pfx"; then echo "$t prefix == reference   : PASS"; else echo "$t prefix == reference   : FAIL"; verdict=1; diff exp.pfx "$t.pfx" | head; fi
done
if [ "$s6_off" -eq 0 ] && [ "$s4_off" -eq 0 ] && [ "$t2_off" -eq 0 ]; then echo "OFF clean (no 4/6/T2)    : PASS"; else echo "OFF clean (no 4/6/T2)    : FAIL (s6=$s6_off s4=$s4_off t2=$t2_off)"; verdict=1; fi
if [ "$r0_off" -ge 1 ]; then echo "OFF drains via RCODE=0   : PASS ($r0_off)"; else echo "OFF drains via RCODE=0   : FAIL"; verdict=1; fi
if [ "$s6_trig" -ge 1 ]; then echo "TRIG SYNC=6 >= 1         : PASS ($s6_trig)"; else echo "TRIG SYNC=6 >= 1         : FAIL"; verdict=1; fi
if [ "$s4_seq" -ge 1 ] && [ "$r0_seq" -eq 0 ]; then echo "SEQ SYNC=4, no RCODE=0   : PASS (s4=$s4_seq)"; else echo "SEQ SYNC=4, no RCODE=0   : FAIL (s4=$s4_seq r0=$r0_seq)"; verdict=1; fi
if [ "$t2_own" -ge 2 ]; then echo "OWN TCODE 2 >= 2         : PASS ($t2_own)"; else echo "OWN TCODE 2 >= 2         : FAIL ($t2_own)"; verdict=1; fi
if [ "$p_f0" -ge 1 ] && [ "$p_f2" -ge 1 ]; then echo "OWN PROCESS 0xc + 0x$f2_hex : PASS (f0=$p_f0 f2=$p_f2, ctxw=$ctxw)"; else echo "OWN PROCESS 0xc + 0x$f2_hex : FAIL (f0=$p_f0 f2=$p_f2, ctxw=$ctxw)"; verdict=1; fi
echo "======================================================"
[ $verdict -eq 0 ] && [ "$pfx" -gt 50 ] && echo "OVERALL: PASS" || { echo "OVERALL: FAIL (prefix=$pfx)"; verdict=1; }
exit $verdict
