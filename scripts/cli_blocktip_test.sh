#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# R1.3 block-ingress gate (ct_pkg::CT_EN_BLOCK_TIP, gap X1).
#
# Claim under test:
#
#     Block-wise reporting does not change the reconstructed flow,
#     only its packaging.
#
# The scenario (tests/instruction/36_block_tip) is written ONCE and driven
# TWO ways in the SAME block build:
#
#   serial  one instruction per tip beat (the historical shape)
#   block   1..4 instructions per beat, every terminator kind exercised
#
# Both legs log the SAME per-instruction oracle, so the reference
# block_tip_tb.expected.pcs is an oracle that never saw a block. Three
# verdicts, and all three have to hold:
#
#   1. serial leg decodes EXACTLY to the oracle (decode_and_check --pc,
#      strict: a short or divergent decode fails)
#   2. block  leg decodes EXACTLY to the same oracle
#   3. the block leg really packed: measured at tip_if, the same number of
#      halfwords arrives in strictly FEWER beats, with at least one beat
#      carrying more than one instruction
#
# (3) is not decoration. Without it the whole gate passes trivially if the
# block tasks silently degenerate to single retirements -- exactly the class
# of blind gate this programme has already produced four times.
#
# It deliberately does NOT check that the byte streams differ. That was the
# first design and it was wrong: the halfword distance between two
# control-flow events does not depend on how the beats were cut, so a block
# build emits the same messages with the same ICNTs. Byte-identical output
# is the CLAIM, not a symptom -- it is reported, and (3) is what keeps the
# gate honest.
#
# Mutation counter-proofs (MUT=M1..M4) flip ONE decision in the worktree and
# must make the gate RED. The first two attack the derivations, the last two
# the two defects this package actually found (F-2), so the gate is checked
# against the failures it was written for and not only against invented ones:
#
#   M1  TipBeatHalfwords ignores the block and counts one instruction
#       -> ICNT undercounts, the decoder's walk falls behind
#   M2  TipLastIaddr returns the block START as the CF source PC
#       -> branch/call/return sources are reported at the wrong address
#   M3  the ProgTraceSync anchor moves to the block's LAST instruction
#       -> every instruction of the anchoring block but the last one drops
#          out of the reconstruction
#   M4  only the anchoring block's last instruction carries over into the
#       next segment's count -> the same loss, one message later
#
# The build always happens in a DETACHED WORKTREE: the working tree is never
# left with a flipped switch (same discipline as scripts/p8_off_neutrality.sh
# and scripts/cli_addr64_test.sh) -- a neighbouring session measures ASIC
# area against the committed default profile.
#
#   usage: bash scripts/cli_blocktip_test.sh [worktree-path]
#          MUT=M1 bash scripts/cli_blocktip_test.sh   (counter-proof, M1..M4)
#
# Exit 0 = PASS, 77 = SKIP (no worktree possible), otherwise the failure
# count. For MUT runs the meaning is INVERTED and stated in the verdict line:
# a mutation that stays green is the finding.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_python
ct_need_abc

tb=block_tip_tb
prj_rel="tests/instruction/36_block_tip/${tb}.abc"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${1:-${CT_WORKTREE_ROOT:-$(dirname "$here")/ctte_worktrees}/r13_block_tip}"
MUT="${MUT:-}"
FAILS=0
say () { echo "[$(date +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------- worktree --
head="$(git rev-parse --short HEAD)"
say "source tree HEAD $head; worktree $WT; mutation '${MUT:-none}'"
if [ ! -d "$WT" ]; then
	git worktree add --detach "$WT" "$head" >"$here/bld/blocktip_worktree.log" 2>&1 \
		|| { echo "SKIP: cannot create worktree $WT (see bld/blocktip_worktree.log)"; exit 77; }
else
	git -C "$WT" checkout -f "$head" >"$here/bld/blocktip_worktree.log" 2>&1 \
		|| { echo "SKIP: cannot check out $head in $WT"; exit 77; }
fi
say "worktree at $(git -C "$WT" rev-parse --short HEAD)"

# The switch flip. Verified by grep, not assumed: a sed that matches nothing
# is silent, and the whole battery would then measure the SR build twice and
# call it a block gate.
sed -i -E "s/(localparam bit CT_EN_BLOCK_TIP = )0;/\11;/" "$WT/rtl/pkg/ct_pkg.sv"
if ! grep -qE "localparam bit CT_EN_BLOCK_TIP = 1;" "$WT/rtl/pkg/ct_pkg.sv"; then
	echo "FAIL: CT_EN_BLOCK_TIP flip did not take in $WT/rtl/pkg/ct_pkg.sv"; exit 3
fi
grep -nE "localparam bit CT_EN_BLOCK_TIP|localparam int unsigned CT_IRETIRE_WIDTH" \
	"$WT/rtl/pkg/ct_pkg.sv"

case "$MUT" in
	"") ;;
	M1) sed -i "s/TipBeatHalfwords = ct_pkg::CT_EN_BLOCK_TIP ? tip_icnt_t'(iretire)/TipBeatHalfwords = 1'b0 ? tip_icnt_t'(iretire)/" \
			"$WT/rtl/pkg/tip_pkg.sv"
		grep -q "TipBeatHalfwords = 1'b0 ?" "$WT/rtl/pkg/tip_pkg.sv" \
			|| { echo "FAIL: mutation M1 did not apply"; exit 3; }
		say "MUTATION M1 applied: TipBeatHalfwords always takes the SR branch" ;;
	M2) sed -i "s/TipLastIaddr   = (ct_pkg::CT_EN_BLOCK_TIP \&\& (|iretire))/TipLastIaddr   = (1'b0 \&\& (|iretire))/" \
			"$WT/rtl/pkg/tip_pkg.sv"
		grep -q "TipLastIaddr   = (1'b0 &&" "$WT/rtl/pkg/tip_pkg.sv" \
			|| { echo "FAIL: mutation M2 did not apply"; exit 3; }
		say "MUTATION M2 applied: TipLastIaddr always returns the block start" ;;
	M3) sed -i "s/etip_msg_next\[msg_id_next\].sub.cf.iaddr = tip.iaddr;/etip_msg_next[msg_id_next].sub.cf.iaddr = iaddr_last;/" \
			"$WT/rtl/preproc/ct_L23_preproc_composer_etip.sv"
		grep -q "sub.cf.iaddr = iaddr_last;" "$WT/rtl/preproc/ct_L23_preproc_composer_etip.sv" \
			|| { echo "FAIL: mutation M3 did not apply"; exit 3; }
		say "MUTATION M3 applied: the ProgTraceSync anchor moves to the LAST instruction of the block" ;;
		# No leading-tab anchor: the indentation is deep and getting the tab
		# count wrong makes the sed a silent no-op (it did, first try). The
		# bare assignment is unique on its own -- the accumulation reads
		# `icnt_cum_next + beat_halfwords` and the overflow re-anchor reads
		# `? beat_halfwords : '0`, neither of which contains this text.
	M4) sed -i "s/icnt_cum_next = beat_halfwords;/icnt_cum_next = (1 << tip.ilastsize);/" \
			"$WT/rtl/preproc/ct_L23_preproc_composer_etip.sv"
		grep -q "icnt_cum_next = (1 << tip.ilastsize);" "$WT/rtl/preproc/ct_L23_preproc_composer_etip.sv" \
			|| { echo "FAIL: mutation M4 did not apply"; exit 3; }
		say "MUTATION M4 applied: only the last instruction of an anchoring block carries over" ;;
	*)  echo "unknown MUT='$MUT' (expected M1..M4)"; exit 2 ;;
esac

# ------------------------------------------------------------------- legs ---
( cd "$WT" && . "$WT/scripts/ct_env.sh" && ct_need_prj "$tb" "$prj_rel" ) \
	>"$here/bld/blocktip_prj.log" 2>&1 \
	|| { echo "SKIP: cannot generate the xsim project (see bld/blocktip_prj.log)"; exit 77; }
xd="$WT/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
[ -d "$xd" ] || { echo "SKIP: xsim dir missing ($xd)"; exit 77; }

say "compiling"
(
	cd "$xd" || exit 78
	rm -rf xsim.dir
	xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
		|| { echo "FAIL xvlog"; grep -i error xvlog.log | head -5; exit 4; }
	xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl \
		-s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
		|| { echo "FAIL xelab"; grep -i error xelab.log | head -5; exit 5; }
	printf 'run -all\nquit\n' > _runall.tcl
) || exit $?

# $1 = tag, $2... = extra xsim args. Copies the artefacts out of the
# worktree so the second leg cannot overwrite the first one's evidence.
run_leg () {
	local tag="$1"; shift
	local rc=0
	(
		cd "$xd" || exit 78
		rm -f "${tb}.atb.bin" "${tb}.decoded.pcs" "${tb}.expected.pcs"
		ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
		[ -s "${tb}.atb.bin" ] || { echo "FAIL: no ATB dump ($tag)"; exit 7; }
		# The SVA half goes through the shared detector (V2) so this gate
		# knows the same spellings as every other one -- including
		# "Fatal:" and Verilator's "%Error", which this private grep did
		# not. The build markers below are this gate's OWN subject and
		# stay here.
		ct_no_sva_errors "xsim_${tag}.log" || { echo "FAIL: simulation reported an error ($tag)"; exit 8; }
		if grep -qE "ERROR:|BUILD-MISMATCH|BLOCK-TASK-IN-SR-BUILD|R1.3-BLOCK" "xsim_${tag}.log"; then
			echo "FAIL: build/profile marker in the transcript ($tag):"
			grep -E "ERROR:|BUILD-MISMATCH|BLOCK-TASK-IN-SR-BUILD|R1.3-BLOCK" "xsim_${tag}.log" | head -5
			exit 8
		fi
	) || rc=$?
	[ "$rc" -eq 0 ] || return "$rc"
	cp "$xd/${tb}.atb.bin"      "$here/bld/blocktip_${tag}.atb.bin"
	cp "$xd/${tb}.expected.pcs" "$here/bld/blocktip_${tag}.expected.pcs"
	grep -o "WITNESS beats=[0-9]* halfwords=[0-9]* max_beat_hw=[0-9]* events=[0-9]*" \
		"$xd/xsim_${tag}.log" | tail -1 > "$here/bld/blocktip_${tag}.witness"
	# Strict PC check, run from the WORKTREE so it finds that tree's bld/.
	( cd "$WT" && bash scripts/decode_and_check.sh --pc "$tb" ) \
		>"$here/bld/blocktip_${tag}.decode.log" 2>&1 || rc=$?
	[ -f "$xd/${tb}.decoded.pcs" ] && cp "$xd/${tb}.decoded.pcs" "$here/bld/blocktip_${tag}.decoded.pcs"
	return "$rc"
}

say "### leg serial (one instruction per beat)"
if run_leg serial -testplusarg SERIAL; then
	say "leg serial: PASS (decoded PCs == per-instruction oracle)"
else
	say "leg serial: FAIL"; tail -12 "$here/bld/blocktip_serial.decode.log" 2>/dev/null
	FAILS=$((FAILS+1))
fi

say "### leg block (1..4 instructions per beat)"
if run_leg block; then
	say "leg block: PASS (decoded PCs == per-instruction oracle)"
else
	say "leg block: FAIL"; tail -12 "$here/bld/blocktip_block.decode.log" 2>/dev/null
	FAILS=$((FAILS+1))
fi

# --------------------------------------------------------------- verdicts ---
say "### cross-checks"
if [ -f "$here/bld/blocktip_serial.decoded.pcs" ] && [ -f "$here/bld/blocktip_block.decoded.pcs" ]; then
	if diff -q "$here/bld/blocktip_serial.decoded.pcs" "$here/bld/blocktip_block.decoded.pcs" >/dev/null; then
		say "PC sequences serial == block: IDENTICAL ($(grep -c . "$here/bld/blocktip_block.decoded.pcs") PCs)"
	else
		say "PC sequences serial != block: DIFFER"
		diff -u "$here/bld/blocktip_serial.decoded.pcs" "$here/bld/blocktip_block.decoded.pcs" | head -20
		FAILS=$((FAILS+1))
	fi
else
	say "PC sequence comparison: INCONCLUSIVE (a leg produced no decode)"
	FAILS=$((FAILS+1))
fi

# ANTI-VACUITY -- measured at the PORT, not in the bytes.
#
# The first version of this check demanded that the two ATB streams DIFFER,
# on the assumption that packing shows up as fewer bytes. Run 3 showed the
# assumption is wrong, and instructively so: the halfword distance between
# two control-flow events does not depend on how the beats were cut, so the
# block leg emits the SAME messages with the SAME ICNTs -- byte-identical
# output is the correct result here, not a suspicious one. It is also the
# sharpest possible statement of the claim, so it is checked as such below.
#
# What that leaves is the real vacuity risk: block tasks that silently
# degenerate into single retirements would also produce identical bytes and
# identical PCs. The testbench therefore counts BEATS and HALFWORDS at
# tip_if and prints them; the block leg must deliver the same halfwords in
# strictly fewer beats, with at least one beat carrying more than one
# instruction.
wit_s="$(cat "$here/bld/blocktip_serial.witness" 2>/dev/null || true)"
wit_b="$(cat "$here/bld/blocktip_block.witness"  2>/dev/null || true)"
say "witness serial: ${wit_s:-<none>}"
say "witness block : ${wit_b:-<none>}"
field () { printf '%s\n' "$1" | sed -nE "s/.*$2=([0-9]+).*/\1/p"; }
sb=$(field "$wit_s" beats);      bb=$(field "$wit_b" beats)
sh=$(field "$wit_s" halfwords);  bh=$(field "$wit_b" halfwords)
bm=$(field "$wit_b" max_beat_hw)
if [ -z "$sb" ] || [ -z "$bb" ] || [ -z "$sh" ] || [ -z "$bh" ] || [ -z "$bm" ]; then
	say "port witness: INCONCLUSIVE (a leg printed no WITNESS line)"; FAILS=$((FAILS+1))
else
	if [ "$sh" -ne "$bh" ]; then
		say "port witness: FAIL -- the legs did not retire the same amount of binary (serial $sh halfwords, block $bh)"
		FAILS=$((FAILS+1))
	elif [ "$bb" -ge "$sb" ]; then
		say "port witness: FAIL -- block leg needed $bb beats for the same $bh halfwords as serial's $sb: it packed nothing"
		FAILS=$((FAILS+1))
	elif [ "$bm" -le 2 ]; then
		say "port witness: FAIL -- no beat carried more than one instruction (max $bm halfwords)"
		FAILS=$((FAILS+1))
	else
		say "port witness: PASS -- $bh halfwords in $bb beats (block) vs $sb beats (serial), largest beat $bm halfwords"
	fi
fi

# The sharp form of the claim: same messages, same ICNTs, same bytes.
if [ -f "$here/bld/blocktip_serial.atb.bin" ] && [ -f "$here/bld/blocktip_block.atb.bin" ]; then
	s_sz=$(stat -c%s "$here/bld/blocktip_serial.atb.bin")
	b_sz=$(stat -c%s "$here/bld/blocktip_block.atb.bin")
	if cmp -s "$here/bld/blocktip_serial.atb.bin" "$here/bld/blocktip_block.atb.bin"; then
		say "ATB streams BYTE-IDENTICAL ($s_sz B) -- block reporting changed the ingress, not the wire"
	else
		say "ATB streams differ: serial $s_sz B, block $b_sz B (PCs still match; message packing moved)"
	fi
else
	say "ATB comparison: INCONCLUSIVE"; FAILS=$((FAILS+1))
fi

echo "======================================================"
if [ -n "$MUT" ]; then
	if [ "$FAILS" -eq 0 ]; then
		echo "MUTATION $MUT: STAYED GREEN -- the gate does NOT detect this defect (finding)"
		exit 1
	fi
	echo "MUTATION $MUT: RED as required ($FAILS verdict(s) failed)"
	exit 0
fi
[ "$FAILS" -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL ($FAILS verdict(s))"
exit "$FAILS"
