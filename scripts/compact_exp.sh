#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Compact-packer experiment: in a control-flow-only profile,
# CT_COMPACT_PACKER=1 replaces nexus_formatter + msg_buffer + bit_slicer with
# the single-module packer ct_L2_compact_packer (per-TCODE layout table).
#   B0  featparity + compact=0  : sanity (test 06 OFF == reference) + synthesis
#                             baseline
#   B1  featparity + compact=1  : test 06 OFF == reference + synthesis MEASUREMENT
#   C0  ptsuite + compact=0 : the whole suite (CF only, suite features on) and
#                             an md5 manifest of every ATB artefact (baseline)
#   C1  ptsuite + compact=1 : suite again -- is the manifest byte-identical
#                             to C0?
#   A   full-profile defaults: closing regression, test 06 md5 OFF/ON plus the
#                             remaining suite. Proves the historical path is
#                             unchanged and leaves the repository in its
#                             default state.
# ptsuite = the full profile minus DAQ/DT/ACT/FILTERS (dual clock, TS64,
# steps=2): the smallest possible distance from the known-good suite
# configuration, so a profile effect cannot be mistaken for a packer effect.
# The hard comparison is the pairwise md5 manifest C0 == C1.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
LOG="bld/compact_exp.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

PKG="rtl/pkg/ct_pkg.sv"
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }
set_ts () { sed -i -E "s/(localparam int unsigned CT_TS_WIDTH = )[0-9]+;/\1${1};/" "$PKG"; }
set_steps () { sed -i -E "s/(localparam int unsigned CT_SLICER_STEPS = )[0-9]+;/\1${1};/" "$PKG"; }

featparity_profile () {
	set_sw CT_EN_DAQ 0; set_sw CT_EN_DATA_TRACE 0; set_sw CT_EN_ACT 0; set_sw CT_EN_FILTERS 0; set_sw CT_EN_WATCHPOINT_MSG 0; set_sw CT_EN_AXIS_TS 0; set_sw CT_EN_DF_DROP 0; set_sw CT_EN_DF_ADDR_COMPRESS 0
	for f in CT_EN_IMPLICIT_RETURN CT_EN_REPEATED_HISTORY CT_EN_WIDE_ICNT CT_EN_REPEAT_BRANCH CT_EN_JTC CT_EN_BP; do set_sw $f 0; done
	set_sw CT_SINGLE_CLOCK 1; set_ts 32; set_steps 1
	"$PYRDL" scripts/gen_rdl_profile.py >> "$LOG" 2>&1
}
ptsuite_profile () { # full profile minus DAQ/DT/ACT/FILTERS; suite features on
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

tb=implicit_return_tb
xd="bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
REF_AMDCMP="811f7d8830108e1125eeda06aab76334"
REF_FULL_OFF="61c0a2eac0d6a94fa51c785b936295af"
REF_FULL_ON="a9c69b3809196b5bd8717d3c8d4b755a"

sim06_off () { # $1 tag
	local tag="$1"
	( cd "$xd" && rm -rf xsim.dir \
	  && xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
	  && xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
	  && printf 'run -all\nquit\n' > _runall.tcl \
	  && ct_xsim "xsim_${tag}.log" "${tb}_snap" -tclbatch _runall.tcl ) \
	  || { say "$tag: FAIL (compile/sim)"; grep -iE "^ERROR" "$xd/xvlog.log" "$xd/xelab.log" 2>/dev/null | head -4 | tee -a "$LOG"; return 1; }
	local m n
	m=$(md5sum "$xd/${tb}.atb.bin" | cut -d' ' -f1)
	"$NEXRV" -deco "$xd/${tb}.atb.bin" -pcinfo "$xd/${tb}.nexrv.info" -pcout "$xd/${tb}.x.pcout" -full > "$xd/nexrv_${tag}.log" 2>&1
	n=$(grep -cE '[0-9]+ PC: 0x' "$xd/nexrv_${tag}.log")
	say "$tag: PCs=$n md5=$([ "$m" = "$REF_AMDCMP" ] && echo AMDCMP-IDENTISCH || echo "$m")"
}

synth_one () { # $1 name
	rm -rf bld/synth_ooc .Xil 2>/dev/null
	say "synth $1 gestartet"
	cmd //c "C:\\Xilinx\\Vivado\\2025.1\\bin\\vivado.bat -mode batch -source scripts/synth_encoder_ooc.tcl -tclargs xck26-sfvc784-2LV-c" > "bld/synth_exp_${1}.log" 2>&1
	if ! [ -f bld/synth_ooc/util_flat.rpt ]; then
		say "synth $1: Retry"
		cmd //c "C:\\Xilinx\\Vivado\\2025.1\\bin\\vivado.bat -mode batch -source scripts/synth_encoder_ooc.tcl -tclargs xck26-sfvc784-2LV-c" > "bld/synth_exp_${1}.log" 2>&1
	fi
	mkdir -p "bld/synth_ooc_cp_${1}"
	cp bld/synth_ooc/util_flat.rpt bld/synth_ooc/util_hier.rpt "bld/synth_ooc_cp_${1}/" 2>/dev/null || { say "synth $1: FAIL"; tail -6 "bld/synth_exp_${1}.log" | tee -a "$LOG"; return 1; }
	local l f b g
	l=$(grep -m1 "CLB LUTs" "bld/synth_ooc_cp_${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	f=$(grep -m1 "CLB Registers" "bld/synth_ooc_cp_${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	b=$(grep -m1 "Block RAM Tile" "bld/synth_ooc_cp_${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	g=$(grep -m1 "msg_gen_inst" "bld/synth_ooc_cp_${1}/util_hier.rpt" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
	say "synth $1: LUTs=$l FFs=$f BRAM=$b (msg_gen=$g)"
}

# Collect every suite testbench's ATB artefact into an md5 manifest (leg comparison)
suite_manifest () { # $1 outfile
	local out="$1"
	: > "$out"
	local d
	for d in implicit_return_tb repeated_history_tb repeat_branch_tb jtc_tb branch_predict_tb robustness_tb; do
		local x="bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"
		[ -d "$x" ] || continue
		local f
		for f in "$x"/atb_*.bin; do
			[ -f "$f" ] || continue
			echo "$(md5sum "$f" | cut -d' ' -f1)  ${d}/$(basename "$f")" >> "$out"
		done
	done
	sort -k2 -o "$out" "$out"
}

run_suite () { # $1 leg-tag; PASS/FAIL je Test + Manifest
	local leg="$1"
	local t d
	# Delete stale artefacts of earlier runs -- otherwise a test that never
	# reaches its ATB dump in this leg can look "identical" via an old file.
	for d in implicit_return_tb repeated_history_tb repeat_branch_tb jtc_tb branch_predict_tb robustness_tb; do
		rm -f "bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"/atb_*.bin 2>/dev/null
	done
	bash scripts/cli_ir_test.sh >> "$LOG" 2>&1 && say "[$leg] 06 ir: PASS" || say "[$leg] 06 ir: FAIL"
	for t in rh rb jtc bp robust; do
		bash scripts/cli_${t}_test.sh >> "$LOG" 2>&1 && say "[$leg] cli_${t}: PASS" || say "[$leg] cli_${t}: FAIL"
	done
	suite_manifest "bld/compact_manifest_${leg}.txt"
	say "[$leg] Manifest: $(grep -c . "bld/compact_manifest_${leg}.txt") artefacts"
}

say "=== B0: featparity + compact=0 (Sanity + Synthese-Baseline) ==="
featparity_profile; set_sw CT_COMPACT_PACKER 0
sim06_off b0
synth_one base

say "=== B1: featparity + compact=1 (Kernbeweis + Synthese-Messung) ==="
set_sw CT_COMPACT_PACKER 1
sim06_off b1
synth_one on

say "=== C0: ptsuite + compact=0 (suite baseline leg) ==="
ptsuite_profile; set_sw CT_COMPACT_PACKER 0
run_suite c0

say "=== C1: ptsuite + compact=1 (suite comparison leg) ==="
set_sw CT_COMPACT_PACKER 1
run_suite c1

if cmp -s bld/compact_manifest_c0.txt bld/compact_manifest_c1.txt; then
	say "SUITE MANIFEST C0 == C1: BYTE-IDENTICAL ($(grep -c . bld/compact_manifest_c0.txt) artefacts)"
else
	say "SUITE-MANIFEST ABWEICHUNG:"
	diff bld/compact_manifest_c0.txt bld/compact_manifest_c1.txt | head -20 | tee -a "$LOG"
fi

say "=== A: full-profile defaults + closing regression (historical path) ==="
full_profile
bash scripts/cli_ir_test.sh >> "$LOG" 2>&1 && say "[voll] 06 ir: PASS" || say "[voll] 06 ir: FAIL"
m1=$(md5sum "$xd/atb_off.bin" | cut -d' ' -f1); m2=$(md5sum "$xd/atb_on.bin" | cut -d' ' -f1)
say "[voll] 06 md5 OFF $([ "$m1" = "$REF_FULL_OFF" ] && echo IDENTISCH || echo "ABWEICHEND:$m1") / ON $([ "$m2" = "$REF_FULL_ON" ] && echo IDENTISCH || echo "ABWEICHEND:$m2")"
for t in rh rb jtc bp robust; do
	bash scripts/cli_${t}_test.sh >> "$LOG" 2>&1 && say "[voll] cli_${t}: PASS" || say "[voll] cli_${t}: FAIL"
done
say "=== FERTIG ==="
