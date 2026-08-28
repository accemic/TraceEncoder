#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# W2 context-width gate: ct_pkg::CT_CONTEXT_WIDTH must reach the WIRE.
#
# The Ownership message (TCODE 2) carries tip._context in the PROCESS field
# of nexus_process_t = {_context[43:0], v, prv[1:0], format[1:0]}, i.e.
#
#     PROCESS = (context << 5) | (v << 4) | (prv << 2) | format
#
# and the field leaves the encoder as a VENDOR_VARIABLE with leading zeros
# stripped. So a context wider than 2 bits needs no format change and no CAPS
# bit -- but it does need the whole path (tip_if, tip_delay, composer cast)
# to actually carry it. That is what this gate measures: it rebuilds the
# tso testbench in a DETACHED WORKTREE with CT_CONTEXT_WIDTH set to <width>,
# runs the ownership leg (cpu_model.context_report('1), i.e. an all-ones
# context of exactly that width, prv = M) and requires the PREDICTED PROCESS
# value in the decoded message dump.
#
# Two built-in counter-proofs, so a green verdict cannot be an accident:
#   1. the value of a DIFFERENT width must NOT appear (at width 16 the
#      2-bit build's 0x6e would mean the upper context bits were dropped
#      somewhere on the way -- exactly the silent-truncation class this
#      knob is about),
#   2. the run must stay PC-lossless against the same cpu_model reference
#      the width-2 build is verified against -- a wider context must not
#      cost a single instruction.
#
#   usage: bash scripts/cli_ctxwidth_test.sh [width] [worktree-path]
#          (default width 16 = RISC-V satp.ASID under Sv39/Sv48)
#   MUTATE=1 ... narrow the composer's context cast back to 2 bits and
#          require the gate to go RED. Without this counter-proof the two
#          checks above only say "something matched"; with it they are shown
#          to be the reason the run is green.
#
# NOT for upstream (cli_* bring-up pattern, like cli_tso_test.sh whose
# testbench it reuses).
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
ct_need_vivado
ct_need_python
ct_need_abc
ct_need_nexrv

W="${1:-16}"
# Scratch worktree for this measurement. Default: a "ctte_worktrees"
# directory next to the repository, overridable with CT_WORKTREE_ROOT
# or the argument/variable below. Nothing here depends on one machine.
WT="${2:-${CT_WORKTREE_ROOT:-$(dirname "$repo")/ctte_worktrees}/w2_ctxwidth}"
case "$W" in ''|*[!0-9]*) echo "usage: $0 [width] [worktree]"; exit 2 ;; esac
if [ "$W" -lt 1 ] || [ "$W" -gt 44 ]; then
	echo "width must be 1..44 (NEXUS_MSG_PROCESS_WIDTH) -- ct_encoder rejects the rest at elaboration"
	exit 2
fi

tb=trig_seq_own_tb
src_tb=repeated_history_tb
head="$(git rev-parse --short HEAD)"

# Predicted PROCESS value. context = all ones of <width>, v = 0, prv = 3 (M),
# format = 2 (CONTEXT_SCONTEXT, because ctype != 0 on the reported retire).
ctx=$(( (1 << W) - 1 ))
exp_hex=$(printf '%x' $(( (ctx << 5) | (3 << 2) | 2 )))
# The value the 2-bit build produces, used as the counter-proof needle.
alt_hex=$(printf '%x' $(( (3 << 5) | (3 << 2) | 2 )))   # 0x6e

echo "### W2 context-width gate: CT_CONTEXT_WIDTH=$W at HEAD $head"
echo "### predicted PROCESS = 0x$exp_hex  (ctx=0x$(printf '%x' $ctx) << 5 | prv 3 << 2 | format 2)"

if [ ! -d "$WT" ]; then
	git worktree add --detach "$WT" "$head" >/dev/null 2>&1 || { echo "FAIL: worktree add"; exit 3; }
else
	git -C "$WT" checkout -f "$head" >/dev/null 2>&1 || { echo "FAIL: worktree checkout"; exit 3; }
fi
sed -i -E "s/(localparam int unsigned CT_CONTEXT_WIDTH[[:space:]]*=[[:space:]]*)[0-9]+;/\1${W};/" \
	"$WT/rtl/pkg/ct_pkg.sv"
grep -nE "localparam int unsigned CT_CONTEXT_WIDTH " "$WT/rtl/pkg/ct_pkg.sv" || {
	echo "FAIL: CT_CONTEXT_WIDTH declaration not found -- knob renamed?"; exit 3; }

MUTATE="${MUTATE:-0}"
if [ "$MUTATE" = "1" ]; then
	# Re-introduce the truncation this knob exists to prevent: keep only the
	# low 2 bits of the context in the Ownership payload.
	sed -i "s|? NEXUS_MSG_PROCESS_WIDTH'(tip._context) : '0;|? NEXUS_MSG_PROCESS_WIDTH'(tip._context[1:0]) : '0; // MUTATION|" \
		"$WT/rtl/preproc/ct_L23_preproc_composer_etip.sv"
	grep -n "MUTATION" "$WT/rtl/preproc/ct_L23_preproc_composer_etip.sv" \
		|| { echo "FAIL: mutation did not apply -- composer cast moved?"; exit 3; }
	echo "### MUTATE=1: composer context cast narrowed to [1:0] -- this run MUST be red"
fi

# The cli scripts clone the .prj of a primary test; a fresh worktree has none.
( cd "$WT" && . "$WT/scripts/ct_env.sh" && ct_need_prj "$src_tb" ) >/dev/null 2>&1 \
	|| { echo "FAIL: no prj for $src_tb (toolchain, not a property failure)"; exit 78; }

xd="$WT/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$WT/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
mkdir -p "$xd"
sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/15_trig_seq_own/${tb}.sv|" \
	"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
cp "$sd/glbl.v" "$xd/"

cd "$xd"
rm -rf xsim.dir
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
	|| { echo "FAIL xvlog"; grep -i error xvlog.log | head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl \
	-s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
	|| { echo "FAIL xelab"; grep -i error xelab.log | head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

rm -f "${tb}.atb.bin"
ct_xsim "xsim_own.log" "${tb}_snap" -testplusarg OWNLEG -tclbatch _runall.tcl || exit 6
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no ATB dump"; exit 6; }
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.own.pcout" -full \
	> nexrv_own.log 2>&1

cnt () { grep -cE "$1" "$2" || true; }
n_t2=$(cnt 'TCODE\[6\]=2 ' nexrv_own.log)
n_exp=$(cnt "PROCESS\\[[0-9]+\\]=0x${exp_hex} \\(" nexrv_own.log)
n_alt=$(cnt "PROCESS\\[[0-9]+\\]=0x${alt_hex} \\(" nexrv_own.log)
grep -E 'PROCESS\[[0-9]+\]=' nexrv_own.log | sed -E 's/^.*(TCODE\[6\]=2).*(PROCESS\[[0-9]+\]=[^ ]+).*/  \1 \2/' | head -6

norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
grep -E '[0-9]+ PC: 0x' nexrv_own.log | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > own.pcs
norm own.pcs > own.norm
norm "${tb}.expected.pcs" > exp.norm
n_pc=$(grep -c . own.norm); n_ref=$(grep -c . exp.norm)
pfx=$n_pc; [ "$n_ref" -lt "$pfx" ] && pfx=$n_ref
head -n "$pfx" own.norm > own.pfx; head -n "$pfx" exp.norm > exp.pfx

echo "======================================================"
echo "CT_CONTEXT_WIDTH        : $W"
echo "Ownership messages      : $n_t2"
echo "PROCESS == 0x$exp_hex (predicted) : $n_exp"
echo "PROCESS == 0x$alt_hex (width 2)   : $n_alt"
echo "PCs decoded / reference : $n_pc / $n_ref (compared prefix $pfx)"
echo "------------------------------------------------------"
v=0
if [ "$n_t2" -ge 2 ]; then echo "TCODE 2 emitted          : PASS ($n_t2)"
else echo "TCODE 2 emitted          : FAIL ($n_t2)"; v=1; fi
if [ "$n_exp" -ge 1 ]; then echo "predicted PROCESS on wire: PASS"
else echo "predicted PROCESS on wire: FAIL (0x$exp_hex never appeared)"; v=1; fi
if [ "$W" -eq 2 ] || [ "$n_alt" -eq 0 ]; then echo "no width-2 residue       : PASS"
else echo "no width-2 residue       : FAIL (0x$alt_hex found $n_alt x -- context truncated)"; v=1; fi
if cmp -s exp.pfx own.pfx; then echo "PC-lossless vs reference : PASS"
else echo "PC-lossless vs reference : FAIL"; diff exp.pfx own.pfx | head; v=1; fi
echo "======================================================"
if [ $v -eq 0 ] && [ "$pfx" -gt 50 ]; then res=PASS; else res=FAIL; v=1; fi
if [ "$MUTATE" = "1" ]; then
	if [ "$v" -ne 0 ]; then
		echo "OVERALL: PASS (counter-proof -- the mutated build is red, as it must be; inner verdict $res)"
		exit 0
	fi
	echo "OVERALL: FAIL (counter-proof -- the mutated build stayed GREEN, so the gate proves nothing)"
	exit 1
fi
echo "OVERALL: $res"
exit $v
