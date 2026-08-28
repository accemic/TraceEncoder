#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Unit gate for the ingress adapters under rtl/adapters/ (AP4.1): the AMD
# MicroBlaze V TRACE-bus adapter, the CVA6 ITI adapter and the Rocket TCI
# adapter, each with its unit testbenches.
#
# WHY THIS SCRIPT EXISTS. The adapters migrated in from the board integration
# tree with seven testbenches, and a testbench that nothing starts is a silent
# failure -- it cannot go red (scripts/check_orphan_gates.py enforces exactly
# that). This gate starts all of them.
#
# VERDICT RULE, stricter than usual because the testbenches are heterogeneous:
# the migrated benches signal success as either "### TB_PASS" or "[tb_*] PASS"
# and failure as "### TB_FAIL", "FAIL", or $fatal -- and xsim exits 0 even on
# $fatal, only the log says so. So a leg passes only if its log contains the
# expected PASS marker AND contains no failure marker. A log with neither
# (e.g. a bench that hung and was killed) is a FAIL, not a skip: silence must
# never read as green.
#
# Backend note, same as cli_preprocsync_test.sh / cli_funneldual_test.sh: the
# project is generated for XSIM and xvlog/xelab/xsim are driven directly.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado

verdict=0

# adapter-dir  testbench  (one line per leg; extend when an adapter gains one)
LEGS="
amd_microblaze_v tb_mbv_itype_decoder off
amd_microblaze_v tb_mbv_to_ctte_tip   off
amd_microblaze_v tb_mbv_trap_mapper     off
cva6             tb_iti2tip_unit        off
cva6             tb_itype_refine_unit   typical
rocket           tb_rocket_tci_unit     off
"

run_tb() {
	# $3 = xelab debug mode. Every leg runs "off" except tb_itype_refine_unit:
	# xelab --debug off mis-schedules the output-port connection of the
	# refine instance inside cva6_iti_to_ctte_tip -- probed 2026-08-17:
	# the instance-internal value is correct while the sink reads X (uwire
	# sink, in-generate) or lags one clock (variable sink, any scope). Same
	# tool-defect family as XSIM finding L2. --debug typical terminates the
	# port correctly; the instance-internal probe proves the RTL right, so
	# the workaround is pinned on the tool, not the DUT.
	local dir="$1" tb="$2" dbg="${3:-off}" abcfile="rtl/adapters/$1/test/${2}.abc"

	ct_need_prj "$tb" "$abcfile" || return $?
	local xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
	cd "$xd"
	rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
	xvlog --relax -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
		|| { echo "FAIL xvlog"; grep -i error xvlog.log | head; cd "$here"; return 4; }
	xelab --relax --debug "$dbg" "xil_defaultlib.${tb}" xil_defaultlib.glbl \
		-s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
		|| { echo "FAIL xelab"; grep -i error xelab.log | head; cd "$here"; return 5; }
	# Stage the stimulus files next to the snapshot: xsim's CWD is this
	# build directory, and the benches open their .vec by bare name. Without
	# this a fresh checkout fails mysteriously (the migration runs only
	# passed because the vectors had been copied by hand).
	for vec in "$here"/rtl/adapters/"$dir"/test/*.vec; do
		[ -f "$vec" ] && cp -f "$vec" .
	done
	printf 'run -all\nquit\n' > _runall.tcl

	echo "########## ${tb} (xsim)"
	ct_xsim "xsim_${tb}.log" "${tb}_snap" -tclbatch _runall.tcl \
		|| { echo "FAIL: xsim leg unusable (reason above)"; cd "$here"; return 6; }

	local rc=0
	# Failure markers first: a log that carries both never passes.
	if grep -aqE '### TB_FAIL|FAIL |Fatal:' "xsim_${tb}.log"; then
		echo "  [FAIL] ${tb}: failure marker in log"
		grep -aE '### TB_FAIL|FAIL |Fatal:' "xsim_${tb}.log" | head -5
		rc=1
	elif grep -aqE '### TB_PASS|\] PASS' "xsim_${tb}.log"; then
		grep -aE '### TB_PASS|\] PASS' "xsim_${tb}.log" | head -2
		echo "  [PASS] ${tb}"
	else
		echo "  [FAIL] ${tb}: neither a PASS nor a FAIL marker -- silence is not green"
		tail -5 "xsim_${tb}.log"
		rc=1
	fi
	cd "$here"
	return $rc
}

while read -r dir tb dbg; do
	[ -z "$dir" ] && continue
	run_tb "$dir" "$tb" "$dbg" || verdict=1
done <<< "$LEGS"

echo "======================================================"
if [ "$verdict" -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $verdict
