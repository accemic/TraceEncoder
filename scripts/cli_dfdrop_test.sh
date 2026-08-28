#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P7 / G10 data-trace drop policy + G12 overflow status verification.
# Runs tests/data/06_df_drop twice with the SAME stimulus:
#   off  : DataDropEna = 0 -> the eTIP queue runs over, the generic overflow
#          path fires (Error + SYNC=7 re-anchor) and instruction trace is lost
#   drop : DataDropEna = 1 -> the watermark sheds data trace first; the queue
#          never runs over, the instruction trace stays LOSSLESS and the loss
#          is announced by ONE Error/ECODE=0x02 marker WITHOUT a SYNC=7
# The status-bit contract (set / RW1C / clear-on-enable) is checked in sim
# ($fatal); this script gates the WIRE side.
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=df_drop_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/data/06_df_drop/${tb}.sv|" \
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
	if [ "$2" = "$3" ]; then printf '%-46s: PASS (%s)\n' "$1" "$2"
	else printf '%-46s: FAIL (got %s, want %s)\n' "$1" "$2" "$3"; verdict=1; fi
}
chk_ge () {
	if [ "$2" -ge "$3" ]; then printf '%-46s: PASS (%s)\n' "$1" "$2"
	else printf '%-46s: FAIL (got %s, want >= %s)\n' "$1" "$2" "$3"; verdict=1; fi
}

# ---------------------------------------------------------------------------
# ro mode: the COMPILED-OUT negative (CT_EN_DF_DROP = 0). Run this in a
# worktree whose ct_pkg has the switch at 0 and whose RDL profile has been
# regenerated -- DataDropEna is then a read-only constant 0
# (CT_PROFILE_NO_DF_DROP, rdl/ct_cs_cpuif.rdl). Same stimulus and the same
# programming attempt as the drop leg, which sheds data trace and keeps the
# instruction trace lossless when the feature is compiled in; here the write
# must be refused, no data-only marker may appear, CAPS.22 must be clear, and
# the queue must overrun exactly like the OFF leg.
# ---------------------------------------------------------------------------
if [ "${1:-full}" = "ro" ]; then
	echo "### run DROP-attempt (compiled out)"
	run_one ro -testplusarg DFDROP_RO
	norm ro.pcs > ro.norm; norm exp_ro.pcs > exp_ro.norm
	n_ro=$(grep -c . ro.norm); e_ro=$(grep -c . exp_ro.norm)
	echo "======================================================"
	grep -h 'eTIP CVS max fill reached' xsim_ro.log | sed 's/^/RO   /'
	chk "in-sim status contract passed (ro)"  "$(cnt 'df_drop_tb\] PASS \(sim\)' xsim_ro.log)" 1
	chk "DataDropEna write refused (RO probe)" "$(cnt 'compiled-out RO probe: DataDropEna refused' xsim_ro.log)" 1
	chk "NO data-only marker with the feature out" "$(cnt 'ECODE\[[0-9]+\]=0x2\b' nexrv_ro.log)" 0
	# The generic path is identified by its SHAPE, not by a fixed ECODE
	# value: this leg runs in the switched-off worktree of the byte-neutrality
	# gate, whose profile also has CT_EN_WATCHPOINT_MSG = 0, and the ECODE
	# bitmask lists exactly the classes the PROFILE can lose. Pinning 0x2f
	# here would test P4's switch, not P7's. The CF bit is the invariant --
	# the control-flow path exists in every profile
	# (ETIP_OVF_ECODE, ct_L23_preproc_composer_etip.sv).
	chk_ge "generic overflow Error present"        "$(cnt 'TCODE\[6\]=8 ' nexrv_ro.log)" 1
	chk_ge "generic overflow re-anchor SYNC=7"     "$(cnt 'SYNC\[4\]=0x7\b' nexrv_ro.log)" 1
	ecode_ro=$(grep -aoE 'ECODE\[[0-9]+\]=0x[0-9a-f]+' nexrv_ro.log | head -1 | sed 's/.*=0x//')
	echo "generic-overflow ECODE seen: 0x${ecode_ro:-?} (profile-gated bitmask)"
	chk "generic ECODE names the CF class (bit 2)" "$(( (0x${ecode_ro:-0} >> 2) & 1 ))" 1
	caps_ro=$(grep -oE 'CAPS\[[0-9]+\]=0x[0-9a-f]+' nexrv_ro.log | head -1 | sed 's/.*=//')
	enab_ro=$(grep -oE 'ENAB\[[0-9]+\]=0x[0-9a-f]+' nexrv_ro.log | head -1 | sed 's/.*=//')
	chk "CAPS.22 clear (feature compiled out)" "$(( (caps_ro >> 22) & 1 ))" 0
	chk "ENAB.22 clear (nothing to announce)"  "$(( (enab_ro >> 22) & 1 ))" 0
	# The queue overruns as in the OFF leg -- without the policy the same
	# stimulus must lose instruction trace, otherwise the leg proves nothing.
	if [ "$n_ro" -lt "$e_ro" ]; then
		printf '%-46s: PASS (%s of %s)\n' "RO leg loses PCs (queue overran)" "$n_ro" "$e_ro"
	else
		printf '%-46s: FAIL (%s of %s -- no overrun?)\n' "RO leg loses PCs (queue overran)" "$n_ro" "$e_ro"; verdict=1
	fi
	echo "======================================================"
	[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
	exit $verdict
fi

echo "### run OFF (DataDropEna=0) "; run_one off  -testplusarg NODROPLEG
echo "### run DROP (DataDropEna=1)"; run_one drop

for t in off drop; do norm "$t.pcs" > "$t.norm"; norm "exp_$t.pcs" > "exp_$t.norm"; done
n_exp=$(grep -c . exp_drop.norm)
n_off=$(grep -c . off.norm)
n_drop=$(grep -c . drop.norm)

# Both legs must have run their in-sim status contract to the end.
chk "in-sim status contract passed (off)"  "$(cnt 'df_drop_tb\] PASS \(sim\)' xsim_off.log)"  1
chk "in-sim status contract passed (drop)" "$(cnt 'df_drop_tb\] PASS \(sim\)' xsim_drop.log)" 1

echo "======================================================"
echo "expected PCs (cpu_model) : $n_exp"
echo "OFF  decoded PCs         : $n_off"
echo "DROP decoded PCs         : $n_drop"
grep -h 'eTIP CVS max fill reached' xsim_off.log  | sed 's/^/OFF  /'
grep -h 'eTIP CVS max fill reached' xsim_drop.log | sed 's/^/DROP /'
echo "------------------------------------------------------"

# ---- the headline claim: the policy protects the INSTRUCTION trace -------
# DROP leg: the PC stream must be complete against the cpu_model oracle.
if [ "$n_drop" -eq "$n_exp" ] && cmp -s exp_drop.norm drop.norm; then
	printf '%-46s: PASS (%s PCs)\n' "DROP leg PC-lossless vs oracle" "$n_drop"
else
	printf '%-46s: FAIL (%s of %s)\n' "DROP leg PC-lossless vs oracle" "$n_drop" "$n_exp"; verdict=1
	diff exp_drop.norm drop.norm | head -5
fi
# OFF leg: the SAME stimulus without the policy loses instruction trace --
# that contrast is what makes the DROP result meaningful (if the OFF leg did
# not overrun, the DROP leg proved nothing).
if [ "$n_off" -lt "$n_exp" ]; then
	printf '%-46s: PASS (%s of %s)\n' "OFF leg loses PCs (queue overran)" "$n_off" "$n_exp"
else
	printf '%-46s: FAIL (%s of %s -- no overrun?)\n' "OFF leg loses PCs (queue overran)" "$n_off" "$n_exp"; verdict=1
fi
echo "------------------------------------------------------"

# ---- marker shape --------------------------------------------------------
err_off=$(cnt 'TCODE\[6\]=8 ' nexrv_off.log)
err_drop=$(cnt 'TCODE\[6\]=8 ' nexrv_drop.log)
s7_off=$(cnt 'SYNC\[4\]=0x7\b' nexrv_off.log)
s7_drop=$(cnt 'SYNC\[4\]=0x7\b' nexrv_drop.log)
chk_ge "OFF: generic overflow Error present"  "$err_off"  1
chk_ge "OFF: generic overflow re-anchor SYNC=7" "$s7_off" 1
chk    "DROP: exactly ONE Error marker"       "$err_drop" 1
chk    "DROP: NO SYNC=7 re-anchor"            "$s7_drop"  0
# The drop marker must name ONLY the data-trace class (ECODE 0x02); the
# generic overflow marker names every class the profile can lose (0x2f).
chk    "DROP: ECODE == 0x02 (data trace only)" "$(cnt 'ECODE\[[0-9]+\]=0x2\b' nexrv_drop.log)" 1
# 0x2f is the FULL profile mask (CF|DF|DAQ|OWNERSHIP|WATCHPOINT). Correct
# here because this path only runs in the full profile; the ro path above
# identifies the generic marker by its SHAPE instead, because it runs in a
# worktree whose profile is shaped by the byte-neutrality gate.
chk    "DROP: no full-class ECODE 0x2f"        "$(cnt 'ECODE\[[0-9]+\]=0x2f\b' nexrv_drop.log)" 0
chk_ge "OFF: full-class ECODE 0x2f present"    "$(cnt 'ECODE\[[0-9]+\]=0x2f\b' nexrv_off.log)"  1
# The runtime negative: with the policy disarmed the drop marker must not
# exist at all -- the same stimulus overruns the queue, and the encoder
# must then take the generic path, not the data-only one.
chk    "OFF: no data-only ECODE 0x02 (negative)" "$(cnt 'ECODE\[[0-9]+\]=0x2\b' nexrv_off.log)" 0
echo "------------------------------------------------------"

# ---- the policy really shed data, and only data -------------------------
df_off=$(cnt 'TCODE\[6\]=(5|6|13|14) ' nexrv_off.log)
df_drop=$(cnt 'TCODE\[6\]=(5|6|13|14) ' nexrv_drop.log)
echo "data-trace messages: OFF=$df_off DROP=$df_drop"
if [ "$df_drop" -lt "$df_off" ] && [ "$df_drop" -gt 20 ]; then
	printf '%-46s: PASS (%s < %s)\n' "DROP sheds data trace but keeps some" "$df_drop" "$df_off"
else
	printf '%-46s: FAIL (%s vs %s)\n' "DROP sheds data trace but keeps some" "$df_drop" "$df_off"; verdict=1
fi
# ENAB bit 22 (DF_DROP) must be advertised exactly in the drop leg.
enab_off=$(grep -oE 'ENAB\[[0-9]+\]=0x[0-9a-f]+' nexrv_off.log  | head -1 | sed 's/.*=//')
enab_drop=$(grep -oE 'ENAB\[[0-9]+\]=0x[0-9a-f]+' nexrv_drop.log | head -1 | sed 's/.*=//')
chk "ENAB.22 clear in OFF leg"  "$(( (enab_off  >> 22) & 1 ))" 0
chk "ENAB.22 set in DROP leg"   "$(( (enab_drop >> 22) & 1 ))" 1
caps_off=$(grep -oE 'CAPS\[[0-9]+\]=0x[0-9a-f]+' nexrv_off.log | head -1 | sed 's/.*=//')
chk "CAPS.22 set (feature compiled in)" "$(( (caps_off >> 22) & 1 ))" 1
echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
