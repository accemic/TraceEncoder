#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Board-Sequenz-Replay (tests/overflow/07_board_replay): Bisektor Encoder-vs-
# encoder core against the adapter path for the sync-boundary family. The
# decode runs against the CAPTURED pcinfo; the PCs are compared against the
# oracle prefix.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=board_replay_tb
src_tb=overrun_recovery_tb
# Program description of the captured hardware run. It is produced by the SoC
# integration flow and is not part of this repository -- point CT_REPLAY_PCINFO
# at it to run this gate.
PCINFO="${CT_REPLAY_PCINFO:-}"
if [ -z "$PCINFO" ] || [ ! -f "$PCINFO" ]; then
	echo "SKIP: this gate replays a captured hardware run; set CT_REPLAY_PCINFO"
	echo "      to that run's program description (produced by the SoC"
	echo "      integration flow, not by this repository)."
	exit 77
fi

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/07_board_replay/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi
# Include path: replay_seq.svh sits next to the testbench.
cp "$here/tests/overflow/07_board_replay/replay_seq.svh" "$xd/" 2>/dev/null

cd "$xd"
fail=0

rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -i "$here/tests/overflow/07_board_replay" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin"; grep -i "error" xelab.log xsim.log 2>/dev/null | head; exit 6; }
ct_no_sva_errors xelab.log xsim.log || { echo "FAIL: \$error/\$fatal in sim log"; exit 7; }

"$NEXRV" -dump "${tb}.atb.bin" > "nexrv_replay_dump.log" 2>&1
syncs=$(grep -acE "TCODE\[6\]=(9|29) " nexrv_replay_dump.log || true)
bps=$(grep -ac "TCODE\[6\]=56 " nexrv_replay_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "$PCINFO" -pcout "${tb}.pcout" -bp -full > "nexrv_replay.log" 2>&1
echo "NEXRV: $syncs Syncs, $bps VendorBP; deco: $(grep -a 'Decoded OK' nexrv_replay.log | tail -1)"

if [ "$syncs" -ge 1 ] && [ "$bps" -ge 1 ]; then echo "R0 PASS: syncs ($syncs) and VendorBP ($bps) present";
else echo "R0 FAIL: axis or feature not active (syncs=$syncs bps=$bps)"; fail=1; fi

if grep -aq "Decoded OK" nexrv_replay.log; then
	echo "R1 DECODE OK ($(grep -ac 'PC: 0x' nexrv_replay.log) PCs) -> encoder core CLEAN on the captured sequence (points at the adapter)"
else
	echo "R1 DECODE FAIL (= Familie im Encoder REPRODUZIERT): $(tail -3 nexrv_replay.log | tr '\n' ' ')"
	grep -a "ICNT adjust" nexrv_replay.log | tail -3
	fail=1
fi

exit $fail
