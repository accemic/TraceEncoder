#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Oracle replay WITH overflow (tests/overflow/10_replay_ovf): the mixed-workload
# class (VendorBP BCNT misattribution after FIFO_OVERRUN anchors) driven with a
# REAL branch history through the simulated encoder. Gates T0/T1/T2 -- see the
# testbench header.
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_python   # gen_replay.py + check_transitions.py are called as `python`
ct_need_nexrv

tb=replay_ovf_tb
src_tb=overrun_recovery_tb
# Program description of the captured hardware run -- see
# cli_boardreplay_test.sh; set CT_REPLAY_PCINFO to enable this gate.
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
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/10_replay_ovf/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi
# replay_seq.svh is generated (1.2 MB) and not versioned -- regenerate it from
# the versioned oracle when needed; the generation is deterministic.
if [ ! -f "$here/tests/overflow/10_replay_ovf/replay_seq.svh" ]; then
	python "$here/scripts/gen_replay.py" \
		"$here/tests/overflow/10_replay_ovf/mixcalls_oracle.u32" \
		"$PCINFO" \
		-o "$here/tests/overflow/10_replay_ovf/replay_seq.svh" \
		--start 0 --count 30000 || { echo "FAIL: gen_replay"; exit 3; }
fi
cp "$here/tests/overflow/10_replay_ovf/replay_seq.svh" "$xd/" 2>/dev/null

cd "$xd"
fail=0

rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -i "$here/tests/overflow/10_replay_ovf" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log -R >/dev/null 2>&1
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin"; grep -i "error" xelab.log xsim.log 2>/dev/null | head; exit 6; }
ct_no_sva_errors xelab.log xsim.log || { echo "FAIL: \$error/\$fatal in sim log"; exit 7; }

"$NEXRV" -dump "${tb}.atb.bin" > "nexrv_rovf_dump.log" 2>&1
errors=$(grep -ac "TCODE\[6\]=8 " nexrv_rovf_dump.log || true)
bps=$(grep -ac "TCODE\[6\]=56 " nexrv_rovf_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "$PCINFO" -pcout "${tb}.pcout" -bp -full > "nexrv_rovf.log" 2>&1
echo "NEXRV: $errors Error messages, $bps VendorBP; deco: $(grep -a 'Decoded OK' nexrv_rovf.log | tail -1)"

if [ "$errors" -ge 1 ]; then echo "T0 PASS: natural overflow reached ($errors)";
else echo "T0 FAIL: no overflow -- increase the throttle or the volume"; fail=1; fi
if [ "$bps" -ge 1 ]; then echo "T1 PASS: VendorBP im Strom ($bps)";
else echo "T1 FAIL: no VendorBP"; fail=1; fi

if grep -aq "Decoded OK" nexrv_rovf.log; then
	if python "$here/scripts/check_transitions.py" "${tb}.pcout" "${tb}.expected.pcs" nexrv_rovf.log > check_rovf.log 2>&1; then
		echo "T2 PASS: Decoded OK and every transition legal ($(grep -ac 'PC: 0x' nexrv_rovf.log) PCs across $errors recoveries)"
	else
		echo "T2 FAIL: Decoded OK, but ILLEGAL transitions (the mixed-workload class REPRODUCES):"
		head -6 check_rovf.log
		fail=1
	fi
else
	echo "T2 FAIL: Decode abgebrochen (mix-Klasse REPRODUZIERT?) -- $(tail -3 nexrv_rovf.log | tr '\n' ' ')"
	fail=1
fi

exit $fail
