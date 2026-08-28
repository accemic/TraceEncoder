#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# board_demo_soak.sh -- drive the demos REPEATEDLY and measure whether the
# chain stays stable. The single walkthrough (board_demo_walkthrough.sh)
# answers "does it work?"; this script answers "does it STILL work the
# twentieth time, and in any order?".
#
#   KV260_BOARD=<board-ip> KV260_JUMP=<jump-host> \
#     bash examples/kv260/board_demo_soak.sh [rounds]           # default 5
#   SCEN="mbv duo trio" KV260_BOARD=... KV260_JUMP=... \
#     bash examples/kv260/board_demo_soak.sh 10
#
# WHY TRANSITIONS ARE THE RIGHT ROBUSTNESS TEST. The failure mode that wedges
# this board is not the first load of a design; it is the CHANGE from one
# scenario to the next -- bitstream unload, reload, slot re-assignment, and
# the first register access afterwards. A per-demo walkthrough executes that
# transition exactly once; a user clicking around the dashboard executes it
# dozens of times. This script therefore changes scenarios on purpose, in
# alternating order, and checks after EVERY step whether the board is still
# alive.
#
# What is measured, per round and per scenario:
#   - does the bitstream load, and does xmutil record the slot (with a wait)?
#   - does the service reach live mode?
#   - does trace start (trace_bytes rises) and can it be stopped?
#   - does the board still answer afterwards (sensors via PS -- independent
#     of the PL)?
#   - temperature/power, so that a later failure can be placed in context
#
# ABORT: as soon as the board stops answering, the run ends IMMEDIATELY with
# exit 2 and writes the last state to the log. Carrying on would be pointless
# (the AXI bus is wedged, only a power cycle helps) and would blur the
# evidence.
set -u

# No lab defaults: the board address and the jump host are site-specific.
BOARD="${KV260_BOARD:-}"
JUMP="${KV260_JUMP:-}"
PORT="${PORT:-8099}"
[ -n "$BOARD" ] || { echo "board_demo_soak: set KV260_BOARD=<board-ip>" >&2; exit 2; }
[ -n "$JUMP" ]  || { echo "board_demo_soak: set KV260_JUMP=<jump-host>" >&2; exit 2; }
ROUNDS="${1:-5}"
here="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$here"
OUT="${OUT:-$here/bld/board_soak}"
mkdir -p "$OUT"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG="$OUT/soak_$STAMP.log"

SCEN="${SCEN:-mbv duo trio tgc5b2_axis_wp cva6_linux cva6_linux64 rocket64 rocket2 cva6_2_rv32}"

say() { echo "$*" | tee -a "$LOG"; }

api_get()  { timeout 60 ssh -o ConnectTimeout=10 "$JUMP" "curl -s -m 25 http://$BOARD:$PORT$1" </dev/null 2>/dev/null; }
api_post() { timeout 120 ssh -o ConnectTimeout=10 "$JUMP" "curl -s -m 60 -X POST -H 'Content-Type: application/json' -d '$2' http://$BOARD:$PORT$1" </dev/null 2>/dev/null; }
board_sh() { timeout 90 ssh -o ConnectTimeout=10 "$JUMP" "timeout 60 ssh -o ConnectTimeout=8 ubuntu@$BOARD '$1'" </dev/null 2>/dev/null; }

jget() { py -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
k='$1'.split('.')
for p in k:
    if isinstance(d,dict): d=d.get(p)
    else: d=None
print('' if d is None else d)"; }

# Is the board still alive? PS side, without touching the PL aperture --
# exactly why the sensors read /sys and not registers.
alive() {
	local s; s="$(api_get /api/sensors)"
	[ -n "$s" ] && [ "$(printf '%s' "$s" | jget available)" = "True" ]
}

sens_line() {
	api_get /api/sensors | py -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: print('n/a'); raise SystemExit
print('PL %s C  PS %s C  fan %s%%  %s W' % (d.get('temp_pl_c'), d.get('temp_ps_c'), d.get('fan_percent'), d.get('power_w')))"
}

slot_of() {
	board_sh "sudo xmutil listapps 2>/dev/null" | awk -v a="$1" '
		$1==a { for(i=NF;i>0;i--) if ($i ~ /^-?[0-9]+,?$/) { print ($i=="-1" ? "NO" : "YES"); exit } }
	' | head -1
}

say "board_demo_soak $STAMP  board=$BOARD rounds=$ROUNDS"
say "scenarios: $SCEN"
say "start: $(sens_line)"

if ! alive; then
	say "ABORT before the start: the board does not answer."
	exit 2
fi

total=0; ok=0; fail=0
for r in $(seq 1 "$ROUNDS"); do
	# Flip the order every round: the transition A->B is the item under test,
	# not the scenario itself. Always the same sequence would always test the
	# same transitions.
	if [ $((r % 2)) -eq 0 ]; then
		order="$(echo "$SCEN" | tr ' ' '\n' | tac | tr '\n' ' ')"
	else
		order="$SCEN"
	fi
	say ""
	say "---------- round $r/$ROUNDS ----------"
	for sc in $order; do
		total=$((total+1))
		res="$(api_post /api/scenario "{\"id\":\"$sc\",\"load\":true}")"
		app="$(printf '%s' "$res" | jget load.app)"
		loaded="$(printf '%s' "$res" | jget loaded)"
		if [ "$loaded" != "True" ] && [ "$loaded" != "true" ]; then
			say "  $sc: LOAD-FAIL ($(printf '%s' "$res" | head -c 90))"
			fail=$((fail+1))
			alive || { say "  BOARD DEAD after LOAD-FAIL on $sc"; say "last state: (no answer)"; exit 2; }
			continue
		fi
		s=""
		for _t in 1 2 3 4 5; do s="$(slot_of "$app")"; [ "$s" = "YES" ] && break; sleep 2; done
		if [ "$s" != "YES" ]; then
			say "  $sc: SLOT-FAIL"
			fail=$((fail+1))
			alive || { say "  BOARD DEAD after SLOT-FAIL on $sc"; exit 2; }
			continue
		fi
		api_post /api/ctl '{"action":"trace_on"}' >/dev/null
		api_post /api/ctl '{"action":"run"}'      >/dev/null
		sleep 2
		b="$(api_get /api/state | jget trace_bytes)"
		api_post /api/ctl '{"action":"stop"}' >/dev/null
		if ! alive; then
			say "  $sc: BOARD DEAD after run/stop (trace_bytes=$b)"
			exit 2
		fi
		if [ -n "${b:-}" ] && [ "${b:-0}" -gt 0 ] 2>/dev/null; then
			say "  $sc: ok  trace_bytes=$b"
			ok=$((ok+1))
		else
			say "  $sc: NO TRACE (trace_bytes=${b:-?})"
			fail=$((fail+1))
		fi
	done
	say "  end of round $r: $(sens_line)"
done

say ""
say "================ soak summary ================"
say "transitions: $total   ok: $ok   suspicious: $fail"
say "board at the end: $(sens_line)"
say "log: $LOG"
[ "$fail" -eq 0 ] && { say "RESULT: stable"; exit 0; } || { say "RESULT: anomalies -- see above"; exit 1; }
