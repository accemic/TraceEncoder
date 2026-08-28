#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# P0-07 gate: the core/encoder address-width agreement is ENFORCED, not
# announced.
#
# A hart wider than the netlist that traces it loses its upper address bits in
# the adapter -- silently: the assignment to the narrower tip_if.iaddr
# truncates without a warning, the encoder emits a well-formed stream of
# plausible low addresses, the config message honestly advertises the
# netlist's OWN width (CAPS bit 23), and the decoder reconstructs exactly what
# it was handed. Nothing downstream can recover the difference, so the refusal
# has to happen before the build: ct_encoder takes the width of the attached
# hart as parameter CORE_XLEN and refuses to elaborate unless it is declared
# AND matches ct_pkg::CT_XLEN.
#
# Three legs, one per outcome (tests/instruction/38_core_xlen):
#
#   accept      a matching declaration    -> elaborates AND traces
#   mismatch    the other width           -> refused, no capture
#   undeclared  CORE_XLEN left at 0       -> refused, no capture
#
# The accepting leg is not decoration: a guard that rejected everything would
# pass the two negative legs on its own.
#
# THE VERDICT IS READ OFF THE OUTPUT, NEVER OFF THE EXIT CODE. Two independent
# reasons, both measured on this tree:
#
#   * xsim returns 0 for an elaboration `$fatal`, so a zero exit says nothing
#     about whether the guard fired.
#   * abc-flow runs Verilator with `-Wno-fatal` (abc/_abcflow/verilator.py),
#     which DEMOTES the elaboration `$fatal` to a warning and lets the run
#     continue. Measured 2026-08-12: with only the elaboration guard in place,
#     the mismatch leg printed the message and then traced 15 ATB transfers.
#     That is why the guard in rtl/ct_encoder.sv carries an `initial $fatal`
#     twin -- and why this script also checks that NO capture was produced,
#     which is the property the work package is actually about.
#
# usage: bash scripts/cli_corexlen_test.sh
# exit 0 = all three legs behaved, 1 = at least one did not,
#      78 = the toolchain is not there, so nothing was judged (CT_E_TOOL).

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

# Every leg is an `abc -sim` run, and abc is a Python program whose shebang is
# `#!/usr/bin/env python3`; with the committed sim_backend it then drives
# Verilator. This script used to inherit all three from whatever the calling
# shell happened to offer -- and the stage-2 runner sets nothing. On a Windows
# host, where `python3` on PATH is the Microsoft Store stub, that produced
#
#     core_xlen: FAIL (3 leg(s))
#
# on a healthy tree (measured 2026-08-12): abc never started, no leg log held
# anything but the stub's installation hint, and the gate blamed the encoder.
# A gate that goes red where nothing is broken is a gate people switch off, so
# the three tools are ESTABLISHED here rather than assumed -- the same two
# lines the other 48 cli_* gates carry. ct_need_abc heals python (bld/pyshim)
# and locates the driver; a tool that cannot be found leaves through ct_die,
# i.e. with CT_E_TOOL (78) and a message naming it, never as a leg failure.
. "$here/scripts/ct_env.sh"
ct_need_abc
# ct_need_abc only repairs VERILATOR_ROOT best-effort (its callers may be on
# the Vivado backend). This gate has no such choice: it runs abc with the
# configuration as committed, so when that says verilator, verilator has to be
# there -- and its absence must say so instead of surfacing as three legs that
# "did not run through".
if [ "$(ct_abc_backend)" = verilator ]; then
	ct_need_verilator
fi

FAILS=0
LOGDIR="$here/bld"
mkdir -p "$LOGDIR"

# The message fragments the guards must produce. Kept as literals on purpose:
# if a guard is reworded, this gate goes red and the wording is re-agreed
# here, rather than the check silently matching nothing (the failure mode
# scripts/check_profile_deps.py was hardened against).
MSG_MISMATCH="does not match this netlist's trace ingress width"
MSG_UNDECLARED="CORE_XLEN is 0 (undeclared)"

# The testbench names are spelled out at the call sites below rather than
# assembled from the leg name: scripts/check_orphan_gates.py looks for a
# testbench's file name in the scripts, and a name hidden behind a shell
# variable reads to it as a testbench nobody runs. It caught exactly that
# here.
run_leg () { # $1 = testbench name -> writes $LOGDIR/<tb>.log
	local tb="$1" leg log
	leg="${tb#core_xlen_}"; leg="${leg%_tb}"
	log="$LOGDIR/core_xlen_${leg}.log"
	# A stale work dir makes Verilator skip re-elaboration, and a guard that
	# is not re-elaborated cannot be observed to fire. Measured: the second
	# run of the mismatch leg printed no guard message at all for exactly
	# this reason.
	rm -rf "$LOGDIR/${tb}.vsim"
	rm -f "$LOGDIR/core_xlen_tb.atb.bin"
	( cd "$LOGDIR" && abc -sim "../tests/instruction/38_core_xlen/${tb}.abc" ) \
		>"$log" 2>&1 || true
	echo "$log"
}

# A rejecting leg must (a) name the reason, (b) not reach the simulation, and
# (c) leave no capture behind. (c) is the one that matters to a user: an
# encoder that announces the mismatch and records anyway is the state this
# package replaces.
check_reject () { # $1 = testbench, $2 = expected message fragment
	local tb="$1" want="$2" leg log ok=1
	leg="${tb#core_xlen_}"; leg="${leg%_tb}"
	log="$(run_leg "$tb")"
	if ! grep -qF "$want" "$log"; then
		echo "FAIL ($leg): guard message not found: $want"; ok=0
	fi
	if grep -qF "[core_xlen_tb] PASS" "$log"; then
		echo "FAIL ($leg): the testbench RAN -- the guard did not stop it"; ok=0
	fi
	if grep -qF "GUARD DID NOT FIRE" "$log"; then
		echo "FAIL ($leg): reached simulation with a rejected declaration"; ok=0
	fi
	if [ -s "$LOGDIR/${leg}.vsim/core_xlen_tb.atb.bin" ] \
	|| [ -s "$LOGDIR/core_xlen_${leg}_tb.vsim/core_xlen_tb.atb.bin" ]; then
		echo "FAIL ($leg): a capture was produced despite the refusal"; ok=0
	fi
	if [ "$ok" = 1 ]; then
		echo "PASS ($leg): refused, no capture  [$log]"
	else
		FAILS=$((FAILS + 1))
	fi
}

check_accept () {
	local log ok=1
	log="$(run_leg core_xlen_accept_tb)"
	if ! grep -qF "[core_xlen_tb] PASS" "$log"; then
		echo "FAIL (accept): a MATCHING declaration did not run through"; ok=0
	fi
	# The SVA channel, on the shared road (ct_no_sva_errors, scripts/ct_env.sh).
	# It replaces a private `grep -qE "%Fatal.*CORE_XLEN"` verdict that stood
	# here until 2026-08-13 and was strictly weaker: it saw the ONE message it
	# named and was blind to every other assertion this leg can fire. The
	# accept leg elaborates and simulates for real, so its expectation is an
	# exact ZERO -- measured on a healthy tree, bld/core_xlen_accept.log holds
	# 0 lines matching CT_SVA_RE. (The two reject legs are the opposite case:
	# there the guard message IS the result, and check_reject asserts its
	# wording; they never reach a simulation.)
	# The wording is deliberately not "assertion": run_leg redirects the WHOLE
	# `abc -sim` invocation, so this log carries the Verilator BUILD and the
	# run in one file, and `%Error:` can come from either. Measured
	# 2026-08-13: a build that died of "The paging file is too small" (the
	# -j 32 that abc-flow hard-codes) put one `%Error: make -C ...` line in
	# here, and a message promising an assertion would have sent the reader
	# hunting for an RTL defect. Red is right in both cases -- the leg
	# verified nothing either way -- but the label must not pick a side.
	if ! ct_no_sva_errors "$log"; then
		echo "FAIL (accept): %Error/%Fatal line(s) in the abc log (assertion OR build -- read $log)"; ok=0
	fi
	if ! grep -qE "observed [1-9][0-9]* ATB transfers" "$log"; then
		echo "FAIL (accept): elaborated but produced no trace bytes"; ok=0
	fi
	if [ "$ok" = 1 ]; then
		echo "PASS (accept): elaborated and traced  [$log]"
	else
		FAILS=$((FAILS + 1))
	fi
}

echo "### P0-07: core/encoder width agreement"
echo "### leg accept (declaration matches the netlist)"
check_accept
echo "### leg mismatch (a hart of the other width)"
check_reject core_xlen_mismatch_tb "$MSG_MISMATCH"
echo "### leg undeclared (nothing declared)"
check_reject core_xlen_undeclared_tb "$MSG_UNDECLARED"

if [ "$FAILS" = 0 ]; then
	echo "core_xlen: PASS (3/3 legs)"
	exit 0
fi
echo "core_xlen: FAIL ($FAILS leg(s))"
exit 1
