#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# X2a address-width gate: the encoder puts the FULL instruction address on
# the wire, in both builds of the CT_XLEN knob.
#
#   leg 32 : the committed tree (CT_XLEN = 32). Base PC 0x0000_1000 has to
#            come back out of the raw ATB bytes exactly.
#   leg 64 : a DETACHED WORKTREE with CT_XLEN = 64. Base PC
#            0xFFFF_FFC0_0000_1000 -- above 2^32, so a path that truncates
#            anywhere produces a plausible-looking 32-bit address and the
#            byte check catches it.
#
# The verdict is read off the RAW BYTE STREAM (scripts/check_addr64_emission.py),
# not from a decoder: the reference decoder's own 64-bit support is a
# separate work package (R1.2), and a gate that can only fail together with
# the tool it uses proves nothing about the encoder. What is NOT claimed
# here, therefore, is a round trip -- this gate says the bytes carry the
# address, not that anything decodes them yet.
#
# The 64-bit leg builds in a worktree so the working tree is never left with
# a flipped switch (same discipline as scripts/p8_off_neutrality.sh). It is
# SKIPPED (exit 77, never silently passed) when the worktree cannot be
# created -- e.g. in a checkout without the git metadata.
#
#   usage: bash scripts/cli_addr64_test.sh [worktree-path]
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_python
ct_need_abc

tb=addr64_tb
prj_rel="tests/instruction/35_addr64/${tb}.abc"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${1:-${CT_WORKTREE_ROOT:-$(dirname "$here")/ctte_worktrees}/r11_xlen64}"
PY="${PY:-python}"
FAILS=0

PC32=0x00001000
PC64=0xFFFFFFC000001000

# Build + run the testbench inside tree $1, print the ATB path on stdout.
run_leg () { # $1 = tree, $2 = tag
	local tree="$1" tag="$2" xd rc=0
	( cd "$tree" && . "$tree/scripts/ct_env.sh" && ct_need_prj "$tb" "$prj_rel" ) \
		>"$here/bld/addr64_${tag}_prj.log" 2>&1 || return 78
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
		rm -f "${tb}.atb.bin"
		ct_xsim "xsim_${tag}.log" "${tb}_snap" -tclbatch _runall.tcl || exit 6
		[ -s "${tb}.atb.bin" ] || { echo "FAIL: no ATB dump ($tag)"; exit 7; }
	) || rc=$?
	echo "$xd/${tb}.atb.bin"
	return $rc
}

# The checker itself first: a reconstruction that is wrong in the HIGH
# groups looks perfectly fine on a low address, so the legs below could go
# green on a broken checker. These vectors pin the arithmetic (both corners,
# plus the negative control that truncation is not accepted).
echo "### selftest (byte framer + field reconstruction)"
if "$PY" scripts/check_addr64_emission.py --selftest; then
	echo "selftest: PASS"
else
	echo "selftest: FAIL"; FAILS=$((FAILS+1))
fi

echo "### leg 32 (committed tree, CT_XLEN=32)"
bin32="$(run_leg "$here" 32)"; rc=$?
if [ "$rc" -ne 0 ]; then
	echo "leg 32: FAIL (rc=$rc)"; FAILS=$((FAILS+1))
else
	if "$PY" scripts/check_addr64_emission.py "$bin32" --expect-pc "$PC32" --dump; then
		echo "leg 32: PASS"
	else
		echo "leg 32: FAIL"; FAILS=$((FAILS+1))
	fi
fi

echo "### leg 64 (worktree, CT_XLEN=64)"
head="$(git rev-parse --short HEAD)"
if [ ! -d "$WT" ]; then
	git worktree add --detach "$WT" "$head" >"$here/bld/addr64_worktree.log" 2>&1 \
		|| { echo "SKIP: cannot create worktree $WT (see bld/addr64_worktree.log)"; exit 77; }
else
	git -C "$WT" checkout -f "$head" >"$here/bld/addr64_worktree.log" 2>&1 \
		|| { echo "SKIP: cannot check out $head in $WT"; exit 77; }
fi
sed -i -E "s/(localparam int unsigned CT_XLEN = )[0-9]+;/\164;/" "$WT/rtl/pkg/ct_pkg.sv"
grep -nE "localparam int unsigned CT_XLEN = " "$WT/rtl/pkg/ct_pkg.sv"

bin64="$(run_leg "$WT" 64)"; rc=$?
if [ "$rc" -ne 0 ]; then
	echo "leg 64: FAIL (rc=$rc)"; FAILS=$((FAILS+1))
else
	if "$PY" scripts/check_addr64_emission.py "$bin64" --expect-pc "$PC64" --dump; then
		echo "leg 64: PASS"
	else
		echo "leg 64: FAIL"; FAILS=$((FAILS+1))
	fi
fi

echo "======================================================"
[ "$FAILS" -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL ($FAILS leg(s))"
exit "$FAILS"
