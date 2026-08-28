#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Gate for tests/instruction/19_feature_matrix -- the feature and filter
# matrix.
#
# WHY THIS SCRIPT EXISTS. The testbench had NO runner (D1-F6, 2026-08-09):
# no cli_*_test.sh, no entry in ci/, no Makefile target named it. It is the
# same silent failure this repository already wrote down once, in
# scripts/cli_preprocsync_test.sh: "A testbench that nothing starts is a
# silent failure -- it cannot go red." It sweeps ten configuration phases
# over comparators, filters, perfcnt, timestamps, the SRC field, both
# external sync sources and the ACT station, and one of those phases (Ph.9)
# is a half-word cadence leg (trTeControl.InstSyncMode = 3). Had it been
# running, it would have shown the half-word counter defect B-R13-1 that D1
# found by reading the RTL.
#
# WHY IT IS A cli GATE AND NOT A `make sim` ENTRY. The abc header carries no
# backend note, but the workload takes ~100 k CPU cycles of configuration
# churn and the verdict below needs the XSIM decode path; the cli gates are
# where an XSIM-driven testbench lives in this repository (same reasoning as
# cli_preprocsync_test.sh). scripts/run_gates.sh picks it up by name.
#
# VERDICT -- four independent claims, because a runner that starts a
# testbench which asserts nothing is not an improvement:
#
#   1. the testbench's own verdict marker, AND no $error / no TIMEOUT.
#      xsim exits 0 even after $fatal, so the log is the only truth here.
#   2. every one of the sixteen phases ran (PHASE markers). A run that dies
#      in phase 4 must not be able to report PASS -- without this the
#      remaining checks would judge a truncated scenario.
#   3. Ph.9 really produces PERIODIC synchronisation messages. This is the
#      load-bearing content claim and the system-level regression guard for
#      B-R13-1: the phase switches to ITR_SYNC_HALFWORDS, and with the
#      pre-D1 half-word counter -- which advanced only on an ODD ilastsize,
#      while the model's default is 1 -- it emits none at all. Measured both
#      ways; the red counter-proof is in
#      docs/handoffs/V1_verification_infra.md.
#      NOTE: the leg was VACUOUS until V1 fixed it. It ran with
#      InstSyncMax=2, i.e. a 64-half-word threshold, over a window of 24
#      instructions (`run()` counts BYTES) = 48 half-words. It could not
#      reach its first tick with a BROKEN or a REPAIRED counter, so D1-F6's
#      premise -- that this testbench would have caught B-R13-1 -- is
#      measurably false. Max=0 (16 half-words) makes the same window cross
#      the threshold twice.
#   3b. the stream still decodes at all (a floor, not a PC contract).
#   4. floors on the workload itself (cpu_model events, ATB transfers), so a
#      scenario that silently stops producing cannot pass on an empty run.
#
# Exit: 0 PASS · 1 verdict failure · 4/5/6 build or simulator failure ·
#       78 toolchain/bootstrap (see scripts/run_gates.sh).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=feature_matrix_tb
abcfile="tests/instruction/19_feature_matrix/${tb}.abc"

# Floors. Every number here was MEASURED on the run recorded in the V1
# handoff, then rounded down. Raise them with the commit that raises the
# workload; never lower one silently.
MIN_PHASES=16        # Ph.1..Ph.10 + 6b (Enable=1 rejection of the DF range
                     # table, U10 F-3) + 10b + 10c + 10d (Enable=1 rejection,
                     # B-3) + 10e (Enable=1 rejection of trTeInstFeatures,
                     # U10 F-1) + Ph.11 (soft-reset persistence, B-4)
MIN_PERIODIC=2       # measured: Ph.9 crosses the 16-half-word threshold twice
MIN_DECODED=60       # NexRv message census before it gives up (measured 81)
MIN_EVENTS=300       # cpu_model event log (measured 324)
MIN_ATB=400          # ATB transfers observed by the recorder (measured 472)

ct_need_prj "$tb" "$abcfile" || exit $?
xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"

cd "$xd"
rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
xvlog --relax -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
	|| { echo "FAIL xvlog"; grep -i error xvlog.log | head; exit 4; }
xelab --relax --debug off "xil_defaultlib.${tb}" xil_defaultlib.glbl \
	-s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
	|| { echo "FAIL xelab"; grep -i error xelab.log | head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

echo "########## 19_feature_matrix (xsim)"
ct_xsim xsim_fm.log "${tb}_snap" -tclbatch _runall.tcl \
	|| { echo "FAIL: xsim leg unusable (reason above)"; exit 6; }

verdict=0

# ---- 1. testbench verdict ------------------------------------------------
# xsim returns 0 even for $fatal, so the exit code above proves only that the
# simulator STARTED. Everything below reads the log.
if grep -aq '\[fm_tb\] PASS (sim)' xsim_fm.log; then
	echo "  [PASS] testbench reached its end marker"
else
	echo "  [FAIL] testbench did not reach '[fm_tb] PASS (sim)'"
	tail -15 xsim_fm.log
	verdict=1
fi
n_err=$(grep -acE '^ *Error:|\$error|ERROR: \[' xsim_fm.log || true); n_err=${n_err:-0}
if [ "$n_err" -eq 0 ]; then
	echo "  [PASS] no error line in the simulator log"
else
	echo "  [FAIL] $n_err error line(s) in xsim_fm.log:"
	grep -aE '^ *Error:|\$error|ERROR: \[' xsim_fm.log | head -8
	verdict=1
fi
if grep -aq 'TIMEOUT - test exceeded' xsim_fm.log; then
	echo "  [FAIL] the testbench hit its own 100 ms watchdog"
	verdict=1
fi

# ---- 2. all phases ran ---------------------------------------------------
n_ph=$(grep -ac '\[fm_tb\] PHASE ' xsim_fm.log || true); n_ph=${n_ph:-0}
if [ "$n_ph" -ge "$MIN_PHASES" ]; then
	echo "  [PASS] $n_ph configuration phase(s) executed (floor $MIN_PHASES)"
else
	echo "  [FAIL] only $n_ph of $MIN_PHASES phases executed -- the run is truncated,"
	echo "         so every check below would judge a partial scenario"
	grep -a '\[fm_tb\] PHASE ' xsim_fm.log | tail -3
	verdict=1
fi

# ---- 3. the half-word cadence of Ph.9 really fires -----------------------
# NOT from the NexRv decode. This scenario reconfigures on the fly, and the
# reference decoder gives up part way through it -- measured 2026-08-09: the
# encoder emits 190 messages, NexRv places 81 and then aborts with "indirect
# address encountered in ICNT", INSIDE Ph.4. Ph.9 is message 170 onwards, so
# a decode-based cadence claim about it would be a claim about a part of the
# stream nobody looked at, i.e. exactly the vacuous check this gate exists to
# avoid. The sync REASON is therefore read from the simulator log, where the
# formatter names it (rtl/ct_L2_nexus_formatter.sv, sync-reason print).
n_per=$(grep -ac 'NEXUS_SYNC_PERIODIC' xsim_fm.log || true); n_per=${n_per:-0}
n_sync=$(grep -ac 'NEXUS_MSG_PROGRAM_TRACE_SYNC' xsim_fm.log || true); n_sync=${n_sync:-0}
echo "  [info] $n_sync synchronisation message(s) emitted, $n_per of them PERIODIC"
if [ "$n_per" -ge "$MIN_PERIODIC" ]; then
	echo "  [PASS] $n_per periodic sync(s) (floor $MIN_PERIODIC) -- Ph.9 sets"
	echo "         InstSyncMode=3 (ITR_SYNC_HALFWORDS), InstSyncMax=2 and retires"
	echo "         96 instructions; the half-word cadence really fires (B-R13-1)"
else
	echo "  [FAIL] only $n_per periodic sync(s), floor is $MIN_PERIODIC."
	echo "         Ph.9 sets InstSyncMode=3 (half-words) with InstSyncMax=2 and then"
	echo "         retires 96 instructions -- that window MUST produce periodic"
	echo "         syncs. Zero is the signature of the pre-D1 half-word counter,"
	echo "         which advanced only on an odd ilastsize and stood still at the"
	echo "         model's default of 1 (2 half-words per instruction)."
	grep -a 'sync reason' xsim_fm.log | tail -8
	verdict=1
fi

# ---- 3b. the stream is still decodable at all ----------------------------
# A floor, not a full contract: the testbench header rules out a PC contract
# on purpose. But "NexRv places nothing" and "NexRv places most of it" are
# different worlds, and only one of them is the status quo.
atb="$xd/${tb}.atb.bin"
info="$xd/${tb}.nexrv.info"
log="$xd/${tb}.nexrv.log"
if [ ! -s "$atb" ] || [ ! -s "$info" ]; then
	echo "  [FAIL] no ATB dump / PCInfo produced ($atb, $info)"
	verdict=1
else
	"$NEXRV" -deco "$atb" -pcinfo "$info" -pcout "$xd/${tb}.decoded.pcout" -full \
		> "$log" 2>&1 || true
	n_dec=$(grep -acE 'TCODE\[6\]=[0-9]+' "$log" || true); n_dec=${n_dec:-0}
	if [ "$n_dec" -ge "$MIN_DECODED" ]; then
		echo "  [PASS] $n_dec message(s) decoded by NexRv (floor $MIN_DECODED)"
	else
		echo "  [FAIL] only $n_dec message(s) decoded, floor is $MIN_DECODED"
		tail -4 "$log"
		verdict=1
	fi
fi

# ---- 4. the workload itself ----------------------------------------------
n_ev=$(sed -nE 's/.*\[fm_tb\] cpu_model logged ([0-9]+) events.*/\1/p' xsim_fm.log | tail -1)
n_ev=${n_ev:-0}
n_atb=$(sed -nE 's/.*\[fm_tb\] observed ([0-9]+) ATB transfers.*/\1/p' xsim_fm.log | tail -1)
n_atb=${n_atb:-0}
if [ "$n_ev" -ge "$MIN_EVENTS" ] && [ "$n_atb" -ge "$MIN_ATB" ]; then
	echo "  [PASS] workload: $n_ev cpu event(s) (floor $MIN_EVENTS), $n_atb ATB transfer(s) (floor $MIN_ATB)"
else
	echo "  [FAIL] workload below floor: $n_ev cpu event(s) (need $MIN_EVENTS), $n_atb ATB transfer(s) (need $MIN_ATB)"
	verdict=1
fi

echo "======================================================"
if [ "$verdict" -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $verdict
