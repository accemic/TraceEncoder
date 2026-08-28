#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Phase-2c RepeatBranch (TCODE 30) OFF-vs-ON verification (local bring-up aid).
# Self-contained: clones the 07 test's xsim .prj (abc's @-resolver is broken
# since the tree was vendored) with the TB source swapped, then runs the
# snapshot twice and NexRv-decodes both. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=repeat_branch_tb
src_tb=repeated_history_tb   # donor project (same env, same libs)

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/08_repeat_branch/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_one () { # $1 = tag, $2... = extra xsim args
	local tag="$1"; shift
	# The S-7 guard leg's dump must stay OUTSIDE the atb_*.bin glob: the
	# byte-neutrality manifests (p7/p8_off_neutrality.sh, r2_final_mint.sh)
	# collect atb_*.bin per TB, and the pinned REF_FINAL families are
	# append-only -- a guard leg must not force a re-mint.
	local dump="atb_${tag}.bin"
	case "$tag" in alias) dump="s7guard_${tag}.bin" ;; esac
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin" "$dump"
	# Per-leg reference snapshot: the +RB_ALIAS leg runs a DIFFERENT program
	# (its guard block sits in front), so a shared expected.pcs would poison
	# the off/on comparisons after the alias leg rewrote it.
	cp "${tb}.expected.pcs" "${tag}.expected.pcs"
	"$NEXRV" -deco "$dump" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${tag}.pcout" -full > "nexrv_${tag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
}

echo "### run OFF"; run_one off
echo "### run ON ";  run_one on -testplusarg REPEAT_BRANCH
# S-7 regression guard (P10 soak run 930): same-target/different-source laps.
# Its reference differs from off/on (guard block in front) -- run_one
# snapshots every leg's own expected.pcs.
echo "### run ALIAS"; run_one alias -testplusarg RB_ALIAS

exp="off.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp"   > exp.norm
norm off.pcs  > off.norm
norm on.pcs   > on.norm
n_exp=$(grep -c . exp.norm); n_off=$(grep -c . off.norm); n_on=$(grep -c . on.norm)
sz_off=$(stat -c%s atb_off.bin); sz_on=$(stat -c%s atb_on.bin)
err_off=$(grep -c -i error nexrv_off.log); err_on=$(grep -c -i error nexrv_on.log)
rb_on=$(grep -c 'RepeatBranch' nexrv_on.log || true)

pfx=$(( n_off < n_on ? n_off : n_on ))
head -n "$pfx" exp.norm > exp.pfx
head -n "$pfx" off.norm > off.pfx
head -n "$pfx" on.norm  > on.pfx

echo "======================================================"
echo "expected PCs   : $n_exp"
echo "OFF decoded    : $n_off PCs, atb $sz_off B, errors $err_off"
echo "ON  decoded    : $n_on PCs, atb $sz_on B, errors $err_on"
echo "verified prefix: $pfx PCs (tail beyond this lost to host ATB truncation)"
echo "RepeatBranch   : $rb_on msgs in ON decode"
echo "------------------------------------------------------"
verdict=0
if cmp -s exp.pfx off.pfx; then echo "OFF prefix == reference : PASS"; else echo "OFF prefix == reference : FAIL"; verdict=1; diff exp.pfx off.pfx | head; fi
if cmp -s exp.pfx on.pfx;  then echo "ON  prefix == reference : PASS"; else echo "ON  prefix == reference : FAIL"; verdict=1; diff exp.pfx on.pfx | head; fi
if cmp -s off.pfx on.pfx;  then echo "OFF prefix == ON prefix : PASS (lossless fold)"; else echo "OFF prefix == ON prefix : FAIL"; verdict=1; fi
if [ "$err_off" -eq 0 ] && [ "$err_on" -eq 0 ]; then echo "decode errors           : PASS (none)"; else echo "decode errors           : note off=$err_off on=$err_on (tail truncation)"; fi
if [ "$sz_on" -lt "$sz_off" ]; then
	pct=$(( 100 - sz_on*100/sz_off ))
	echo "ON atb < OFF atb        : PASS (compression $sz_off -> $sz_on B, -$pct%)"
else
	echo "ON atb < OFF atb        : FAIL ($sz_off -> $sz_on)"; verdict=1
fi
# ---- S-7 guard (RB_ALIAS): the collapse of NON-byte-identical IBHs used to
# derail the decoder ("resolved source ... to a non-indirect instruction").
# Red when reintroduced: decode error + short/diverging PC list. The leg must
# also still COMPRESS (>=1 TCODE 30), so the guard cannot silently pass by
# never collapsing at all.
norm alias.pcs          > alias.norm
norm alias.expected.pcs > alias_exp.norm
n_aexp=$(grep -c . alias_exp.norm); n_alias=$(grep -c . alias.norm)
# Real decode aborts only ("ERROR: ..."/"Error: ..."); the legacy off/on
# counter also hits the harmless "0 error messages" Stat line.
err_alias=$(grep -c -E '(^|[[:space:]])(ERROR|Error):' nexrv_alias.log)
rb_alias=$(grep -c 'RepeatBranch' nexrv_alias.log || true)
pfx_a=$(( n_alias < n_aexp ? n_alias : n_aexp ))
head -n "$pfx_a" alias_exp.norm > alias_exp.pfx
head -n "$pfx_a" alias.norm     > alias.pfx
echo "ALIAS decoded  : $n_alias of $n_aexp PCs, errors $err_alias, RepeatBranch msgs $rb_alias"
if cmp -s alias_exp.pfx alias.pfx; then echo "ALIAS prefix == reference : PASS"; else echo "ALIAS prefix == reference : FAIL"; verdict=1; diff alias_exp.pfx alias.pfx | head; fi
if [ "$err_alias" -eq 0 ]; then echo "ALIAS decode errors     : PASS (none)"; else echo "ALIAS decode errors     : FAIL ($err_alias)"; verdict=1; fi
# >= 50%: the discriminator is the positional prefix compare above (the stale
# replay walk diverges at ~PC 9); the tail loses one periodic-sync window to
# the same host ATB truncation as the off/on legs (~84% coverage there).
if [ $(( n_alias * 100 )) -ge $(( n_aexp * 50 )) ]; then echo "ALIAS coverage >= 50%   : PASS ($n_alias/$n_aexp)"; else echo "ALIAS coverage >= 50%   : FAIL ($n_alias/$n_aexp)"; verdict=1; fi
if [ "$rb_alias" -ge 1 ]; then echo "ALIAS TCODE30 present   : PASS ($rb_alias)"; else echo "ALIAS TCODE30 present   : FAIL (leg no longer exercises RB)"; verdict=1; fi
echo "======================================================"
[ $verdict -eq 0 ] && [ "$pfx" -gt 50 ] && echo "OVERALL: PASS" || { echo "OVERALL: FAIL (prefix=$pfx)"; verdict=1; }
exit $verdict
