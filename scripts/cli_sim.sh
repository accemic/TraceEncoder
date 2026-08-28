#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Local Windows workaround runner: abc's Vivado project-mode launch_simulation
# fails to spawn compile.bat under the Bash tool ("Spawn failed: Broken pipe").
# abc still generates the xsim .prj before that failure, so we drive xvlog +
# xelab + xsim on the command line (which works), then run decode_and_check.sh.
# NOT for commit — a local bring-up aid only.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_abc


# name -> tests subdir
declare -A DIR=(
  [basic]=instruction/01_basic
  [interrupts]=instruction/02_interrupts
  [stress]=instruction/03_stress
  [periodic_sync]=instruction/04_periodic_sync
  [exceptions]=instruction/05_exceptions
  [data_basic]=data/01_basic
  [data_split]=data/02_split_load
  [addr_compress]=data/03_addr_compress
  [data_sync]=data/04_data_sync
  [df_workload]=data/05_df_workload
  [df_workload_full]=data/05_df_workload
  [overrun_recovery]=overflow/01_overrun_recovery
  [hsi_csr_cap]=hsi/01_csr_cap
  [combined]=combined/01_all
  [sync_quota_bytes]=instruction/29_sync_quota_bytes
  [sync_quota_msgs]=instruction/30_sync_quota_msgs
)
declare -A TB=(
  [basic]=basic_tb [interrupts]=interrupts_tb [stress]=stress_tb
  [periodic_sync]=periodic_sync_tb [exceptions]=exceptions_tb
  [data_basic]=data_basic_tb [data_split]=split_load_tb
  [addr_compress]=addr_compress_tb [data_sync]=data_sync_tb
  [df_workload]=df_workload_tb [df_workload_full]=df_workload_full_tb
  [overrun_recovery]=overrun_recovery_tb
  [hsi_csr_cap]=csr_cap_tb [combined]=combined_tb
  [sync_quota_bytes]=sync_quota_bytes_tb [sync_quota_msgs]=sync_quota_msgs_tb
)

name="$1"; shift || true
checks="${*:-}"
sub="${DIR[$name]}"; tb="${TB[$name]}"
[ -z "$sub" ] && { echo "unknown test: $name"; exit 2; }

# make-target uses hyphens
mt="${name//_/-}"
# Project generation lives in ct_need_prj (scripts/ct_env.sh) since the same
# bootstrap was needed by nineteen other gates. It keeps everything this
# script used to do inline -- the faked git toplevel (`git rev-parse
# --show-toplevel` resolves to the SUPER repository when CTTE is vendored,
# which breaks every @DIR import), the "generate only when the .prj is
# missing" rule (the xvlog step below recompiles all sources anyway, so a
# stale .prj only matters when the FILE LIST changed; CT_PRJ_REFRESH=1
# forces it), and the fact that the abc run always ends in a Vivado spawn
# error whose exit code says nothing.
xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
ct_need_prj "$tb" "tests/${sub}/${tb}.abc" || exit $?
prj="$xd/${tb}_vlog.prj"

cd "$xd"
echo "### [$name] xvlog"
xvlog --incr --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1
rc=$?; [ $rc -ne 0 ] && { echo "### [$name] FAIL xvlog rc=$rc"; grep -iE 'error' xvlog.log | head; exit 4; }
echo "### [$name] xelab"
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1
rc=$?; [ $rc -ne 0 ] && { echo "### [$name] FAIL xelab rc=$rc"; grep -iE 'error' xelab.log | head; exit 5; }
echo "### [$name] xsim"
printf 'run -all\nquit\n' > _runall.tcl
ct_xsim xsim.log "${tb}_snap" -tclbatch _runall.tcl || exit 6
# decode_and_check --overflow greps the tee'd sim log (Makefile contract);
# mirror the xsim log under that name so the check works in this runner too.
cp -f xsim.log "${tb}.sim.log" 2>/dev/null || true
ls -la "${tb}.atb.bin" 2>/dev/null | sed 's/^/### atb: /' || echo "### [$name] no atb.bin"

cd "$here"
if [ -n "$checks" ]; then
  echo "### [$name] decode_and_check $checks"
  scripts/decode_and_check.sh $checks "$tb"
fi
