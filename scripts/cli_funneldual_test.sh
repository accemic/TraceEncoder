#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Unit gate for the two capabilities AP1 ported into ct_L1_funnel: the
# MDO_WIDTH parameterisation (byte/half-word chunk configurations, not only
# the historical one-chunk-per-beat fixed width) and the dual-protocol
# EN_TE_RAW path (E-Trace reference-raw te_inst channels merged into one
# self-describing CTMX byte container with source tags).
#
# WHY THIS SCRIPT EXISTS. The two testbenches came from the board integration
# tree, where they were run by hand. Dropping them into rtl/test/ without a
# runner would have made them orphans -- and scripts/check_orphan_gates.py
# would have gone red for exactly the right reason: "a testbench that nothing
# starts is a silent failure, it cannot go red". This gate starts them.
#
# Backend note, same as cli_preprocsync_test.sh: the project is generated for
# XSIM (ct_need_prj asks for --sim-backend vivado) and xvlog/xelab/xsim are
# driven directly, because these testbenches use constructs the free front end
# does not implement. That is a statement about the front end, not the DUT.
#
# Verdict per testbench: the testbench's own summary, PLUS a floor on the
# number of checked assertions -- a testbench that stops checking must not be
# able to pass by checking less. Floors are the counts measured when this gate
# was written; raise them with the commit that adds assertions, never lower
# them silently.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado

verdict=0

run_tb() {
	local tb="$1" floor="$2" abcfile="rtl/test/${1}.abc"

	ct_need_prj "$tb" "$abcfile" || return $?
	local xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
	cd "$xd"
	rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
	xvlog --relax -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
		|| { echo "FAIL xvlog"; grep -i error xvlog.log | head; cd "$here"; return 4; }
	xelab --relax --debug off "xil_defaultlib.${tb}" xil_defaultlib.glbl \
		-s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
		|| { echo "FAIL xelab"; grep -i error xelab.log | head; cd "$here"; return 5; }
	printf 'run -all\nquit\n' > _runall.tcl

	echo "########## ${tb} (xsim)"
	ct_xsim "xsim_${tb}.log" "${tb}_snap" -tclbatch _runall.tcl \
		|| { echo "FAIL: xsim leg unusable (reason above)"; cd "$here"; return 6; }
	grep -aE 'Testcase:|Info: Testbench|^ *Error:' "xsim_${tb}.log" | head -12

	local rc=0
	if grep -aq 'Info: Testbench passed.' "xsim_${tb}.log"; then
		echo "  [PASS] ${tb} verdict"
	else
		echo "  [FAIL] ${tb} verdict"
		grep -aE '^ *Error:' "xsim_${tb}.log" | head -5
		rc=1
	fi

	# The MAXIMUM, not the last line: tt prints a "Checked N assertions"
	# summary per testcase, and the last testcase is usually a small one. Using
	# tail -1 would put the floor at 1 and make it meaningless -- the floor has
	# to bite on the global set, which is where the assertions actually are.
	local n
	n=$(sed -nE 's/.*Checked ([0-9]+) assertions.*/\1/p' "xsim_${tb}.log" \
		| sort -n | tail -1)
	n=${n:-0}
	if [ "$n" -ge "$floor" ]; then
		echo "  [PASS] $n assertion(s) checked (floor $floor)"
	else
		echo "  [FAIL] only $n assertion(s) checked, floor is $floor --"
		echo "         a testbench may not pass by checking less"
		rc=1
	fi
	cd "$here"
	return $rc
}

# NEUTRALITY LEG, and the reason it runs first. ct_L1_funnel_tb is the
# fixed-width reference testbench that predates the port: MDO_WIDTH = 30,
# EN_TE_RAW = 0, i.e. exactly the historical configuration. If the
# parameterisation changed behaviour at its defaults, this is where it shows.
# The file header of the ported funnel CLAIMS that EN_TE_RAW = 0 folds every
# te_raw tie away and leaves the historical netlist -- a claim is not evidence,
# so it gets a runner.
#
# Wiring it here also retires one of the known orphans in
# scripts/check_orphan_gates.py (it ran only in coverage_suite.sh, which judges
# nothing, V1-F6). That guard goes red on good news too, by design, so its list
# is updated in the same commit.
run_tb ct_L1_funnel_tb       "${MIN_FIXED:-386}" || verdict=1
# MDO_WIDTH parameterisation: 6/14/30-bit chunk configurations.
run_tb ct_L1_funnel_mdo6_tb  "${MIN_MDO6:-117}"  || verdict=1
# Dual protocol: te_raw framing, CTMX source tags, mixed MSEO/te_raw.
run_tb ct_L1_funnel_teraw_tb "${MIN_TERAW:-148}" || verdict=1

echo "======================================================"
if [ "$verdict" -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $verdict
