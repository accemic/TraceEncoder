#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# CF-slim CSR twin read-back probe (CT_MICRO_CSR = 1).
#
# ct_pkg::CT_MICRO_CSR selects rtl/pkg/ct_cs_micro.sv -- a hand-written
# drop-in for the PeakRDL-generated register block, offered and documented as
# the Phase-O2 slim profile. Until the P8 closing audit NO build in this
# repository ever set it to 1, so the twin could drift for a whole campaign
# without a single red line, and it did: P8 widened
# trTeSyncStatus.SyncReqSource to three bits (SYNC_REQ_TE = 4), carried the
# generated block along and left the twin reading `s_cpuif_rd_data[1:0]`.
# Software in a slim build read the new source back as 0 -- "since reset
# nobody has asked for a sync" -- which is the only discovery D-P8-2 left the
# feature (audit finding A-N1).
#
# This is the behavioural half of that fix; the static half is
# scripts/check_micro_csr_twin.py (`make check-micro-csr`), which compares
# every read-back slice of the twin against the generated block.
#
# The build is a CF-only slim profile, because ct_cs_micro's own elaboration
# guard rejects anything richer. The flip happens on a COPY of rtl/pkg
# (bld/microcsr_profile/), never in the repository -- an in-tree `sed` plus
# `git checkout --` destroys a parallel worker's uncommitted edits in exactly
# those files (it did, 2026-08-05).
#
# `abc -sim` is not used: it dies on this host with "Spawn failed: Broken
# pipe" before it reaches the simulator, and the file list here is six files
# long, so xvlog/xelab/xsim are called directly -- the same way the other
# cli_*_test.sh legs drive their simulations.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado

tb=ct_cs_micro_tb
wd="bld/microcsr"
pdir="$wd/profile"

rm -rf "$wd"; mkdir -p "$pdir"
cp rtl/pkg/*.sv "$pdir/"
git diff --quiet -- rtl/pkg 2>/dev/null \
	|| echo "### [microcsr] note: rtl/pkg differs from HEAD -- the sandbox copies the WORKING TREE"

PKG="$pdir/ct_pkg.sv"
set_sw () { sed -i -E "s/(localparam bit ${1}[[:space:]]*=[[:space:]]*)[01];/\1${2};/" "$PKG"; }

# --- CF-only slim profile: exactly what ct_cs_micro's guard demands -------
set_sw CT_MICRO_CSR 1
set_sw CT_EN_DAQ 0
set_sw CT_EN_ACT 0
# CT_EN_WATCHPOINT_MSG requires CT_EN_ACT (composer guard, P4).
set_sw CT_EN_WATCHPOINT_MSG 0; set_sw CT_EN_AXIS_TS 0
set_sw CT_EN_DATA_TRACE 0
# CT_EN_DF_ADDR_COMPRESS / CT_EN_DF_DROP require CT_EN_DATA_TRACE (P3/P7).
set_sw CT_EN_DF_ADDR_COMPRESS 0
set_sw CT_EN_DF_DROP 0
set_sw CT_EN_FILTERS 0
# CT_EN_COMPRESSION is the derived OR of the per-feature suite switches, so
# it is turned off by turning THEM off (the profile_matrix.sh idiom).
for f in CT_EN_IMPLICIT_RETURN CT_EN_REPEATED_HISTORY CT_EN_WIDE_ICNT \
         CT_EN_REPEAT_BRANCH CT_EN_JTC CT_EN_BP CT_EN_IBHS CT_EN_REPEAT_INSTR; do
	set_sw "$f" 0
done
set_sw CT_EN_TRIG_REGS 0
# P8 closing audit: the twin does not decode the eTIP FIFO fill histogram
# either, and its own $fatal now says so.
set_sw CT_EN_FIFO_HIST 0

echo "### [microcsr] profile:"
grep -E "localparam bit (CT_MICRO_CSR|CT_EN_DAQ|CT_EN_ACT|CT_EN_DATA_TRACE|CT_EN_FILTERS|CT_EN_BP|CT_EN_JTC|CT_EN_TRIG_REGS|CT_EN_FIFO_HIST) " "$PKG" \
	| sed -E 's/^[[:space:]]*/    /'

# --- compile + elaborate + run -------------------------------------------
# xvlog/xelab are native Windows binaries under MSYS: the prj must carry
# native paths, not the POSIX ones this shell works with.
w () { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
: > "$wd/${tb}_vlog.prj"
for f in rtl/external/testtools/string_pkg.sv \
         rtl/external/testtools/file_pkg.sv \
         rtl/external/testtools/tt.sv \
         "$pdir/ct_cs_cpuif_pkg.sv" \
         "$pdir/ct_pkg.sv" \
         "$pdir/ct_cs_cpuif.sv" \
         "$pdir/ct_cs_micro.sv" \
         "rtl/pkg/test/${tb}.sv"; do
	echo "sv xil_defaultlib \"$(w "$here/$f")\"" >> "$wd/${tb}_vlog.prj"
done

cd "$wd"
rm -rf xsim.dir
xvlog --relax -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
	|| { echo "FAIL xvlog"; grep -i error xvlog.log | head; exit 4; }
xelab --relax --debug off "xil_defaultlib.${tb}" -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
	|| { echo "FAIL xelab"; grep -i error xelab.log | head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl
ct_xsim "xsim_${tb}.log" "${tb}_snap" -tclbatch _runall.tcl \
	|| { echo "FAIL: xsim leg unusable (reason above)"; exit 6; }

echo "======================================================"
grep -aE '^PROBE:|Testcase:|Info: Testbench|Error' "xsim_${tb}.log"
echo "======================================================"
if grep -aq 'Info: Testbench passed.' "xsim_${tb}.log"; then
	echo "OVERALL: PASS"
	exit 0
fi
echo "OVERALL: FAIL"
exit 1
