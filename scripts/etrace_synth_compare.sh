#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# ET5: OOC resource comparison N-Trace backend vs E-Trace backend on an
# otherwise IDENTICAL CF-only profile (DAQ/DATA/ACT/FILTERS + msg_gen feature
# set off, dual clock, TS default). Reports land in
# bld/synth_ooc_etrace_cmp/{ntrace,etrace}/.
#
# Hardened 2026-07-24 against this workstation's flaky Vivado 2022.1 launch
# (helper child intermittently fails reading EXISTING install/.Xil tcl files;
# roughly one success in six attempts, also from a native shell):
#   - runs Vivado from a scratch CWD (fresh .Xil; a stale-locked .Xil in the
#     repo root wedged consecutive runs) -- synth_encoder_ooc.tcl is
#     script-relative since the same date
#   - strips SHELL/MSYSTEM from the environment
#   - prefers Vivado 2026.1 when installed (different rt-engine code)
#   - retries up to 5x per side
# Requires a committed rtl/pkg tree (restores via git checkout).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

# Vivado: whatever is already on PATH wins, otherwise the usual install
# roots on both platforms. CT_VIVADO_BIN / XILINX_VIVADO override both --
# no single machine's layout is assumed. Same order as scripts/ct_env.sh.
if ! command -v vivado >/dev/null 2>&1; then
	cands="${CT_VIVADO_BIN:-} ${XILINX_VIVADO:+$XILINX_VIVADO/bin}"
	cands="$cands /c/Xilinx/*/Vivado/bin /c/Xilinx/Vivado/*/bin"
	cands="$cands /opt/Xilinx/*/Vivado/bin /opt/Xilinx/Vivado/*/bin"
	cands="$cands /tools/Xilinx/*/Vivado/bin /tools/Xilinx/Vivado/*/bin"
	for cand in $cands; do          # deliberately unquoted: glob + split
		[ -x "$cand/vivado" ] || [ -f "$cand/vivado.bat" ] || continue
		export PATH="$cand:$PATH"
		echo "### vivado: $cand"
		break
	done
fi

PKG="rtl/pkg/ct_pkg.sv"
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }

restore () { git checkout -- "$PKG" rtl/pkg/ct_cs_cpuif.sv rtl/pkg/ct_cs_cpuif_pkg.sv rdl/ct_profile.inc.rdl 2>/dev/null; }
trap restore EXIT

base_profile () { # $1 = CT_EN_ETRACE value
	set_sw CT_EN_ETRACE "$1"
	# CT_EN_DF_DROP rides with CT_EN_DATA_TRACE (composer guard "CT_EN_DF_DROP
	# requires CT_EN_DATA_TRACE" -- there is no data trace to drop).
	for sw in CT_EN_DAQ CT_EN_DATA_TRACE CT_EN_DF_DROP CT_EN_ACT CT_EN_FILTERS \
	          CT_EN_IMPLICIT_RETURN CT_EN_REPEATED_HISTORY CT_EN_WIDE_ICNT \
	          CT_EN_REPEAT_BRANCH CT_EN_JTC CT_EN_BP CT_EN_IBHS CT_EN_BTM; do
		set_sw "$sw" 0
	done
	"$PYRDL" scripts/gen_rdl_profile.py >/dev/null || { echo "FATAL gen_rdl_profile"; exit 9; }
}

run_one () { # $1 = tag
	local work="${TMPDIR:-/tmp}/ctte_synthwork_$1"
	local ok=0
	mkdir -p "$work"
	for i in 1 2 3 4 5; do
		rm -rf "$work/.Xil" bld/synth_ooc
		( cd "$work" && env -u SHELL -u MSYSTEM -u MSYSTEM_CARCH -u MSYSTEM_CHOST -u MSYSTEM_PREFIX \
			vivado -mode batch -source "$here/scripts/synth_encoder_ooc.tcl" \
			> "$here/bld/synth_etrace_cmp_${1}.log" 2>&1 )
		if [ -f bld/synth_ooc/util_flat.rpt ]; then ok=1; break; fi
		echo "### [${1}] try $i failed: $(grep -m1 "couldn't read" "bld/synth_etrace_cmp_${1}.log" || echo 'see log')"
	done
	[ $ok -eq 1 ] || { echo "FATAL: no reports for ${1} (see bld/synth_etrace_cmp_${1}.log)"; exit 8; }
	mkdir -p "bld/synth_ooc_etrace_cmp/${1}"
	cp bld/synth_ooc/util_flat.rpt bld/synth_ooc/util_hier.rpt "bld/synth_ooc_etrace_cmp/${1}/"
	l=$(grep -m1 "CLB LUTs" "bld/synth_ooc_etrace_cmp/${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	f=$(grep -m1 "CLB Registers" "bld/synth_ooc_etrace_cmp/${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	b=$(grep -m1 "Block RAM Tile" "bld/synth_ooc_etrace_cmp/${1}/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	echo "### [${1}] LUT=${l} FF=${f} BRAM=${b}"
}

# ntrace side is skippable when its reports already exist (SKIP_NTRACE=1)
if [ "${SKIP_NTRACE:-0}" != "1" ]; then
	base_profile 0
	run_one ntrace
fi
base_profile 1
run_one etrace
echo "### synth compare done -> bld/synth_ooc_etrace_cmp/"
