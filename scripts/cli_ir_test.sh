#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Phase-1 implicit-return OFF-vs-ON verification (local Windows bring-up aid).
# abc generates the xsim .prj (its project-mode launch_simulation can't spawn
# under the Bash tool, so we drive xvlog/xelab/xsim on the command line), then
# runs the same snapshot twice and NexRv-decodes both. NOT for commit.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_abc
ct_need_nexrv

tb=implicit_return_tb
# The project is generated on demand (ct_need_prj, scripts/ct_env.sh):
# bld/ is gitignored, so a fresh clone or worktree has none, and the
# gates that clone THIS project used to fail with "donor prj missing"
# on a tree where nothing was broken. CT_PRJ_REFRESH=1 forces a
# regeneration after a change to the file list.
ct_need_prj "$tb" || exit $?
xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"

cd "$xd"
rm -rf xsim.dir          # clean compile so TB edits always take effect
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_one () { # $1 = tag, $2... = extra xsim args
	local tag="$1"; shift
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin" "atb_${tag}.bin"
	"$NEXRV" -deco "atb_${tag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${tag}.pcout" -full > "nexrv_${tag}.log" 2>&1
	# NexRv -pcout writes "<n> PC: 0x..." lines; extract the addresses
	grep -E '[0-9]+ PC: 0x' "nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
}

echo "### run OFF"; run_one off
echo "### run ON ";  run_one on -testplusarg IMPLICIT_RETURN

exp="${tb}.expected.pcs"
# normalise to bare lower-hex for compare
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr 'A-F' 'a-f'; }
norm "$exp"   > exp.norm
norm off.pcs  > off.norm
norm on.pcs   > on.norm
n_exp=$(grep -c . exp.norm); n_off=$(grep -c . off.norm); n_on=$(grep -c . on.norm)
sz_off=$(stat -c%s atb_off.bin); sz_on=$(stat -c%s atb_on.bin)
err_off=$(grep -c -i error nexrv_off.log); err_on=$(grep -c -i error nexrv_on.log)

# Common verified prefix = min decoded length (this bring-up host drops the
# last held ATB message; a divergence BEFORE that prefix end is a real fault).
pfx=$(( n_off < n_on ? n_off : n_on ))
head -n "$pfx" exp.norm > exp.pfx
head -n "$pfx" off.norm > off.pfx
head -n "$pfx" on.norm  > on.pfx

echo "======================================================"
echo "expected PCs   : $n_exp"
echo "OFF decoded    : $n_off PCs, atb $sz_off B, errors $err_off"
echo "ON  decoded    : $n_on PCs, atb $sz_on B, errors $err_on"
echo "verified prefix: $pfx PCs (tail beyond this lost to host ATB truncation)"
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
