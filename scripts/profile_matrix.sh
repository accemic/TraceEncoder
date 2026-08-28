#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Profile matrix: simulation verification (full-profile md5, slim losslessness)
# plus an out-of-context synthesis per build profile.
#  - full profile: the test 06 md5 must stay identical
#  - ACT=0 with everything else on: must still produce a valid stream
#  - PT-only / minimal / featparity: simulation plus the final syntheses
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
LOG="bld/profile_matrix3.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

PKG="rtl/pkg/ct_pkg.sv"
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }
set_ts () { sed -i -E "s/(localparam int unsigned CT_TS_WIDTH = )[0-9]+;/\1${1};/" "$PKG"; }
profile () { # daq dt act filt suite sclk ts
	set_sw CT_EN_DAQ "$1"; set_sw CT_EN_DATA_TRACE "$2"; set_sw CT_EN_ACT "$3"; set_sw CT_EN_FILTERS "$4"; set_sw CT_EN_WATCHPOINT_MSG "$3"; set_sw CT_EN_AXIS_TS "$3"; set_sw CT_EN_DF_DROP "$2"; set_sw CT_EN_DF_ADDR_COMPRESS "$2"
	set_sw CT_EN_IMPLICIT_RETURN "$5"; set_sw CT_EN_REPEATED_HISTORY "$5"; set_sw CT_EN_WIDE_ICNT "$5"
	set_sw CT_EN_REPEAT_BRANCH "$5"; set_sw CT_EN_JTC "$5"; set_sw CT_EN_BP "$5"
	set_sw CT_SINGLE_CLOCK "$6"; set_ts "$7"
	"$PYRDL" scripts/gen_rdl_profile.py >> "$LOG" 2>&1 || { say "FATAL: gen_rdl_profile"; exit 9; }
}

tb=implicit_return_tb
xd="bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sim06_off () { # $1 = tag
	local tag="$1"
	( cd "$xd" && rm -rf xsim.dir \
	  && xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
	  && xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
	  && printf 'run -all\nquit\n' > _runall.tcl \
	  && ct_xsim "xsim_${tag}.log" "${tb}_snap" -tclbatch _runall.tcl ) \
	  || { say "$tag: FAIL (compile/sim)"; return 1; }
	cp "$xd/${tb}.atb.bin" "$xd/atb_${tag}.bin"
	"$NEXRV" -deco "$xd/atb_${tag}.bin" -pcinfo "$xd/${tb}.nexrv.info" -pcout "$xd/${tb}.${tag}.pcout" -full > "$xd/nexrv_${tag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "$xd/nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "$xd/${tag}.pcs"
	local n; n=$(grep -c . "$xd/${tag}.pcs")
	local m1 m2; m1=$(md5sum "$xd/atb_${tag}.bin" | cut -d' ' -f1); m2=$(md5sum "$xd/atb_off_phase1_baseline.bin" | cut -d' ' -f1)
	sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$xd/${tb}.expected.pcs" | tr 'A-F' 'a-f' > "$xd/exp.norm"
	sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$xd/${tag}.pcs" | tr 'A-F' 'a-f' > "$xd/${tag}.norm"
	head -n "$n" "$xd/exp.norm" > "$xd/exp.pfx"
	local sz; sz=$(stat -c%s "$xd/atb_${tag}.bin")
	local derr; derr=$(grep -c "max_delay" "$xd/xsim_${tag}.log" || true)
	if cmp -s "$xd/exp.pfx" "$xd/${tag}.norm" && [ "$n" -gt 400 ]; then
		say "$tag: prefix($n) PASS; atb ${sz}B; delay-errors=$derr; md5 $([ "$m1" = "$m2" ] && echo IDENTISCH || echo "abweichend ($m1)")"
	else say "$tag: FAIL (prefix/$n)"; fi
}
synth_one () { # $1 = name
	rm -rf bld/synth_ooc .Xil 2>/dev/null
	say "synth $1 gestartet"
	cmd //c "C:\\Xilinx\\Vivado\\2025.1\\bin\\vivado.bat -mode batch -source scripts/synth_encoder_ooc.tcl -tclargs xck26-sfvc784-2LV-c" > "bld/synth_pass2_${1}.log" 2>&1
	if ! [ -f bld/synth_ooc/util_flat.rpt ]; then
		say "synth $1: Retry"
		cmd //c "C:\\Xilinx\\Vivado\\2025.1\\bin\\vivado.bat -mode batch -source scripts/synth_encoder_ooc.tcl -tclargs xck26-sfvc784-2LV-c" > "bld/synth_pass2_${1}.log" 2>&1
	fi
	mkdir -p "bld/synth_ooc_pass2_${1}"
	cp bld/synth_ooc/util_flat.rpt bld/synth_ooc/util_hier.rpt "bld/synth_ooc_pass2_${1}/" 2>/dev/null \
	  || { say "synth $1: FAIL"; return 1; }
	local l f b
	l=$(grep -m1 "CLB LUTs" "bld/synth_ooc_pass2_${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	f=$(grep -m1 "CLB Registers" "bld/synth_ooc_pass2_${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	b=$(grep -m1 "Block RAM Tile" "bld/synth_ooc_pass2_${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	say "synth $1: LUTs=$l FFs=$f BRAM=$b"
}

say "=== full-profile counter-check (the delay fix must change nothing) ==="
profile 1 1 1 1 1 0 64
bash scripts/cli_ir_test.sh >> "$LOG" 2>&1 && say "voll 06: PASS" || say "voll 06: FAIL"
m1=$(md5sum "$xd/atb_off.bin" | cut -d' ' -f1); m2=$(md5sum "$xd/atb_off_phase1_baseline.bin" | cut -d' ' -f1)
m3=$(md5sum "$xd/atb_on.bin" | cut -d' ' -f1);  m4=$(md5sum "$xd/atb_on_phase1_baseline.bin" | cut -d' ' -f1)
say "voll OFF-md5 $([ "$m1" = "$m2" ] && echo IDENTISCH || echo ABWEICHEND) / ON-md5 $([ "$m3" = "$m4" ] && echo IDENTISCH || echo ABWEICHEND)"

say "=== R3 combination retest (ACT=0, rest on): a valid stream is expected now ==="
profile 1 1 0 1 1 0 64
sim06_off r3fix

say "=== PT-only final ==="
profile 0 0 0 0 1 0 64
sim06_off ptfix
synth_one ptonly

say "=== Minimal final (SINGLE_CLOCK) ==="
profile 0 0 0 0 0 1 64
sim06_off minfix
synth_one minimal

say "=== feature-parity final (TS32) ==="
profile 0 0 0 0 0 1 32
sim06_off featparityfix
synth_one featparity

say "=== Defaults wiederherstellen ==="
profile 1 1 1 1 1 0 64
bash scripts/cli_ir_test.sh >> "$LOG" 2>&1 && say "Abschluss voll 06: PASS" || say "Abschluss voll 06: FAIL"
m1=$(md5sum "$xd/atb_off.bin" | cut -d' ' -f1)
say "Abschluss OFF-md5: $([ "$m1" = "$m2" ] && echo IDENTISCH || echo ABWEICHEND)"
say "=== FERTIG ==="
