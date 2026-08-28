#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# C0a AXIS-timestamp verification (CT_EN_AXIS_TS).
# Runs tests/hsi/01_csr_cap twice with the SAME stimulus:
#   on : the committed tree (CT_EN_AXIS_TS = 1). The TB asserts in sim that
#        every DAQ_PC_CURR beat carries a VALID element 2 and that the values
#        are strictly monotonic over three beats (TR_TS_SYSTEM counter with
#        trTsControl.Enable = 0, so the ATB stays TSTAMP-free); this gate
#        reads the TB's verdict lines off the xsim log.
#   ro : the COMPILED-OUT negative in a detached worktree whose ct_pkg has
#        CT_EN_AXIS_TS = 0. No RDL regen -- the switch has no profile
#        override, which is why this leg lives in check_negative_legs
#        EXTRA_LEGS rather than NEGATIVE_LEGS. Same TB, same stimulus;
#        element 2 must be INVALID and the strobe the historical 8'hFF.
# Both legs additionally require the TB's end-to-end PASS line, so a leg
# that died before the AXIS checks cannot count as green.
# The worktree discipline follows scripts/cli_addr64_test.sh: the switch is
# flipped in a throwaway worktree, never in the tree under test, and a
# missing git metadata makes the leg SKIP (77), never silently pass.
# Self-contained: bootstraps the csr_cap xsim project with abc (ct_need_prj).
# NOT for upstream.
#   usage: bash scripts/cli_axists_test.sh [full|on|ro]
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_abc

tb=csr_cap_tb
prj_rel="tests/hsi/01_csr_cap/${tb}.abc"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${AXISTS_WT:-${CT_WORKTREE_ROOT:-$(dirname "$here")/ctte_worktrees}/c0a_axists_ro}"
mode="${1:-full}"
verdict=0

# The two TB verdict markers, kept as FIXED strings (grep -F) so the
# check_negative_legs EXTRA_LEGS entry can quote them literally.
MARK_ON='elem2 valid + strictly monotonic -- PASS'
MARK_RO='AXIS TS compiled out: elem2 invalid + Strb 0xff -- PASS'
MARK_E2E='PASS: ACT-CAP DAQ commands observed on AXIS sink'

cnt_f () { grep -cF "$1" "$2" 2>/dev/null || true; }
chk () { # $1 = label, $2 = actual, $3 = expected
	if [ "$2" = "$3" ]; then printf '%-52s: PASS (%s)\n' "$1" "$2"
	else printf '%-52s: FAIL (got %s, want %s)\n' "$1" "$2" "$3"; verdict=1; fi
}

# Build + run the testbench inside tree $1; log = <xsim dir>/xsim_axists_$2.log.
run_leg () { # $1 = tree, $2 = tag
	local tree="$1" tag="$2" xd rc=0
	( cd "$tree" && . "$tree/scripts/ct_env.sh" && ct_need_prj "$tb" "$prj_rel" ) \
		>"$here/bld/axists_${tag}_prj.log" 2>&1 || return 78
	xd="$tree/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
	[ -d "$xd" ] || return 78
	(
		cd "$xd" || exit 78
		rm -rf xsim.dir
		xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
			|| { echo "FAIL xvlog ($tag)"; grep -i error xvlog.log | head -3; exit 4; }
		xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl \
			-s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
			|| { echo "FAIL xelab ($tag)"; grep -i error xelab.log | head -3; exit 5; }
		printf 'run -all\nquit\n' > _runall.tcl
		ct_xsim "xsim_axists_${tag}.log" "${tb}_snap" -tclbatch _runall.tcl \
			|| { echo "FAIL: xsim leg $tag unusable (reason above)"; exit 6; }
	) || rc=$?
	echo "$xd/xsim_axists_${tag}.log"
	return $rc
}

if [ "$mode" = "full" ] || [ "$mode" = "on" ]; then
	echo "### leg ON (committed tree, CT_EN_AXIS_TS=1)"
	log_on="$(run_leg "$here" on)"; rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "leg on: FAIL (rc=$rc)"; verdict=1
	else
		chk "ON: TS element valid + strictly monotonic"  "$(cnt_f "$MARK_ON"  "$log_on")" 1
		chk "ON: sim leg completed end to end"           "$(cnt_f "$MARK_E2E" "$log_on")" 1
	fi
fi

if [ "$mode" = "full" ] || [ "$mode" = "ro" ]; then
	echo "### leg RO (worktree, CT_EN_AXIS_TS=0 -- compiled-out negative)"
	head_sha="$(git rev-parse --short HEAD)"
	if [ ! -d "$WT" ]; then
		git worktree add --detach "$WT" "$head_sha" >"$here/bld/axists_worktree.log" 2>&1 \
			|| { echo "SKIP: cannot create worktree $WT (see bld/axists_worktree.log)"; exit 77; }
	else
		git -C "$WT" checkout -f "$head_sha" >"$here/bld/axists_worktree.log" 2>&1 \
			|| { echo "SKIP: cannot check out $head_sha in $WT"; exit 77; }
	fi
	sed -i -E "s/(localparam bit CT_EN_AXIS_TS = )[01];/\10;/" "$WT/rtl/pkg/ct_pkg.sv"
	grep -nE "localparam bit CT_EN_AXIS_TS = " "$WT/rtl/pkg/ct_pkg.sv"

	log_ro="$(run_leg "$WT" ro)"; rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "leg ro: FAIL (rc=$rc)"; verdict=1
	else
		chk "RO: elem2 invalid + historical 8'hFF strobe" "$(cnt_f "$MARK_RO"  "$log_ro")" 1
		chk "RO: sim leg completed end to end"            "$(cnt_f "$MARK_E2E" "$log_ro")" 1
		# The negative is only meaningful if the positive marker is ABSENT.
		chk "RO: no ON-verdict in the compiled-out build" "$(cnt_f "$MARK_ON"  "$log_ro")" 0
	fi
fi

echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
