#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# P4 compact=0/1 pair leg for the Device ID message (TCODE 1).
#
# The compact packer is the SECOND egress path: it builds the MDO/MSEO
# chunks from its own per-TCODE layout table, so every new message format
# exists twice and only a pair run proves the two agree. Contract (as in
# r2_final_mint.sh phases 2/3): identical MESSAGE SEQUENCE -- the raw ATB
# file is quantized to beats and idle POSITIONS shift with assembly
# latency, the message bytes do not.
#
# Profile: CF-only (the packer's elaboration guard demands
# DAQ=DATA_TRACE=ACT=0), hence also CT_EN_DF_ADDR_COMPRESS=0 (P3 guard)
# and CT_EN_WATCHPOINT_MSG=0 (P4 guard: WPHIT comes from the ACT-ST path)
# and CT_EN_DF_DROP=0 (P7 guard: no data trace to drop).
# The Watchpoint message therefore has NO packer arm at all -- unreachable
# code by construction, documented in ct_L2_compact_packer.sv; the same
# holds for the P7 data-trace drop marker.
#
# Requires a committed working tree for rtl/pkg (restores via git checkout).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=status_msgs_tb
src_tb=repeated_history_tb
PKG="rtl/pkg/ct_pkg.sv"

# The line that used to stand here was
#     PYRDL=".venv-rdl-win/Scripts/python.exe"
# -- one host's venv layout, hard-wired, unchecked. It fails on every machine
# without that directory, and the failure arrives as `FAIL: gen_rdl_profile`,
# exit 9: a property verdict about the compact packer, from a gate that never
# reached a simulation.
#
# Worse, it defeats a fallback the generator deliberately has. A linked `git
# worktree` carries no .venv-rdl* of its own (gitignored, it belongs to the
# main checkout), and scripts/gen_rdl_profile.py resolves exactly that case --
# this tree first, then the main working tree via `git rev-parse
# --git-common-dir` (its own comment: "P8 audit C-1, third incident of the
# class"). Measured 2026-08-13 in a fresh linked worktree: the hard-wired path
# gives `FAIL: gen_rdl_profile`, rc=9, while `python3 scripts/gen_rdl_profile.py`
# in the SAME directory writes ct_cs_cpuif.sv and returns 0. The launcher was
# the only thing missing, and the gate blamed the encoder for it.
#
# The generator imports nothing but the standard library and finds the pinned
# peakrdl venv itself, so any WORKING interpreter does -- which is what
# ct_need_python guarantees (or 78, TOOL, instead of a verdict).
ct_need_python
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }
restore () {
	git checkout -- "$PKG" rtl/pkg/ct_cs_cpuif.sv rtl/pkg/ct_cs_cpuif_pkg.sv rdl/ct_profile.inc.rdl 2>/dev/null
}
trap restore EXIT

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/31_status_msgs/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

run_leg () { # $1 = compact 0/1
	local cmp="$1"
	set_sw CT_EN_DAQ 0; set_sw CT_EN_DATA_TRACE 0; set_sw CT_EN_ACT 0; set_sw CT_EN_FILTERS 0; set_sw CT_EN_DF_DROP 0
	set_sw CT_EN_DF_ADDR_COMPRESS 0
	set_sw CT_EN_WATCHPOINT_MSG 0; set_sw CT_EN_AXIS_TS 0
	set_sw CT_COMPACT_PACKER "$cmp"
	# stdout+stderr are KEPT and printed on failure. They used to go to
	# /dev/null, so the generator's own diagnosis -- which names the missing
	# pinned toolchain and what to do about it -- was thrown away and replaced
	# by four words that point at the wrong subsystem.
	if ! rdlout="$(python3 scripts/gen_rdl_profile.py 2>&1)"; then
		echo "FAIL: gen_rdl_profile (compact=$cmp) --"
		printf '%s\n' "$rdlout" | sed 's/^/    /'
		exit 9
	fi
	( cd "$xd"
	  rm -rf xsim.dir
	  xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log "xvlog_cmp${cmp}.log" >/dev/null 2>&1 || { echo "FAIL xvlog (compact=$cmp)"; exit 4; }
	  xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log "xelab_cmp${cmp}.log" >/dev/null 2>&1 || { echo "FAIL xelab (compact=$cmp)"; exit 5; }
	  printf 'run -all\nquit\n' > _runall.tcl
	  ct_xsim "xsim_did_cmp${cmp}.log" "${tb}_snap" -testplusarg DIDLEG -tclbatch _runall.tcl || exit 6
	  cp "${tb}.atb.bin" "atb_did_cmp${cmp}.bin"
	  # Message-level dump: keep the decoded field lines + the Stat line;
	  # raw byte echoes and idle separators shift with assembly latency.
	  "$NEXRV" -deco "atb_did_cmp${cmp}.bin" -pcinfo "${tb}.nexrv.info" -pcout /dev/null -full 2>/dev/null \
		| grep -E '=|^Stat:' > "msgdump_cmp${cmp}.txt" ) || exit $?
}

echo "### compact=0 (historical formatter + MSEO/MDO)"
run_leg 0
echo "### compact=1 (single-module packer)"
run_leg 1
restore

cd "$xd"
n0=$(grep -c 'TCODE\[6\]=1 ' msgdump_cmp0.txt || true)
n1=$(grep -c 'TCODE\[6\]=1 ' msgdump_cmp1.txt || true)
verdict=0
echo "======================================================"
if [ "$n0" = "1" ] && [ "$n1" = "1" ]; then
	echo "TCODE 1 present in both arms : PASS (1 each)"
else
	echo "TCODE 1 present in both arms : FAIL (cmp0=$n0 cmp1=$n1)"; verdict=1
fi
if cmp -s msgdump_cmp0.txt msgdump_cmp1.txt; then
	echo "message sequence identical   : PASS ($(grep -c . msgdump_cmp0.txt) lines)"
else
	echo "message sequence identical   : FAIL"
	diff msgdump_cmp0.txt msgdump_cmp1.txt | head -20
	verdict=1
fi
echo "md5 cmp0: $(md5sum atb_did_cmp0.bin | cut -d' ' -f1)"
echo "md5 cmp1: $(md5sum atb_did_cmp1.bin | cut -d' ' -f1)"
echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
