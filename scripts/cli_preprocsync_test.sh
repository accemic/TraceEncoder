#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Unit gate for ct_L23_preproc_sync -- the sync generator.
#
# WHY THIS SCRIPT EXISTS. rtl/preproc/test/ct_L23_preproc_sync_tb.sv carries
# 29 assertions over the whole sync surface (reset-exit sync, tip-clock and
# wall-clock periodic modes, the trace-byte quota, and both explicitly
# requested syncs -- the ATB input and the TE register field, including their
# collision, their negative case and the pause behaviour). P8 changed exactly
# that module, and the testbench ran on NO runner at all: its .abc header
# said "run it through scripts/run_gates.sh", and scripts/run_gates.sh runs
# cli_*_test.sh gates, of which none touched it. A testbench that nothing
# starts is a silent failure -- it cannot go red (P8 re-check RC-2).
#
# The backend note in the .abc header stays true and is the reason this is a
# cli gate rather than a `make sim` entry: under the repository's default
# `verilator` backend the testbench does not pass -- it uses virtual-interface
# constructs the free front end does not implement. That is a statement about
# the front end, not about the DUT. So the project is generated for XSIM
# (ct_need_prj asks for --sim-backend vivado) and xvlog/xelab/xsim are driven
# directly, exactly like every other cli gate.
#
# Verdict: the testbench's own summary, PLUS a floor on the number of checked
# assertions -- a testbench that stops checking must not be able to pass by
# checking less.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado

tb=ct_L23_preproc_sync_tb
abcfile="rtl/preproc/test/${tb}.abc"
# The floor is the count at the time of writing (P8 left 28, D1 added the five
# half-word-cadence checks of Test 6). Raise it with the commit that adds
# assertions; never lower it silently.
MIN_ASSERTIONS=33

ct_need_prj "$tb" "$abcfile" || exit $?
xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"

cd "$xd"
rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
xvlog --relax -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
	|| { echo "FAIL xvlog"; grep -i error xvlog.log | head; exit 4; }
xelab --relax --debug off "xil_defaultlib.${tb}" xil_defaultlib.glbl \
	-s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
	|| { echo "FAIL xelab"; grep -i error xelab.log | head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

echo "########## ct_L23_preproc_sync unit testbench (xsim)"
ct_xsim xsim_sync.log "${tb}_snap" -tclbatch _runall.tcl \
	|| { echo "FAIL: xsim leg unusable (reason above)"; exit 6; }
grep -aE 'Testcase:|Info: Testbench|^ *Error:' xsim_sync.log | head -12

verdict=0
if grep -aq 'Info: Testbench passed.' xsim_sync.log; then
	echo "  [PASS] testbench verdict"
else
	echo "  [FAIL] testbench verdict"
	grep -aE '^ *Error:' xsim_sync.log | head -5
	verdict=1
fi

# "Checked <n> assertions" comes from tt's summary line.
n=$(sed -nE 's/.*Checked ([0-9]+) assertions.*/\1/p' xsim_sync.log | tail -1)
n=${n:-0}
if [ "$n" -ge "$MIN_ASSERTIONS" ]; then
	echo "  [PASS] $n assertion(s) checked (floor $MIN_ASSERTIONS)"
else
	echo "  [FAIL] only $n assertion(s) checked, floor is $MIN_ASSERTIONS --"
	echo "         a testbench may not pass by checking less"
	verdict=1
fi

echo "======================================================"
if [ "$verdict" -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $verdict
