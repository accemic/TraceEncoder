#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Pause-edge guard: InstTracing toggled off and on asynchronously in the
# CF-dichten Retire-Strom (tests/overflow/11_pause_edge). Board-Klasse KV260
# hardware runs without any overflow: VendorBP with BCNT=0 between the
# correlation and the re-anchor, and a sync carrying ICNT=24, which derails the
# decoder into the 0x40 idle trap.
# Gates:
#   P0  Kontroll-Leg (+NO_PAUSE): Decoded OK, 0 Correlation
#   P1  Pause leg: >=4 correlations, each followed by a re-anchor sync
#   P2  NexRv "Decoded OK" (-bp)
#   P3  Contract: only VendorConfig may appear between the correlation and the
#       re-anchor sync; the re-anchor ProgTraceSync carries ICNT=0
#   P4  check_transitions: every transition legal
#   P5  trTeControl.Empty == 1 after stop and flush (checked in the testbench)
# Self-contained: clones the xsim .prj of the overrun test. Local bring-up aid,
# not part of the upstream CI.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_python
ct_need_nexrv

tb=pause_edge_tb
src_tb=overrun_recovery_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/overflow/01_overrun_recovery/${src_tb}.sv|tests/overflow/11_pause_edge/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
fail=0

# ---- Compile + elaborate ONCE; the legs run via xsim -testplusarg ----------
# xelab 2022.1 does not accept -testplusarg (only xsim does), so -R cannot be
# used here: one snapshot, two xsim runs.
rm -rf xsim.dir "${tb}.atb.bin"
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -iE "^ERROR" xelab.log | head; exit 5; }

# ---- Leg A: control run (+NO_PAUSE) -----------------------------------------
ct_xsim xsim_np.log "${tb}_snap" -R -testplusarg NO_PAUSE || exit 6
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (Kontroll-Leg)"; grep -i "error" xsim_np.log 2>/dev/null | head; exit 6; }
# ($error/$fatal in xsim_np.log: ct_xsim above already judges that -- V2)
"$NEXRV" -dump "${tb}.atb.bin" > np_dump.log 2>&1
np_corr=$(grep -ac "TCODE\[6\]=33 " np_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout np.pcout -bp -full > np_deco.log 2>&1
if grep -aq "Decoded OK" np_deco.log && [ "$np_corr" -le 1 ]; then
	echo "P0 PASS: control leg: Decoded OK, $np_corr correlation messages (stop only)"
else
	echo "P0 FAIL: Kontroll-Leg deco=$(tail -2 np_deco.log|tr '\n' ' ') corr=$np_corr"; fail=1
fi

# ---- Leg B: Pausen ----------------------------------------------------------
rm -f "${tb}.atb.bin"
ct_xsim xsim.log "${tb}_snap" -R || exit 6
[ -f "${tb}.atb.bin" ] || { echo "FAIL: no atb.bin (Pause-Leg)"; grep -i "error" xsim.log 2>/dev/null | head; exit 6; }
# ($error/$fatal in xsim.log: ct_xsim above already judges that -- V2)

"$NEXRV" -dump "${tb}.atb.bin" > pe_dump.log 2>&1
corr=$(grep -ac "TCODE\[6\]=33 " pe_dump.log || true)
"$NEXRV" -deco "${tb}.atb.bin" -pcinfo "${tb}.nexrv.info" -pcout pe.pcout -bp -full > pe_deco.log 2>&1
echo "NEXRV: $corr Correlations; deco: $(grep -a 'Decoded OK' pe_deco.log | tail -1)"

if [ "$corr" -ge 4 ]; then echo "P1 PASS: $corr correlations (pauses active)";
else echo "P1 FAIL: only $corr correlations -- the pause stimulus had no effect"; fail=1; fi

if grep -aq "Decoded OK" pe_deco.log; then echo "P2 PASS: Decoded OK ($(grep -ac 'PC: 0x' pe_deco.log) PCs)";
else echo "P2 FAIL (= Klasse REPRODUZIERT): $(tail -3 pe_deco.log | tr '\n' ' ')"; fail=1; fi

# P3: contract between the correlation and the re-anchor sync
python3 - "$xd/pe_dump.log" <<'PYEOF'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
msgs = []          # (tcode, [field lines])
for ln in lines:
    m = re.match(r"0x[0-9A-Fa-f]+ [01_]+: TCODE\[6\]=(\d+) ", ln)
    if m:
        msgs.append([int(m.group(1)), []])
    elif msgs and ln.strip() and "IDLE" not in ln:
        msgs[-1][1].append(ln)
bad = 0
in_gap = False
for tcode, fields in msgs:
    if tcode == 33:
        in_gap = True
        continue
    if in_gap:
        if tcode == 58:      # VendorConfig on the resume edge: allowed
            continue
        if tcode in (9, 11, 12):
            # Re-anchor: ProgTraceSync (9, a non-CF anchor) OR Direct/
            # IndirectBranchSync (11/12 -- the anchor beat was a call, return
            # or jump; sync_anchor_ok only spares plain branches in BP mode).
            # ICNT must be 0 only for the EXCLUSIVE anchor (9); for 11 and 12
            # the ICNT covers exactly the anchor instruction (the inclusive
            # path) and the unlocked decoder skips it anyway.
            if tcode == 9:
                icnt = 0
                for f in fields:
                    m = re.search(r"ICNT\[\d+\]=0x[0-9A-Fa-f]+ \((\d+)\)", f)
                    if m:
                        icnt = int(m.group(1))
                if icnt != 0:
                    print(f"P3 VIOLATED: re-anchor ProgTraceSync with ICNT={icnt} (expected 0)")
                    bad += 1
            in_gap = False
            continue
        print(f"P3 VIOLATED: TCODE {tcode} between the correlation and the re-anchor sync")
        bad += 1
        in_gap = False   # count only the first violation per pause
if bad == 0:
    print("P3 PASS: pause-edge contract holds (only config between correlation and sync, sync ICNT=0)")
sys.exit(1 if bad else 0)
PYEOF
[ $? -eq 0 ] || fail=1

# P4: transition check (loss tolerant; pause gaps only at segment boundaries)
python3 "$here/scripts/check_transitions.py" pe.pcout "${tb}.expected.pcs" pe_deco.log | tail -2
[ ${PIPESTATUS[0]} -eq 0 ] && echo "P4 PASS" || { echo "P4 FAIL"; fail=1; }

exit $fail
