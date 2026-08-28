#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# C1/C2/C3/C4 config-message verification (seq 24; local bring-up aid,
# cli_* pattern). Runs tests/instruction/16_config_msg five times:
#   none  : SendConfig=0             -> zero TCODE 58
#   once  : reset default CFG_ONCE   -> exactly one TCODE 58, as MSG #0
#   onsync: SendConfig=2             -> count(58) == count(SYNC-field msgs)
#   bp    : +BP, CFG_ONCE            -> C4: NexRv WITHOUT -bp == WITH -bp
#                                       (autoconfig from ENAB.5, INFO print)
#   bpneg : +BP, SendConfig=0        -> negative control: flagless decode
#                                       must NOT reproduce the reference
# All legs (except bpneg flagless) PC-lossless against the same reference.
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=config_msg_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/16_config_msg/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_sim () { # $1 = tag, $2... = extra xsim args
	local tag="$1"; shift
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin" "atb_${tag}.bin"
}
deco () { # $1 = atb tag, $2 = out tag, $3... = extra NexRv args
	local atag="$1" otag="$2"; shift 2
	"$NEXRV" -deco "atb_${atag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${otag}.pcout" "$@" -full > "nexrv_${otag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${otag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${otag}.pcs"
}

echo "### run NONE  ";  run_sim none  -testplusarg NONELEG;   deco none  none
echo "### run ONCE  ";  run_sim once;                          deco once  once
echo "### run ONSYNC";  run_sim onsync -testplusarg ONSYNCLEG; deco onsync onsync
echo "### run BP    ";  run_sim bp    -testplusarg BPLEG
deco bp bp_auto            # C4: flagless -- autoconfig must kick in
deco bp bp_flag -bp        # explicit flag reference
echo "### run BPNEG ";  run_sim bpneg -testplusarg BPNEGLEG
deco bpneg bpneg_flagless  # negative control: must NOT match reference
deco bpneg bpneg_flag -bp  # sanity: with the flag it decodes fine

exp="${tb}.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp" > exp.norm
for t in none once onsync bp_auto bp_flag bpneg_flagless bpneg_flag; do norm "$t.pcs" > "$t.norm"; done
n_exp=$(grep -c . exp.norm)

cnt () { grep -cE "$1" "$2" || true; }
t58_none=$(cnt 'TCODE\[6\]=58 ' nexrv_none.log)
t58_once=$(cnt 'TCODE\[6\]=58 ' nexrv_once.log)
t58_sync=$(cnt 'TCODE\[6\]=58 ' nexrv_onsync.log)
sync_sync=$(cnt 'SYNC\[4\]=' nexrv_onsync.log)
first58_once=$(grep -cE 'TCODE\[6\]=58 \(MSG #0\)' nexrv_once.log || true)
auto_info=$(cnt 'BP walk enabled .*auto' nexrv_bp_auto.log)

verdict=0
chk_pfx () { # $1 = tag; PC-lossless vs reference (full-length prefix match)
	local n; n=$(grep -c . "$1.norm")
	local m=$(( n < n_exp ? n : n_exp ))
	if [ "$m" -gt 50 ] && head -n "$m" exp.norm | cmp -s - <(head -n "$m" "$1.norm"); then
		echo "$1 lossless ($m PCs)      : PASS"
	else
		echo "$1 lossless               : FAIL (n=$n exp=$n_exp)"; verdict=1
	fi
}

echo "======================================================"
echo "expected PCs: $n_exp"
echo "T58: none=$t58_none once=$t58_once onsync=$t58_sync (SYNC fields onsync=$sync_sync)"
echo "------------------------------------------------------"
for t in none once onsync bp_auto bp_flag bpneg_flag; do chk_pfx "$t"; done
if [ "$t58_none" -eq 0 ]; then echo "NONE has no TCODE 58     : PASS"; else echo "NONE has no TCODE 58     : FAIL ($t58_none)"; verdict=1; fi
if [ "$t58_once" -eq 1 ] && [ "$first58_once" -eq 1 ]; then echo "ONCE exactly 1x, MSG #0  : PASS"; else echo "ONCE exactly 1x, MSG #0  : FAIL (n=$t58_once first=$first58_once)"; verdict=1; fi
if [ "$t58_sync" -ge 3 ] && [ "$t58_sync" -eq "$sync_sync" ]; then echo "ONSYNC 58 == sync count  : PASS ($t58_sync)"; else echo "ONSYNC 58 == sync count  : FAIL (58=$t58_sync sync=$sync_sync)"; verdict=1; fi
if [ "$auto_info" -ge 1 ]; then echo "BP autoconfig INFO print : PASS"; else echo "BP autoconfig INFO print : FAIL"; verdict=1; fi
if cmp -s bp_auto.norm bp_flag.norm && [ "$(grep -c . bp_auto.norm)" -gt 50 ]; then
	echo "C4 flagless == flagged   : PASS ($(grep -c . bp_auto.norm) PCs byte-equal)"
else
	echo "C4 flagless == flagged   : FAIL"; verdict=1
fi
if cmp -s bpneg_flagless.norm bpneg_flag.norm; then
	echo "BPNEG flagless != ref    : FAIL (unexpectedly matched)"; verdict=1
else
	echo "BPNEG flagless != ref    : PASS (negative control diverges)"
fi
echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
