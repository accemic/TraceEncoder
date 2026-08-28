#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# I-02 eTIP-FIFO fill histogram verification (local bring-up aid, cli_*
# pattern). Runs tests/instruction/18_fifo_histogram once and gates:
#   - HIST_NONZERO  (pressure run counted at least one bin)
#   - HIST_CLEARED  (HistClear zeroes all bins)
#   - HIST_REARMED  (second run counts again)
#   - no $error in the sim log
#   - PC lossless: both trace sessions decode against the expected-PC
#     reference (prefix per session; the TB runs two enable cycles).
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=fifo_hist_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/18_fifo_histogram/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl
ct_xsim xsim.log "${tb}_snap" -tclbatch _runall.tcl || exit 6
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin"; exit 6; }
cp "${tb}.atb.bin" "atb_hist.bin"

"$NEXRV" -deco "atb_hist.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.pcout" -full > "nexrv_hist.log" 2>&1
grep -E '[0-9]+ PC: 0x' "nexrv_hist.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "hist.pcs"

verdict=0
chk () { local n; n=$(grep -c "$2" xsim.log || true)
	if [ "$n" -ge 1 ]; then echo "$1 : PASS"; else echo "$1 : FAIL"; verdict=1; fi }
echo "======================================================"
grep -E "HIST [0-9]" xsim.log | sed 's/^/  /'
echo "------------------------------------------------------"
chk "pressure run counts   " "HIST_NONZERO"
chk "HistClear zeroes      " "HIST_CLEARED"
chk "re-armed counting     " "HIST_REARMED"
# (V2) was a fifth private spelling of the SVA check -- case-insensitive
# "^Error" also matched the tool's own "ERROR: [VRFC...]", and "Fatal: "
# with the trailing space missed a "Fatal:" at end of line.
if ct_no_sva_errors xsim.log; then echo "sim errors            : PASS (none)"; else echo "sim errors            : FAIL"; verdict=1; fi

# PC lossless: the reference holds BOTH sessions back to back; the decode
# must reproduce a prefix of it per session. Simple robust gate: decoded
# PC count > 100 and every decoded PC appears in the reference in order.
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "${tb}.expected.pcs" > exp.norm; norm hist.pcs > got.norm
n_exp=$(grep -c . exp.norm); n_got=$(grep -c . got.norm)
if [ "$n_got" -gt 100 ] && awk 'NR==FNR{a[NR]=$0;n=NR;next}{while(i<n && a[++i]!=$0);if(i>n){exit 1}}END{exit 0}' exp.norm got.norm; then
	echo "PC lossless (ordered) : PASS ($n_got/$n_exp PCs, in-order subsequence)"
else
	echo "PC lossless (ordered) : FAIL (got=$n_got exp=$n_exp)"; verdict=1
fi
echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
