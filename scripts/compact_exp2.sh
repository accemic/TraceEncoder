#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Compact-packer experiment, part 2 -- coverage complement to compact_exp.sh.
# It runs the arms the main suite does not cover, pairwise (compact=0 vs
# compact=1, identical ptsuite profile, md5 comparison):
#   - the TIMESTAMPS legs of test 06 (absolute/delta TSTAMP, the TCODE 30
#     exception indirectly via the baseline): 06 +TIMESTAMPS and
#     +TIMESTAMPS+IMPLICIT_RETURN
#   - older instruction tests via cli_sim.sh: basic, interrupts (traps ->
#     BTYPE INTERRUPT/EXCEPTION on TCODE 12/28), stress (RCODE 0/1 drains),
#     periodic_sync (TCODE 9/11/12 rotation)
# The PASS/FAIL of the --pc checks is informational; the hard criterion is
# byte identity of the ATB streams between the two legs.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
LOG="bld/compact_exp2.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

PKG="rtl/pkg/ct_pkg.sv"
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }
set_ts () { sed -i -E "s/(localparam int unsigned CT_TS_WIDTH = )[0-9]+;/\1${1};/" "$PKG"; }
set_steps () { sed -i -E "s/(localparam int unsigned CT_SLICER_STEPS = )[0-9]+;/\1${1};/" "$PKG"; }

ptsuite_profile () {
	set_sw CT_EN_DAQ 0; set_sw CT_EN_DATA_TRACE 0; set_sw CT_EN_ACT 0; set_sw CT_EN_FILTERS 0; set_sw CT_EN_WATCHPOINT_MSG 0; set_sw CT_EN_AXIS_TS 0; set_sw CT_EN_DF_DROP 0; set_sw CT_EN_DF_ADDR_COMPRESS 0
	for f in CT_EN_IMPLICIT_RETURN CT_EN_REPEATED_HISTORY CT_EN_WIDE_ICNT CT_EN_REPEAT_BRANCH CT_EN_JTC CT_EN_BP; do set_sw $f 1; done
	set_sw CT_SINGLE_CLOCK 0; set_ts 64; set_steps 2
	"$PYRDL" scripts/gen_rdl_profile.py >> "$LOG" 2>&1
}
full_profile () {
	set_sw CT_EN_DAQ 1; set_sw CT_EN_DATA_TRACE 1; set_sw CT_EN_ACT 1; set_sw CT_EN_FILTERS 1; set_sw CT_EN_WATCHPOINT_MSG 1; set_sw CT_EN_AXIS_TS 1; set_sw CT_EN_DF_DROP 1; set_sw CT_EN_DF_ADDR_COMPRESS 1
	for f in CT_EN_IMPLICIT_RETURN CT_EN_REPEATED_HISTORY CT_EN_WIDE_ICNT CT_EN_REPEAT_BRANCH CT_EN_JTC CT_EN_BP; do set_sw $f 1; done
	set_sw CT_SINGLE_CLOCK 0; set_ts 64; set_steps 2; set_sw CT_COMPACT_PACKER 0
	"$PYRDL" scripts/gen_rdl_profile.py >> "$LOG" 2>&1
}

irtb=implicit_return_tb
irxd="bld/${irtb}.abc.vivado/${irtb}.abc.sim/sim_1/behav/xsim"

run_leg () { # $1 leg-tag
	local leg="$1"
	local out="bld/compact2_manifest_${leg}.txt"
	: > "$out"

	# --- test 06 TIMESTAMPS legs (fresh compile in the 06 project) ---
	( cd "$irxd" && rm -rf xsim.dir \
	  && xvlog --relax -L uvm -prj "${irtb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
	  && xelab --relax --debug off -L uvm "xil_defaultlib.${irtb}" xil_defaultlib.glbl -s "${irtb}_snap" -log xelab.log >/dev/null 2>&1 \
	  && printf 'run -all\nquit\n' > _runall.tcl ) \
	  || { say "[$leg] 06-ts: FAIL (compile)"; grep -iE "^ERROR" "$irxd/xvlog.log" "$irxd/xelab.log" 2>/dev/null | head -4 | tee -a "$LOG"; return 1; }
	local tag args
	for tag in ts ts_ir; do
		args="-testplusarg TIMESTAMPS"
		[ "$tag" = "ts_ir" ] && args="$args -testplusarg IMPLICIT_RETURN"
		( cd "$irxd" && rm -f "${irtb}.atb.bin" \
		  && ct_xsim "xsim_${leg}_${tag}.log" "${irtb}_snap" $args -tclbatch _runall.tcl )
		if [ -f "$irxd/${irtb}.atb.bin" ]; then
			"$NEXRV" -deco "$irxd/${irtb}.atb.bin" -pcinfo "$irxd/${irtb}.nexrv.info" -pcout "$irxd/${irtb}.${tag}.pcout" -full > "$irxd/nexrv_${leg}_${tag}.log" 2>&1
			local n e
			n=$(grep -cE '[0-9]+ PC: 0x' "$irxd/nexrv_${leg}_${tag}.log")
			e=$(grep -ci error "$irxd/nexrv_${leg}_${tag}.log")
			echo "$(md5sum "$irxd/${irtb}.atb.bin" | cut -d' ' -f1)  06_${tag}.atb" >> "$out"
			say "[$leg] 06-${tag}: PCs=$n decode-errors=$e"
		else
			say "[$leg] 06-${tag}: FAIL (no ATB)"
		fi
	done

	# --- older instruction tests (cli_sim with --pc, informational) ---
	local name tb
	for name in basic interrupts stress periodic_sync; do
		case "$name" in
			basic) tb=basic_tb;; interrupts) tb=interrupts_tb;;
			stress) tb=stress_tb;; periodic_sync) tb=periodic_sync_tb;;
		esac
		rm -rf "bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim/xsim.dir" 2>/dev/null
		rm -f  "bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim/${tb}.atb.bin" 2>/dev/null
		if bash scripts/cli_sim.sh "$name" --pc >> "$LOG" 2>&1; then
			say "[$leg] $name --pc: PASS"
		else
			say "[$leg] $name --pc: FAIL (informational; the hard criterion is the leg md5)"
		fi
		local bin="bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim/${tb}.atb.bin"
		if [ -f "$bin" ]; then
			echo "$(md5sum "$bin" | cut -d' ' -f1)  ${name}.atb" >> "$out"
		else
			say "[$leg] $name: produced no ATB binary"
			echo "MISSING  ${name}.atb" >> "$out"
		fi
	done
	sort -k2 -o "$out" "$out"
	say "[$leg] Manifest: $(grep -c . "$out") Eintraege"
}

say "=== C2-0: ptsuite + compact=0 ==="
ptsuite_profile; set_sw CT_COMPACT_PACKER 0
run_leg c20

say "=== C2-1: ptsuite + compact=1 ==="
set_sw CT_COMPACT_PACKER 1
run_leg c21

if cmp -s bld/compact2_manifest_c20.txt bld/compact2_manifest_c21.txt; then
	say "C2 MANIFEST c20 == c21: BYTE-IDENTICAL ($(grep -c . bld/compact2_manifest_c20.txt) entries)"
else
	say "C2-MANIFEST ABWEICHUNG:"
	diff bld/compact2_manifest_c20.txt bld/compact2_manifest_c21.txt | head -20 | tee -a "$LOG"
fi

say "=== restore defaults + closing test 06 ==="
full_profile
bash scripts/cli_ir_test.sh >> "$LOG" 2>&1 && say "[voll] 06 ir: PASS" || say "[voll] 06 ir: FAIL"
m1=$(md5sum "$irxd/atb_off.bin" | cut -d' ' -f1)
say "[voll] OFF-md5: $([ "$m1" = "61c0a2eac0d6a94fa51c785b936295af" ] && echo IDENTISCH || echo "ABWEICHEND:$m1")"
say "=== FERTIG ==="
