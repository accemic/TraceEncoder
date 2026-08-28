#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P7 / G9 trigger-configuration-register verification (te 0x050/0x054/0x058).
# Runs tests/instruction/32_trig_regs six times:
#   off    : reset defaults              -> the trigger pulse does nothing
#   legacy : InstTrigEnable=1, Action0=0 -> historical SYNC=6 marker (E-P7-2
#                                           regression guard: UNCHANGED)
#   notify : InstTrigEnable=0, Action0=4 -> the SAME marker via the register
#   both   : InstTrigEnable=1, Action0=4 -> exactly ONE marker (de-dup)
#   offact : InstTrigEnable=1, Action0=3 -> the pulse STOPS instruction tracing
#   onact  : InstTrigEnable=1, Action0=2 -> the pulse STARTS instruction tracing
# The WARL / "trigger does not exist" negatives ($fatal on mismatch) run
# inside every leg -- an xsim exit with a fatal shows up as a missing PASS
# line here.
# Each leg is compared against ITS OWN cpu_model reference (the two
# on/off legs deliberately trace a different PC set).
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=trig_regs_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/32_trig_regs/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_one () { # $1 = tag, $2... = extra xsim args
	local tag="$1"; shift
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin"      "atb_${tag}.bin"
	cp "${tb}.expected.pcs" "exp_${tag}.pcs"
	"$NEXRV" -deco "atb_${tag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${tag}.pcout" -full > "nexrv_${tag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
}

norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
cnt () { grep -cE "$1" "$2" || true; }
verdict=0
chk () { # $1 = label, $2 = actual, $3 = expected
	if [ "$2" = "$3" ]; then printf '%-44s: PASS (%s)\n' "$1" "$2"
	else printf '%-44s: FAIL (got %s, want %s)\n' "$1" "$2" "$3"; verdict=1; fi
}
chk_ge () { # $1 = label, $2 = actual, $3 = minimum
	if [ "$2" -ge "$3" ]; then printf '%-44s: PASS (%s)\n' "$1" "$2"
	else printf '%-44s: FAIL (got %s, want >= %s)\n' "$1" "$2" "$3"; verdict=1; fi
}

# ---------------------------------------------------------------------------
# ro mode: the COMPILED-OUT negative (CT_EN_TRIG_REGS = 0). Run this in a
# worktree whose ct_pkg has the switch at 0 and whose RDL profile has been
# regenerated -- the register then is a read-only constant 0 twice over (RDL
# profile + WARL wrapper). Same stimulus as the notify leg of the full run,
# which produces exactly ONE marker when the feature is compiled in; here it
# must produce NONE, and the programming must not stick.
# ---------------------------------------------------------------------------
if [ "${1:-full}" = "ro" ]; then
	echo "### run NOTIFY (compiled out)"
	run_one notify -testplusarg NOTIFYLEG -testplusarg TRIGREGS_RO
	norm notify.pcs > notify.norm; norm exp_notify.pcs > exp_notify.norm
	echo "======================================================"
	n=$(grep -c . notify.norm); e=$(grep -c . exp_notify.norm)
	m=$(( n < e ? n : e ))
	if [ "$m" -gt 20 ] && head -n "$m" exp_notify.norm | cmp -s - <(head -n "$m" notify.norm); then
		printf '%-44s: PASS (%s PCs)\n' "RO leg lossless vs own reference" "$m"
	else
		printf '%-44s: FAIL (n=%s exp=%s)\n' "RO leg lossless vs own reference" "$n" "$e"; verdict=1
	fi
	chk "WARL probes OK"                    "$(cnt 'WARL / non-existent-trigger probes: OK' xsim_notify.log)" 1
	chk "legal actions refused (RO probes)" "$(cnt 'compiled-out RO probes: OK' xsim_notify.log)" 1
	chk "NO marker with the feature out"    "$(cnt 'SYNC\[4\]=0x6\b' nexrv_notify.log)" 0
	echo "======================================================"
	[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
	exit $verdict
fi

legs="off legacy notify both offact onact"
echo "### run OFF   "; run_one off
echo "### run LEGACY"; run_one legacy -testplusarg LEGACYLEG
echo "### run NOTIFY"; run_one notify -testplusarg NOTIFYLEG
echo "### run BOTH  "; run_one both   -testplusarg BOTHLEG
echo "### run OFFACT"; run_one offact -testplusarg OFFACTLEG
echo "### run ONACT "; run_one onact  -testplusarg ONACTLEG

for t in $legs; do norm "$t.pcs" > "$t.norm"; norm "exp_$t.pcs" > "exp_$t.norm"; done

echo "======================================================"
# --- every leg decodes PC-lossless against ITS OWN reference --------------
for t in $legs; do
	n=$(grep -c . "$t.norm"); e=$(grep -c . "exp_$t.norm")
	m=$(( n < e ? n : e ))
	if [ "$m" -gt 20 ] && head -n "$m" "exp_$t.norm" | cmp -s - <(head -n "$m" "$t.norm"); then
		printf '%-44s: PASS (%s PCs)\n' "$t lossless vs own reference" "$m"
	else
		printf '%-44s: FAIL (n=%s exp=%s)\n' "$t lossless vs own reference" "$n" "$e"; verdict=1
	fi
done
echo "------------------------------------------------------"
# --- the in-sim WARL / non-existent-trigger probes ran in every leg -------
for t in $legs; do
	chk "WARL probes OK ($t)" "$(cnt 'WARL / non-existent-trigger probes: OK' "xsim_$t.log")" 1
done
echo "------------------------------------------------------"
# --- SYNC=6 marker accounting --------------------------------------------
s6_off=$(cnt 'SYNC\[4\]=0x6\b' nexrv_off.log)
s6_leg=$(cnt 'SYNC\[4\]=0x6\b' nexrv_legacy.log)
s6_not=$(cnt 'SYNC\[4\]=0x6\b' nexrv_notify.log)
s6_bot=$(cnt 'SYNC\[4\]=0x6\b' nexrv_both.log)
chk    "OFF: no marker (Action0=0, TrigEn=0)"   "$s6_off" 0
chk    "LEGACY: exactly one marker"             "$s6_leg" 1
chk    "NOTIFY: exactly one marker (Action0=4)" "$s6_not" 1
chk    "BOTH: still exactly ONE marker (de-dup)" "$s6_bot" 1
echo "------------------------------------------------------"
# --- trace-off / trace-on actions ----------------------------------------
# OFFACT stops tracing at the pulse, so its PC set is a strict PREFIX of the
# untouched OFF leg; ONACT starts at the pulse, so its PC set is a strict
# SUFFIX. Both must therefore be SHORTER than the baseline and must not
# invent PCs (covered by the per-leg lossless check above).
n_off=$(grep -c . off.norm)
n_offact=$(grep -c . offact.norm)
n_onact=$(grep -c . onact.norm)
if [ "$n_offact" -lt "$n_off" ] && [ "$n_offact" -gt 20 ]; then
	printf '%-44s: PASS (%s < %s)\n' "OFFACT traces less than baseline" "$n_offact" "$n_off"
else
	printf '%-44s: FAIL (%s vs %s)\n' "OFFACT traces less than baseline" "$n_offact" "$n_off"; verdict=1
fi
if [ "$n_onact" -lt "$n_off" ] && [ "$n_onact" -gt 20 ]; then
	printf '%-44s: PASS (%s < %s)\n' "ONACT traces less than baseline" "$n_onact" "$n_off"
else
	printf '%-44s: FAIL (%s vs %s)\n' "ONACT traces less than baseline" "$n_onact" "$n_off"; verdict=1
fi
# The trace-off action must end the traced region with the trace-off
# correlation message (TCODE 33) -- and with exactly ONE of them: the TB's
# own InstTracing=0 at the end then finds tracing already stopped.
chk    "OFFACT trace-off correlation (TCODE 33)" "$(cnt 'TCODE\[6\]=33 ' nexrv_offact.log)" 1
# The trace-on action must produce a TRACE_ENABLE re-anchor (SYNC=5).
chk_ge "ONACT emits TRACE_ENABLE (SYNC=5)"   "$(cnt 'SYNC\[4\]=0x5\b' nexrv_onact.log)" 1
chk    "OFF baseline has no extra ENABLE"    "$(cnt 'SYNC\[4\]=0x5\b' nexrv_off.log)" 0
echo "------------------------------------------------------"
# --- the register route is a SECOND SOURCE, not a second code path --------
# legacy (InstTrigEnable=1, Action0=0) and notify (InstTrigEnable=0,
# Action0=4) must produce the identical MESSAGE stream. The raw bytes differ
# in exactly one place and for a documented reason: ENAB bit 13 (TRIG_SYNC)
# mirrors the runtime InstTrigEnable, which is 1 in one leg and 0 in the
# other. Everything else -- every TCODE and every SYNC code, in order -- must
# match, and the ENAB delta must be exactly that one bit.
tcodes () { grep -oE 'TCODE\[6\]=[0-9]+' "$1"; }
syncs ()  { grep -oE 'SYNC\[4\]=0x[0-9a-f]+' "$1"; }
if diff -q <(tcodes nexrv_legacy.log) <(tcodes nexrv_notify.log) >/dev/null \
   && diff -q <(syncs nexrv_legacy.log) <(syncs nexrv_notify.log) >/dev/null; then
	printf '%-44s: PASS\n' "legacy == notify (TCODE + SYNC sequence)"
else
	printf '%-44s: FAIL\n' "legacy == notify (TCODE + SYNC sequence)"; verdict=1
	diff <(tcodes nexrv_legacy.log) <(tcodes nexrv_notify.log) | head
fi
enab_leg=$(grep -oE 'ENAB\[[0-9]+\]=0x[0-9a-f]+' nexrv_legacy.log | head -1 | sed 's/.*=//')
enab_not=$(grep -oE 'ENAB\[[0-9]+\]=0x[0-9a-f]+' nexrv_notify.log | head -1 | sed 's/.*=//')
enab_xor=$(printf '0x%x' $(( enab_leg ^ enab_not )))
chk "legacy^notify ENAB delta == bit 13 only" "$enab_xor" "0x2000"
# legacy vs both: adding Action0=4 to a build that already has
# InstTrigEnable=1 must change NOTHING on the wire -- that IS the de-dup.
if cmp -s atb_legacy.bin atb_both.bin; then
	printf '%-44s: PASS\n' "legacy stream == both stream (bytes)"
else
	printf '%-44s: FAIL\n' "legacy stream == both stream (bytes)"; verdict=1
fi
echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
