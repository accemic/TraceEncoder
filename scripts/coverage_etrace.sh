#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# E-Trace-profile Verilator line coverage (companion to coverage_suite.sh,
# AW directive 2026-07-25: measure the NEW CTTE version, E-Trace +
# N-Trace). The default-profile suite never compiles the E-Trace backend
# (CT_EN_ETRACE=0 -> genEtrace and ct_L2_te_inst_gen/_packetizer are
# generated out). This script:
#
#   1. flips ct_pkg to the FAT E-Trace profile (CT_EN_ETRACE=1,
#      CT_EN_NTRACE=0, DATA_TRACE/DAQ/ACT stay 1 -> all te_inst_gen arms
#      incl. te_data + vendor-DAQ live, PKT_MAX=208) + RDL regen,
#   2. abc-builds + runs the E-Trace TBs plus the four generic stimulus
#      TBs under this profile, feature ON-legs via a second run of the
#      already-built executable (distinct +verilator+coverage+file names,
#      pattern of coverage_on_legs.sh),
#   3. restores ct_pkg/RDL (trap).
#
# P9 (2026-08-04) removed the former third step, a DUAL profile run for
# genDual and the runtime protocol mux: the protocol is a synthesis
# parameter now, genDual is gone and etrace_dual_tb is retired. The mixed
# instantiation that replaced it (protocol_param_tb) runs in profile E.
# Note for the suite-wide rate: both numerator and denominator shrink --
# the ~135 genDual lines leave the product RTL, so the published
# 2026-07-25 figure is not comparable line-for-line.
#
# Run AFTER coverage_suite.sh (a rebuild replaces the per-test default
# .dat only if the run omits the explicit file plusarg -- every run here
# names its .dat *_e, so the default-profile dats survive in the
# same .vsim dirs). scripts/coverage_report.sh then merges everything.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
ct_need_abc
# MSYS2's Verilator needs a native Windows VERILATOR_ROOT (see the Windows
# notes in coverage_suite.sh); on Linux the binary's built-in default applies.
if [ "${OS:-}" = "Windows_NT" ]; then
	export VERILATOR_ROOT="${VERILATOR_ROOT:-C:/msys64/ucrt64/share/verilator}"
fi
LOG="bld/coverage_etrace.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

PKG="rtl/pkg/ct_pkg.sv"
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }
restore () {
	git checkout -- "$PKG" rtl/pkg/ct_cs_cpuif.sv rtl/pkg/ct_cs_cpuif_pkg.sv rdl/ct_profile.inc.rdl 2>/dev/null
}
trap restore EXIT

# task path + tb name + list of "<legname>:<plusargs>" (off = no plusargs)
run_tb () { # $1 = task rel path, $2 = tb, $3.. = legs
	local task="$1" tb="$2"; shift 2
	if [ ! -s "bld/cov_e_${tb}.log" ] || ! grep -q "Total coverage" "bld/cov_e_${tb}.log"; then
		( cd bld && ABC_VERILATOR_EXTRA_ARGS="" timeout 900 \
			abc --sim-backend verilator --coverage -sim "../$task" ) \
			> "bld/cov_e_${tb}.log" 2>&1
		local rc=$?
		# rename the build-run .dat to a profile-specific name so the
		# default-profile dat of the same TB is not shadowed/mixed up
		if [ -f "bld/${tb}.vsim/coverage_${tb}.dat" ]; then
			mv "bld/${tb}.vsim/coverage_${tb}.dat" "bld/${tb}.vsim/coverage_${tb}_${PROFILE}.dat"
		fi
		if [ $rc -ne 0 ]; then
			say "cov[$PROFILE] $tb: FAIL (rc=$rc)"; tail -3 "bld/cov_e_${tb}.log" | sed 's/^/    /' | tee -a "$LOG"
			fails=$((fails+1)); return
		fi
		say "cov[$PROFILE] $tb: build+off OK"
	else
		say "cov[$PROFILE] $tb: SKIP build (already run)"
	fi
	local exe="bld/${tb}.vsim/obj_${tb}/${tb}.exe"
	for legspec in "$@"; do
		local leg="${legspec%%:*}" args="${legspec#*:}"
		[ "$args" = "$legspec" ] && args=""
		local dat="coverage_${tb}_${PROFILE}_${leg}.dat"
		( cd "bld/${tb}.vsim" && timeout 600 "./obj_${tb}/${tb}.exe" $args \
			"+verilator+coverage+file+${dat}" ) > "bld/cov_e_${tb}_${leg}.log" 2>&1 \
			&& say "cov[$PROFILE] $tb/$leg: OK" \
			|| { say "cov[$PROFILE] $tb/$leg: FAIL"; fails=$((fails+1)); }
	done
}

fails=0

# --- profile 1: fat E-Trace (everything on except N-Trace) --------------
PROFILE=e
say "=== Profil E: CT_EN_ETRACE=1 CT_EN_NTRACE=0 (DF/DAQ/ACT an) ==="
set_sw CT_EN_ETRACE 1
set_sw CT_EN_NTRACE 0
"$PYRDL" scripts/gen_rdl_profile.py >/dev/null 2>&1 || { say "FATAL: gen_rdl_profile"; exit 9; }

run_tb tests/instruction/01_basic/basic_tb.abc            basic_tb
run_tb tests/instruction/02_interrupts/interrupts_tb.abc  interrupts_tb
run_tb tests/instruction/03_stress/stress_tb.abc          stress_tb
run_tb tests/instruction/05_exceptions/exceptions_tb.abc  exceptions_tb
run_tb tests/instruction/21_etrace_ir/etrace_ir_tb.abc           etrace_ir_tb       "on:+IR"
run_tb tests/overflow/02_natural_overflow/natural_ovf_tb.abc     natural_ovf_tb
run_tb tests/instruction/22_etrace_f1n_trap/etrace_f1n_trap_tb.abc etrace_f1n_trap_tb "th0:+TH0"
run_tb tests/instruction/23_etrace_resync/etrace_resync_tb.abc   etrace_resync_tb   "anchorjump:+ANCHORJUMP"
run_tb tests/instruction/25_etrace_jtc/etrace_jtc_tb.abc         etrace_jtc_tb      "on:+JTC" "jtcx:+JTC +JTCX"
run_tb tests/instruction/26_etrace_bp/etrace_bp_tb.abc           etrace_bp_tb       "on:+BP" "bpx:+BP +JTC +BPX"
run_tb tests/instruction/27_etrace_df/etrace_df_tb.abc           etrace_df_tb
run_tb tests/instruction/28_etrace_daq/etrace_daq_tb.abc         etrace_daq_tb
# Mixed instantiation (P9): one N-Trace + one E-Trace encoder side by side.
run_tb tests/instruction/24_protocol_param/protocol_param_tb.abc protocol_param_tb

say "=== FERTIG ($fails Fails) — merge via scripts/coverage_report.sh ==="
exit $fails
