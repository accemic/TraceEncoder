#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# P8 / B-N1: the explicit sync request across a reset of the CONSUMER's
# domain alone, at two unrelated clocks.
#
# The two halves of one request live in two reset domains -- the pacing in
# wb_rst (ct_sync_req_pacer), the pending latch in tip_rst
# (ct_L23_preproc_sync) -- and ct_encoder carries both as INDEPENDENT inputs,
# which doc/integration.adoc states as a property of the design. A core reset
# that leaves the CSR domain running therefore clears the consumer's state
# without an acknowledgement. With the retired strobe handshake the request
# was then gone for good; with the four-phase LEVEL handshake the consumer
# simply sees the still-standing request again.
#
# Formal proves that at ONE clock (formal/preproc_sync, task tereqrst,
# P-SYNC-12) because that is the assumption the whole wrapper carries
# (ASM-SYNC-3). This gate is the other half: two unrelated clocks, a scenario
# sweep over reset length, over how many requests have already gone through
# (the toggle-parity dimension the strobe design was sensitive to), over a
# queued second request and over a write landing DURING the reset.
#
# Two runs, and the second one is the point:
#   1. as built            -> must PASS
#   2. `+strobe`           -> the RED CONTROL: the testbench rebuilds the
#                             request as a one-cycle pulse, which is the
#                             retired design in one line, and it must FAIL.
# A gate whose red side is not shown is a gate that proves nothing.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado

tb=ct_sync_req_pacer_tb
wd="bld/syncreqrst"
rm -rf "$wd"; mkdir -p "$wd"

# xvlog/xelab are native Windows binaries under MSYS: native paths in the prj.
w () { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
: > "$wd/${tb}_vlog.prj"
for f in rtl/external/testtools/string_pkg.sv \
         rtl/external/testtools/file_pkg.sv \
         rtl/external/testtools/tt.sv \
         rtl/external/common/signal_cdc.sv \
         rtl/pkg/ct_sync_req_pacer.sv \
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

verdict=0

echo "########## level handshake (as built) -- expect PASS"
ct_xsim "xsim_level.log" "${tb}_snap" -tclbatch _runall.tcl \
	|| { echo "FAIL: xsim leg level unusable (reason above)"; exit 6; }
grep -aE '^MODE:|^SCEN|Testcase:|Info: Testbench' "xsim_level.log"
if grep -aq 'Info: Testbench passed.' "xsim_level.log"; then
	echo "  [PASS] level handshake: every request answered, path alive after every reset"
else
	echo "  [FAIL] level handshake"
	grep -aE '^ *Error:' "xsim_level.log" | head -5
	verdict=1
fi

echo "########## RED CONTROL: one-cycle request (the retired strobe) -- expect FAIL"
# ct_xsim, not a bare call, and its verdict is about the RUN, not about the
# testbench: a failing testbench still reaches $finish, while an engine that
# never started would leave the previous log in place and the red side would
# look red for the wrong reason (the very confusion check_xsim_guard exists
# for).
# CT_SVA_EXPECT=off: ct_xsim now fails a run whose log carries $error/$fatal
# (V2, scripts/ct_env.sh). Here the errors ARE the result -- this leg exists
# to produce them, and the verdict below is inverted. An exact count would
# tie the gate to an incidental number (141 on 2026-08-09); what must hold is
# "it did not pass", and that is what is checked.
if ! CT_SVA_EXPECT=off ct_xsim "xsim_strobe.log" "${tb}_snap" -testplusarg strobe -tclbatch _runall.tcl; then
	echo "  [FAIL] the red control did not run"
	verdict=1
elif grep -aq 'Info: Testbench passed.' "xsim_strobe.log"; then
	echo "  [FAIL] the red control PASSED -- this gate proves nothing"
	verdict=1
else
	echo "  [PASS] the red control failed, as it must. First findings:"
	grep -aE '^ *Error:' "xsim_strobe.log" | head -2 | sed 's/^/      /'
fi

echo "======================================================"
if [ "$verdict" -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $verdict
