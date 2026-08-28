#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# E-Trace E2E cross-validation (ET3 gate):
#   CT_EN_ETRACE=1 CF-only build of basic_tb (donor-clone project, abc-free)
#   -> XSIM -> ATB byte stream (= reference-raw te_inst stream)
#   -> vendored reference decoder (tools/etrace/etrace_decode.py) with a
#      synthetic listing from the cpu_model PCInfo (pcinfo2listing.py)
#   -> PC sequence prefix-compared against the cpu_model oracle
#      (basic_tb.expected.pcs).
# The same stimulus decoded via NexRv in the N-Trace build (cli_sim.sh basic)
# is the A==B==C sibling; this script checks the E-Trace leg (C).
#
# Scenarios: basic | interrupts | stress | exceptions | ir | f1ntrap |
# resync | resyncir | jtc | bp | df | daq | mixed. The `mixed` leg is the odd one out
# -- it decodes nothing and instead proves the P9 property that the
# protocol is a per-instance synthesis parameter (two differently
# parameterised encoders in one netlist, discovery per instance).
#
# The profile flip happens on a COPY of rtl/pkg + rdl (bld/etrace_<leg>_profile/),
# never in the repository: an in-tree `sed` plus `git checkout --` restore
# destroys a parallel worker's uncommitted edits in exactly those files (it
# did, 2026-08-05). The copy is taken from the WORKING TREE, so uncommitted
# RTL under test still gets tested; only the flip stays out of the repo.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_abc

name="${1:-basic}"
# The PeakRDL venv is gitignored; a fresh worktree has none. Fall back to the
# main checkout's (read only) -- same rule as cli_simsoak_build.sh.
PYRDL="${CT_PYRDL:-}"
if [ -z "$PYRDL" ]; then
	# A linked worktree has no venv of its own; fall back to the main
	# checkout it was created from -- resolved, not hardcoded.
	main_root="$(cd "$(dirname "$(git -C "$here" rev-parse --git-common-dir)")" && pwd)"
	for cand in "$here/.venv-rdl-win/Scripts/python.exe" \
	            "$here/.venv-rdl/bin/python" \
	            "$main_root/.venv-rdl-win/Scripts/python.exe" \
	            "$main_root/.venv-rdl/bin/python"; do
		[ -x "$cand" ] && { PYRDL="$cand"; break; }
	done
fi
[ -n "$PYRDL" ] || { echo "### [etrace] FATAL: no PeakRDL venv (set CT_PYRDL)"; exit 9; }

# --- 0. profile sandbox: rtl/pkg + rdl copy, flipped instead of the repo --
pdir="bld/etrace_${name}_profile"
rm -rf "$pdir"; mkdir -p "$pdir/pkg" "$pdir/rdl"
cp rtl/pkg/*.sv "$pdir/pkg/"
cp rdl/*.rdl    "$pdir/rdl/"
git diff --quiet -- rtl/pkg rdl 2>/dev/null \
	|| echo "### [etrace] note: rtl/pkg or rdl differ from HEAD -- the sandbox copies the WORKING TREE"

PKG="$pdir/pkg/ct_pkg.sv"
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }

# --- 1. CF-only E-Trace profile ---------------------------------------
set_sw CT_EN_ETRACE 1
set_sw CT_EN_NTRACE 0
set_sw CT_EN_DAQ 0
set_sw CT_EN_DATA_TRACE 0; set_sw CT_EN_DF_DROP 0
# CT_EN_DF_ADDR_COMPRESS must follow CT_EN_DATA_TRACE: the P3 formatter
# guard ($fatal "CT_EN_DF_ADDR_COMPRESS requires CT_EN_DATA_TRACE",
# ct_L2_nexus_formatter.sv) aborts elaboration otherwise. Invisible while
# every leg here was E-Trace-only (no Nexus formatter in the netlist); the
# `mixed` leg instantiates an N-Trace encoder too and trips it.
set_sw CT_EN_DF_ADDR_COMPRESS 0
set_sw CT_EN_ACT 0
# Same class of dependency (P4): CT_EN_WATCHPOINT_MSG must follow
# CT_EN_ACT (composer guard) -- WPHIT comes from the ACT-ST command path.
set_sw CT_EN_WATCHPOINT_MSG 0; set_sw CT_EN_AXIS_TS 0
if [ "${1:-basic}" = "df" ]; then
	set_sw CT_EN_DATA_TRACE 1   # te_data emission
	set_sw CT_EN_DF_DROP 1
	set_sw CT_EN_DF_ADDR_COMPRESS 1
fi
if [ "${1:-basic}" = "daq" ]; then
	set_sw CT_EN_DAQ 1          # vendor DAQ packets (ACT-CAP path)
	set_sw CT_EN_ACT 1
	set_sw CT_EN_WATCHPOINT_MSG 1; set_sw CT_EN_AXIS_TS 1
fi
"$PYRDL" scripts/gen_rdl_profile.py --pkg "$PKG" --rdl-dir "$pdir/rdl" --out-dir "$pdir/pkg" \
	>/dev/null 2>&1 || { echo "### [etrace] FATAL: gen_rdl_profile"; exit 9; }

# --- 2. donor-clone project (abc-free), + E-Trace rtl in the prj -------
# optional $1 selects the scenario (default basic): basic | exceptions |
# interrupts | stress
case "$name" in
	basic)      tb=basic_tb;      sub=01_basic ;;
	interrupts) tb=interrupts_tb; sub=02_interrupts ;;
	stress)     tb=stress_tb;     sub=03_stress ;;
	exceptions) tb=exceptions_tb; sub=05_exceptions ;;
	ir)         tb=etrace_ir_tb;      sub=21_etrace_ir ;;
	f1ntrap)    tb=etrace_f1n_trap_tb; sub=22_etrace_f1n_trap ;;
	resync)     tb=etrace_resync_tb;   sub=23_etrace_resync ;;
	resyncir)   tb=etrace_resync_ir_tb; sub=34_etrace_resync_ir ;;
	mixed)      tb=protocol_param_tb;  sub=24_protocol_param ;;
	jtc)        tb=etrace_jtc_tb;      sub=25_etrace_jtc ;;
	bp)         tb=etrace_bp_tb;       sub=26_etrace_bp ;;
	df)         tb=etrace_df_tb;       sub=27_etrace_df ;;
	daq)        tb=etrace_daq_tb;      sub=28_etrace_daq ;;
	*) echo "### [etrace] unknown scenario '$name'"; exit 2 ;;
esac
plus="${plus:-}"
ct_need_prj implicit_return_tb || exit $?
donor=bld/implicit_return_tb.abc.vivado/implicit_return_tb.abc.sim/sim_1/behav/xsim
xd="bld/etrace_${name}"
rm -rf "$xd"; mkdir -p "$xd"
cp "$donor/glbl.v" "$xd/"
cp "$donor"/*.ini "$xd/" 2>/dev/null || true
printf 'run -all\nquit\n' > "$xd/_runall.tcl"
# ... and the package sources are taken from the profile sandbox, not from
# rtl/pkg -- that is what keeps the flip out of the repository.
sed -e "s#tests/instruction/06_implicit_return/implicit_return_tb.sv#tests/instruction/${sub}/${tb}.sv#" \
	-e 's#\.\./\.\./\.\./\.\./\.\./\.\./#../../#g' \
	-e "s#\.\./\.\./rtl/pkg/#../../${pdir}/pkg/#g" \
	"$donor/implicit_return_tb_vlog.prj" > "$xd/${tb}_vlog.prj"
awk '{print; if ($0 ~ /ct_L2_msg_gen\.sv/) { print "\"../../rtl/ct_L2_te_inst_gen.sv\" \\"; print "\"../../rtl/ct_L2_te_packetizer.sv\" \\" }}' \
	"$xd/${tb}_vlog.prj" > "$xd/tmp.prj" && mv "$xd/tmp.prj" "$xd/${tb}_vlog.prj"

# --- 3. compile / elaborate ---------------------------------------------
( cd "$xd"   && xvlog --incr --relax -L uvm -prj "${tb}_vlog.prj" > xvlog.log 2>&1   && xelab --relax --debug off -L uvm xil_defaultlib.${tb} xil_defaultlib.glbl -s "${tb}_snap" > xelab.log 2>&1 )
rc=$?
if [ $rc -ne 0 ]; then
	echo "### [etrace] FAIL: build failed (rc=$rc; see $xd/{xvlog,xelab}.log)"
	exit 3
fi

# --- 4. simulate + reference decode + oracle compare ---------------------
norm () { sed -e 's/^0x//' -e 's/^0*//' -e 's/^$/0/' "$1" | tr 'A-F' 'a-f'; }

run_and_check () { # $1 = tag, remaining args = extra xsim plusargs
	local tag="$1"; shift
	( cd "$xd" && rm -f "${tb}.atb.bin" \
	  && ct_xsim "xsim_${tag}.log" "${tb}_snap" -tclbatch _runall.tcl $plus "$@" ) || {
		echo "### [etrace] FAIL($tag): xsim did not complete (see $xd/xsim_${tag}.log)"
		exit 3
	}
	if [ ! -f "$xd/${tb}.atb.bin" ]; then
		echo "### [etrace] FAIL($tag): sim did not produce ${tb}.atb.bin (see $xd/xsim_${tag}.log)"
		exit 3
	fi
	cp "$xd/${tb}.atb.bin" "$xd/atb_${tag}.bin"
	python tools/etrace/pcinfo2listing.py "$xd/${tb}.nexrv.info" "$xd/${tb}.objdump" || exit 4
	python tools/etrace/etrace_decode.py -i "$xd/atb_${tag}.bin" -l "$xd/${tb}.objdump" -o "$xd/${tb}.${tag}.pctrace" || exit 4

	norm "$xd/${tb}.expected.pcs"   > "$xd/exp.norm"
	norm "$xd/${tb}.${tag}.pctrace" > "$xd/got.norm"
	local n_exp n_got n_cmp
	n_exp=$(wc -l < "$xd/exp.norm"); n_got=$(wc -l < "$xd/got.norm")
	n_cmp=$(( n_exp < n_got ? n_exp : n_got ))
	head -n "$n_cmp" "$xd/exp.norm" > "$xd/exp.pfx"
	head -n "$n_cmp" "$xd/got.norm" > "$xd/got.pfx"
	if cmp -s "$xd/exp.pfx" "$xd/got.pfx" && [ "$n_cmp" -ge 20 ]; then
		echo "### [etrace] PASS($tag) — $n_cmp/$n_exp oracle PCs ($(stat -c%s "$xd/atb_${tag}.bin") stream bytes)"
	else
		echo "### [etrace] FAIL($tag) — prefix mismatch (expected $n_exp, decoded $n_got, compared $n_cmp)"
		diff "$xd/exp.pfx" "$xd/got.pfx" | head -10
		exit 5
	fi
}

if [ "$name" = "resyncir" ]; then
	# P10 S-1/S-2 regression guard: the resync x implicit-return braid must
	# be PC-lossless with IR off AND on, and the stream must really contain
	# mid-trace F3.0 anchors (otherwise the braid was not crossed and the
	# guard proves nothing).
	run_and_check off
	run_and_check on -testplusarg IMPLICIT_RETURN
	n_f30=$(python tools/etrace/dump_te.py "$xd/atb_on.bin" | grep -c "f30" || true)
	if [ "$n_f30" -ge 3 ]; then
		echo "### [etrace] PASS — resync x IR braid lossless, $n_f30 F3.0 anchors in the ON stream"
		exit 0
	else
		echo "### [etrace] FAIL — resyncir: only $n_f30 F3.0 anchors (braid not crossed)"
		exit 6
	fi
elif [ "$name" = "ir" ]; then
	# OFF/ON compression gate from one build: both PC-lossless, ON smaller.
	run_and_check off
	run_and_check on -testplusarg IMPLICIT_RETURN
	b_off=$(stat -c%s "$xd/atb_off.bin"); b_on=$(stat -c%s "$xd/atb_on.bin")
	if [ "$b_on" -lt "$b_off" ]; then
		echo "### [etrace] PASS — implicit-return: $b_off B -> $b_on B, both lossless"
		exit 0
	else
		echo "### [etrace] FAIL — implicit-return stream not smaller ($b_off B -> $b_on B)"
		exit 6
	fi
elif [ "$name" = "mixed" ]; then
	# Protocol as a per-INSTANCE synthesis parameter (P9): ONE netlist, two
	# ct_encoder instances with different back ends. Nothing is decoded here
	# -- the datapaths are covered by the protocol-specific legs; this leg
	# proves that the mixed elaboration works and that each instance reports
	# ITS OWN protocol (atb_te_raw + the hardware-driven discovery registers).
	( cd "$xd" && ct_xsim xsim_mixed.log "${tb}_snap" -tclbatch _runall.tcl ) || {
		echo "### [etrace] FAIL(mixed): xsim did not complete (see $xd/xsim_mixed.log)"
		exit 3
	}
	if grep -q "\[protocol_param_tb\] PASS" "$xd/xsim_mixed.log"; then
		grep "\[protocol_param_tb\]" "$xd/xsim_mixed.log" | sed 's/^/### [etrace] /'
		echo "### [etrace] PASS — mixed build: N-Trace and E-Trace encoder side by side, discovery per instance"
		exit 0
	else
		echo "### [etrace] FAIL(mixed) — see $xd/xsim_mixed.log"
		grep -E "\[protocol_param_tb\]|ERROR|FATAL" "$xd/xsim_mixed.log" | head -20
		exit 5
	fi
elif [ "$name" = "bp" ]; then
	run_and_check off
	run_and_check on -testplusarg BP
	b_off=$(stat -c%s "$xd/atb_off.bin"); b_on=$(stat -c%s "$xd/atb_on.bin")
	n_f00=$(python tools/etrace/dump_te.py "$xd/atb_on.bin" | grep -c "f00" || true)
	if [ "$b_on" -lt "$b_off" ] && [ "$n_f00" -ge 1 ]; then
		echo "### [etrace] PASS — branch-prediction: $b_off B -> $b_on B, $n_f00 F0.0 packets, both lossless"
		exit 0
	else
		echo "### [etrace] FAIL — bp gate: $b_off B -> $b_on B, $n_f00 F0.0 packets"
		exit 6
	fi
elif [ "$name" = "jtc" ]; then
	run_and_check off
	run_and_check on -testplusarg JTC
	b_off=$(stat -c%s "$xd/atb_off.bin"); b_on=$(stat -c%s "$xd/atb_on.bin")
	n_f01=$(python tools/etrace/dump_te.py "$xd/atb_on.bin" | grep -c "f01" || true)
	if [ "$b_on" -lt "$b_off" ] && [ "$n_f01" -ge 2 ]; then
		echo "### [etrace] PASS — jump-target-cache: $b_off B -> $b_on B, $n_f01 F0.1 packets, both lossless"
		exit 0
	else
		echo "### [etrace] FAIL — jtc gate: $b_off B -> $b_on B, $n_f01 F0.1 packets"
		exit 6
	fi
elif [ "$name" = "df" ]; then
	run_and_check run
	python tools/etrace/etrace_data_check.py "$xd/atb_run.bin" 		--df "$xd/${tb}.expected.df" || { echo "### [etrace] FAIL — df record check"; exit 6; }
	echo "### [etrace] PASS — data-trace: te_data records match, PC trace lossless"
	exit 0
elif [ "$name" = "daq" ]; then
	run_and_check run
	python tools/etrace/etrace_data_check.py "$xd/atb_run.bin" 		--daq "$xd/${tb}.expected.daq" || { echo "### [etrace] FAIL — daq record check"; exit 6; }
	echo "### [etrace] PASS — DAQ: vendor records match, PC trace lossless"
	exit 0
elif [ "$name" = "resync" ]; then
	run_and_check run
	# mid-trace anchors: total F3.0 count minus the initial one must be >= 2
	n_f30=$(python tools/etrace/dump_te.py "$xd/atb_run.bin" | grep -c "f30" || true)
	if [ "$n_f30" -ge 3 ]; then
		echo "### [etrace] PASS — resync: $n_f30 F3.0 anchors (>= 1 initial + 2 mid-trace)"
		exit 0
	else
		echo "### [etrace] FAIL — resync: only $n_f30 F3.0 anchors in the stream"
		exit 7
	fi
else
	run_and_check run
	exit 0
fi
