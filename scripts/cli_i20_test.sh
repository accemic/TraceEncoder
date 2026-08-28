#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# P0-04 -- the decode/conformance gate of the ICNT-overflow drain family
# (tests/instruction/20_icnt_overflow).  The testbench header has named this
# script since the test was written and it did not exist; its own pass criterion
# is "clean run, ATB bytes produced", so the test PRODUCED an over-cap ICNT
# field for months and reported PASS.  That is the hole this gate closes.
#
# The invariant under test is a FIELD WIDTH, not a behaviour: N-Trace 1.0 caps
# the program-trace I-CNT variable at 8 bit (16 with the Accemic wide-ICNT
# compression).  The field is MSEO-variable-length, so an over-cap value costs
# one wire byte and decodes perfectly -- no PC check, no decode gate and no
# byte-neutrality gate can see it.  Hence a gate that reads the field VALUES off
# the wire (scripts/check_icnt_cap.py), next to the usual losslessness checks.
#
# Legs -- three configurations over the same stimulus, plus the red control:
#   def   HTM (reset default): the composer-side pre-drain of a truly
#         control-flow-free run, and the msg_gen inline/hold drains of chains of
#         SILENT control-flow events (not-taken, inferable, folded return).
#   btm   InstMode=3: cf_btm_icnt_overflow_hold and the silent BTM arms.
#   bp    HTM + branch prediction: cf_bp_icnt_drain_hold and the
#         correctly-predicted-branch arm.
#   mut   RED COUNTER-PROOF.  A throwaway worktree in which the two named drain
#         expressions of rtl/ct_L2_msg_gen.sv are mutated back to the pre-fix
#         form (drain the SUM, keep nothing).  The leg REQUIRES the I12
#         assertion to fire and requires check_icnt_cap to find over-cap fields.
#         A green mut leg fails the gate: a check that cannot go red proves
#         nothing about the three that are green.
# Per leg: xsim ran to $finish (ct_xsim), SVA channel clean, NexRv decodes to
# the end with the full PC stream (decode_and_check --pc), every
# instruction-count field within the cap.
#
# Worktree discipline follows scripts/cli_axists_test.sh / cli_addr64_test.sh:
# the mutation happens in a throwaway tree, NEVER in the tree under test, and
# missing git metadata makes the leg SKIP (77) instead of silently passing.
# Self-contained: bootstraps the xsim project with abc (ct_need_prj).
# Local bring-up aid, not part of the upstream CI.
#   usage: bash scripts/cli_i20_test.sh [full|def|btm|bp|mut]
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_abc
ct_need_python
ct_need_nexrv

tb=icnt_overflow_tb
prj_rel="tests/instruction/20_icnt_overflow/${tb}.abc"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${I20_WT:-${CT_WORKTREE_ROOT:-$(dirname "$here")/ctte_worktrees}/p004_icnt_mut}"
mode="${1:-full}"
# Narrow cap: the testbench never sets trTeInstFeatures.InstEnWideIcnt, so
# MAX_NEXUS_ICNT is 2^8-1 in every leg.  Passing it explicitly keeps the gate
# honest if the TB ever turns the wide cap on -- the number would then be wrong
# and visibly so, rather than silently permissive.
CAP=255
verdict=0

chk () { # $1 = label, $2 = rc
	if [ "$2" -eq 0 ]; then printf '%-56s: PASS\n' "$1"
	else printf '%-56s: FAIL (rc=%s)\n' "$1" "$2"; verdict=1; fi
}

# Build the project in tree $1 and run the testbench with the plusargs in $3.
# Echoes the xsim working directory; the log is <xd>/xsim_i20_<tag>.log.
run_leg () { # $1 = tree, $2 = tag, $3.. = xsim plusargs
	local tree="$1" tag="$2"; shift 2
	local xd rc=0
	( cd "$tree" && . "$tree/scripts/ct_env.sh" && ct_need_prj "$tb" "$prj_rel" ) \
		>"$here/bld/i20_${tag}_prj.log" 2>&1 || return 78
	xd="$tree/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
	[ -d "$xd" ] || return 78
	(
		cd "$xd" || exit 78
		rm -rf xsim.dir "${tb}.atb.bin"
		xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log "xvlog_${tag}.log" >/dev/null 2>&1 \
			|| { echo "FAIL xvlog ($tag)"; grep -i error "xvlog_${tag}.log" | head -3; exit 4; }
		xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl \
			-s "${tb}_snap_${tag}" -log "xelab_${tag}.log" >/dev/null 2>&1 \
			|| { echo "FAIL xelab ($tag)"; grep -i error "xelab_${tag}.log" | head -3; exit 5; }
		printf 'run -all\nquit\n' > _runall.tcl
		# CT_SVA_EXPECT=off ONLY on the mutation leg -- there the assertion
		# firing IS the verdict, and it is counted explicitly below.  The three
		# real legs keep the exact-zero expectation.
		if [ "$tag" = mut ]; then export CT_SVA_EXPECT=off; fi
		ct_xsim "xsim_i20_${tag}.log" "${tb}_snap_${tag}" -tclbatch _runall.tcl "$@" \
			|| { echo "FAIL: xsim leg $tag unusable (reason above)"; exit 6; }
		# The dump is only the run's dump if the run wrote one THIS time (the
		# rm above makes a stale artefact impossible to mistake for a result).
		[ -s "${tb}.atb.bin" ] || { echo "FAIL: leg $tag produced no ATB bytes"; exit 7; }
	) || rc=$?
	echo "$xd"
	return $rc
}

# Losslessness of a leg whose stream needs a NexRv decode OPTION.
# scripts/decode_and_check.sh has no way to pass one through, and a branch-
# prediction stream needs `-bp` -- without it NexRv stops at the first TCODE 56
# and reports a short decode (measured here first as "539 of 950 PCs", which
# looks exactly like an encoder defect and is a decoder invocation). The same
# note is in scripts/cli_bp_test.sh:7. So that leg decodes directly, with the
# same strictness: the decoded PC list must equal <tb>.expected.pcs in full and
# in order.
decode_with_flags () { # $1 = xsim dir, $2 = tag, $3 = NexRv flags
	local xd="$1" tag="$2" flags="$3" n_exp n_got
	( cd "$xd" \
	  && "$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" \
	              -pcout "${tb}.${tag}.pcout" -full $flags >"nexrv_${tag}.log" 2>&1
	  grep -aE '[0-9]+ PC: 0x' "nexrv_${tag}.log" \
	    | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
	  # The simulator writes expected.pcs with CRLF, the extraction above with
	  # LF. Comparing them raw reports all 950 lines as different while every
	  # address matches -- a line ending that reads like a decode failure.
	  tr -d '\r' < "${tb}.expected.pcs" > "${tag}.exp.pcs"
	  n_exp=$(wc -l < "${tag}.exp.pcs"); n_got=$(wc -l < "${tag}.pcs")
	  echo "    [decode-pc] ${tag}: expected $n_exp PCs, decoded $n_got PCs (NexRv $flags)"
	  grep -aq "Decoded OK" "nexrv_${tag}.log" || { echo "    [decode] no 'Decoded OK'"; exit 1; }
	  cmp -s "${tag}.exp.pcs" "${tag}.pcs" || { echo "    [decode-pc] MISMATCH"; exit 1; }
	)
}

# One real leg: run, decode losslessly, then read the field values.
# $2 = NexRv decode flags ("" -> the shared decode_and_check), $3.. = plusargs
real_leg () { # $1 = tag, $2 = deco flags, $3.. = plusargs
	local tag="$1" deco="$2"; shift 2
	local xd rc=0
	echo "### leg ${tag} ($*)"
	xd="$(run_leg "$here" "$tag" "$@")"; rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "leg ${tag}: FAIL (rc=$rc)"; verdict=1; return
	fi
	# Losslessness: NexRv decodes to the end and every expected PC appears.
	if [ -n "$deco" ]; then
		decode_with_flags "$xd" "$tag" "$deco"
		chk "${tag}: NexRv decodes the full PC stream" $?
	else
		scripts/decode_and_check.sh --pc "$tb" >"$here/bld/i20_${tag}_decode.log" 2>&1
		chk "${tag}: NexRv decodes the full PC stream" $?
		grep -aE 'PASS|FAIL|ERROR' "$here/bld/i20_${tag}_decode.log" | tail -3 | sed 's/^/    /'
	fi
	# Conformance: the ICNT carriers stay within the cap.
	python3 scripts/check_icnt_cap.py --atb "$xd/${tb}.atb.bin" \
		--cap "$CAP" --label "${tag}: I-CNT fields"
	chk "${tag}: every instruction count within the cap" $?
}

case "$mode" in
	full|def) real_leg def ""    ;;
esac
case "$mode" in
	full|btm) real_leg btm ""    -testplusarg BTMLEG ;;
esac
case "$mode" in
	full|bp)  real_leg bp  "-bp" -testplusarg BPLEG  ;;
esac

if [ "$mode" = full ] || [ "$mode" = mut ]; then
	echo "### leg mut (RED counter-proof: pre-fix drain expressions restored)"
	head_sha="$(git rev-parse --short HEAD)"
	if [ ! -d "$WT" ]; then
		git worktree add --detach "$WT" "$head_sha" >"$here/bld/i20_worktree.log" 2>&1 \
			|| { echo "SKIP: cannot create worktree $WT (see bld/i20_worktree.log)"; exit 77; }
	else
		git -C "$WT" checkout -f "$head_sha" >"$here/bld/i20_worktree.log" 2>&1 \
			|| { echo "SKIP: cannot check out $head_sha in $WT"; exit 77; }
	fi
	# THE mutation.  Both halves are needed: emitting the sum is the over-cap
	# value, keeping nothing is what made the accounting add up while the field
	# was too wide.  Reverting only one half would change the PC stream and the
	# leg would fail for the wrong reason.
	mg="$WT/rtl/ct_L2_msg_gen.sv"
	# The three named expressions became MULTI-LINE on 2026-08-20 (the split
	# that keeps the excess instead of dropping it), so the line-wise sed that
	# used to sit here no longer matched. python3 replaces the whole block
	# instead; the count check below is unchanged and still refuses to run a
	# mutation that did not apply -- that check is what caught the
	# reformatting, and it has to keep working the next time the block moves.
	python3 - "$mg" <<'MUTPY'
import re
import sys
import pathlib

p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
block = re.compile(
    r"\tuwire logic icnt_drain_over_cap[^\n]*\n"
    r"\tuwire logic \[ICNT_ACC_W-1:0\] icnt_drain_value[^;]*;\n"
    r"\tuwire logic \[ICNT_ACC_W-1:0\] icnt_drain_residue[^;]*;\n")
# The pre-fix form, both halves: emit the SUM (that is the over-cap value)
# and keep NOTHING (that is what made the accounting add up while the field
# was still too wide). Reverting only one half would change the PC stream and
# the leg would fail for the wrong reason.
repl = ("\tuwire logic [ICNT_ACC_W-1:0] icnt_drain_value   = "
        "CurrICnt + ICNT_ACC_W'(etip_cf.icnt);\n"
        "\tuwire logic [ICNT_ACC_W-1:0] icnt_drain_residue = '0;\n")
s2, n = block.subn(repl, s, count=1)
if n:
    p.write_text(s2, encoding="utf-8", newline="\n")
MUTPY
	mutated="$(grep -cE "icnt_drain_(value   = CurrICnt \+|residue = '0;)" "$mg")"
	if [ "$mutated" -ne 2 ]; then
		echo "mut: FAIL -- the mutation did not apply (matched $mutated of 2 lines)."
		echo "  The named expressions in rtl/ct_L2_msg_gen.sv were renamed or"
		echo "  reformatted; update the sed above, do NOT drop the leg."
		verdict=1
	else
		grep -nE "uwire logic \[ICNT_ACC_W-1:0\] icnt_drain_" "$mg" | sed 's/^/    /'
		xd="$(run_leg "$WT" mut)"; rc=$?
		if [ "$rc" -ne 0 ]; then
			echo "mut: FAIL (rc=$rc) -- the red leg has to RUN to be red"; verdict=1
		else
			n_i12="$(grep -acE 'I12: (ResourceFull|TCODE)' "$xd/xsim_i20_mut.log" || true)"
			if [ "${n_i12:-0}" -ge 1 ]; then
				printf '%-56s: PASS (%s line(s))\n' "mut: I12 assertion fires on the pre-fix form" "$n_i12"
				grep -aE 'I12:' "$xd/xsim_i20_mut.log" | head -2 | sed 's/^/    /'
			else
				printf '%-56s: FAIL (0 lines)\n' "mut: I12 assertion fires on the pre-fix form"
				echo "    The mutation compiled but no assertion fired -- either the"
				echo "    stimulus stopped reaching the drain arms or I12 is vacuous."
				verdict=1
			fi
			python3 scripts/check_icnt_cap.py --atb "$xd/${tb}.atb.bin" \
				--cap "$CAP" --expect-over --label "mut: I-CNT fields"
			chk "mut: over-cap fields present on the wire" $?
		fi
	fi
fi

echo "======================================================"
if [ $verdict -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $verdict
