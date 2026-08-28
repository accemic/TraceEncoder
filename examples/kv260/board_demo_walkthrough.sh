#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# board_demo_walkthrough.sh -- drive every KV260 demo through one complete
# run, the way a person operates it in the dashboard, and write a log:
#
#   pick scenario -> load bitstream -> VERIFY SLOT -> check mode
#   -> load program -> run -> watch counters -> stop -> read memory
#   -> fetch trace -> decode -> verdict
#
#   KV260_BOARD=<board-ip> KV260_JUMP=<jump-host> \
#     bash examples/kv260/board_demo_walkthrough.sh              # all demos
#   KV260_BOARD=... KV260_JUMP=... \
#     bash examples/kv260/board_demo_walkthrough.sh mbv duo      # a selection
#
# WHY THE SLOT CHECK IS THE MOST IMPORTANT STEP. A write to the PL aperture
# 0xA000_0000 while our own app is NOT in the slot wedges the AXI
# interconnect: no SSH, no ping, power switch only. Between "app loaded" and
# the core_run write there is a window in which the slot can still be empty,
# and `fpga_manager` cheerfully reports "operating" in exactly that state --
# only the Active_slot column of `xmutil listapps` tells the truth. This
# script therefore checks the slot IMMEDIATELY before every control access
# and aborts the demo instead of guessing.
#
# The dashboard service on the board is the operator interface driven here
# (the same API calls the buttons issue) -- so the run exercises the chain a
# user actually uses, not a second one built for the test.
#
# Exit: 0 = every requested demo reached verdict PASS, 1 = at least one did not.
set -u

# No lab defaults: the board address and the jump host are site-specific.
BOARD="${KV260_BOARD:-}"
JUMP="${KV260_JUMP:-}"
PORT="${PORT:-8099}"
[ -n "$BOARD" ] || { echo "board_demo_walkthrough: set KV260_BOARD=<board-ip>" >&2; exit 2; }
[ -n "$JUMP" ]  || { echo "board_demo_walkthrough: set KV260_JUMP=<jump-host>" >&2; exit 2; }
here="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$here"
OUT="${OUT:-$here/bld/board_walkthrough}"
mkdir -p "$OUT"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG="$OUT/walkthrough_$STAMP.log"

# All dashboard scenarios. The bare-metal demos carry a program that is
# loaded here; the Linux demos boot from the reserved PS-DDR window and are
# therefore handled differently (see LINUX_SCEN).
SCEN_ALL="mbv duo trio tgc5b2_axis_wp cva6_linux cva6_linux64 rocket64 rocket2 cva6_2_rv32 cva6_2_rv64"
LINUX_SCEN=" cva6_linux cva6_linux64 rocket64 rocket2 cva6_2_rv32 cva6_2_rv64 "

say() { echo "$*" | tee -a "$LOG"; }

# --- remote calls ----------------------------------------------------------
# A single ssh hop to the jump host; from there curl to the board, or ssh to
# the board. `< /dev/null` everywhere, because ssh otherwise eats the stdin
# of the surrounding loop -- measured: the run stops after the first demo.
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

# Slot truth: NOT fpga_manager, but the Active_slot column.
slot_ok() {
	local app="$1"
	board_sh "sudo xmutil listapps 2>/dev/null" | awk -v a="$app" '
		$1==a { for(i=NF;i>0;i--) if ($i ~ /^-?[0-9]+,?$/) { print ($i=="-1" ? "NO" : "YES"); exit } }
	' | head -1
}

demo_one() {
	local sc="$1" rc=0
	say ""
	say "=============================================================="
	say "=== $sc"
	say "=============================================================="

	# 1. pick scenario AND load bitstream (exactly the 'Load bitstream' button)
	local res app loaded
	res="$(api_post /api/scenario "{\"id\":\"$sc\",\"load\":true}")"
	app="$(printf '%s' "$res" | jget load.app)"
	loaded="$(printf '%s' "$res" | jget loaded)"
	say "  [1] scenario+load : app=${app:-?} loaded=${loaded:-?}"
	if [ "$loaded" != "True" ] && [ "$loaded" != "true" ]; then
		say "  ABORT: bitstream not loaded -- $(printf '%s' "$res" | head -c 200)"
		return 1
	fi

	# 2. VERIFY SLOT -- the step whose absence wedges the board.
	# With retries: after `loadapp`, dfx-mgr needs a moment before the
	# Active_slot column is populated. Without the wait, the first look
	# reports "no slot" although the load succeeded (measured: UNKNOWN
	# immediately, "0," two seconds later).
	local s=""
	for _try in 1 2 3 4 5; do
		s="$(slot_ok "$app")"
		[ "$s" = "YES" ] && break
		sleep 2
	done
	say "  [2] slot check    : $app -> ${s:-UNKNOWN}"
	if [ "$s" != "YES" ]; then
		say "  ABORT: our app does NOT own the slot -- no register access."
		return 1
	fi

	# 3. mode: only now may "live" be expected
	# The mode needs a second look as well: the service re-evaluates live
	# capability on access, so the answer right after the load can still
	# read "demo".
	local mode=""
	for _try in 1 2 3 4 5; do
		mode="$(api_get /api/mode | jget mode)"
		[ "$mode" = "live" ] && break
		sleep 2
	done
	say "  [3] mode          : $mode"
	[ "$mode" = "live" ] || { say "  ABORT: service not in live mode."; return 1; }

	# 4. load program (bare metal) resp. note (Linux demos)
	case "$LINUX_SCEN" in
		*" $sc "*)
			say "  [4] program       : skipped -- Linux demo boots from the reserved PS-DDR window"
			;;
		*)
			local elf hexf
			elf="$(ls -1 examples/kv260/*/sw/build/trace_test.elf examples/kv260/*/sw/*.elf 2>/dev/null | head -1)"
			if [ -n "$elf" ]; then
				# The file MUST go to the jump host first, because curl runs
				# there. With `ssh ... "curl --data-binary @-" < file`, curl
				# reads the stdin of the REMOTE shell -- but the file is local.
				# Measured on duo: the upload dutifully reported "332 bytes",
				# the core then ran into nothing and produced 40 instead of
				# 10 million bytes.
				local up
				timeout 120 scp -q "$elf" "$JUMP:/tmp/wt_prog.elf" </dev/null 2>/dev/null
				up="$(timeout 120 ssh -o ConnectTimeout=10 "$JUMP" "curl -s -m 60 --data-binary @/tmp/wt_prog.elf -X POST 'http://$BOARD:$PORT/api/elf?target=ram'" </dev/null 2>/dev/null)"
				say "  [4] program       : $(basename "$elf") -> $(printf '%s' "$up" | jget loaded_bytes) bytes"
				# Counter-check: is it really in memory? The core is still
				# stopped here, so the window is readable (an access to the
				# window of a RUNNING core wedges the AXI bus -- which is why
				# the server refuses it).
				local mem0
				mem0="$(api_get "/api/read?region=ram&off=0&n=4")"
				say "  [4b] memory check : ${mem0:0:110}"
			else
				say "  [4] program       : NO ELF found -- core runs into nothing, the run says nothing"
			fi
			;;
	esac

	# 5. counters before the start
	local b0; b0="$(api_get /api/state | jget trace_bytes)"
	say "  [5] before run    : trace_bytes=${b0:-?}"

	# 6a. SWITCH THE ENCODER ON -- without this step NOTHING visible happens.
	# `run` only sets core_run; the core then runs, but the encoder is off
	# and not a single byte flows -- trace_bytes stays 0, which reads like
	# "pressed Run, nothing happened". Measured on mbv: with trace_on first,
	# 2,092,346 beats / 8,369,416 bytes in four seconds; without it, 0/0.
	api_post /api/ctl '{"action":"trace_on"}' >/dev/null
	say "  [6a] trace_on     : encoder switched on"

	# 6b. run
	api_post /api/ctl '{"action":"run"}' >/dev/null
	say "  [6b] run          : issued"
	sleep 4

	# 7. counters during/after the run
	local st b1 beats
	st="$(api_get /api/state)"
	b1="$(printf '%s' "$st" | jget trace_bytes)"
	beats="$(printf '%s' "$st" | jget trace_beats)"
	say "  [7] after 4 s     : trace_bytes=${b1:-?} trace_beats=${beats:-?}"

	# 8. stop
	api_post /api/ctl '{"action":"stop"}' >/dev/null
	say "  [8] stop          : issued"

	# 9. read memory/trace -- the 'look at the memory' part
	local dump; dump="$(api_get "/api/dump?n=64" | head -c 160)"
	say "  [9] memory        : ${dump:0:150}"

	# 10. fetch the trace and have it decoded (server side, like the UI)
	local dec; dec="$(api_get "/api/decode?limit=200" | head -c 200)"
	say "  [10] decode       : ${dec:0:190}"

	# 11. record the board state: temperature/power are the cheapest evidence
	# that a verdict was produced under normal conditions -- and the number
	# that settles any "it just needs to cool down" claim.
	local sens; sens="$(api_get /api/sensors)"
	say "  [11] board        : $(printf '%s' "$sens" | py -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: print('n/a'); raise SystemExit
print('PL %s C  PS %s C  fan %s%%  %s W' % (d.get('temp_pl_c'), d.get('temp_ps_c'), d.get('fan_percent'), d.get('power_w')))")"

	# Verdict: bytes must have flowed.
	if [ -n "${b1:-}" ] && [ "${b1:-0}" -gt "${b0:-0}" ] 2>/dev/null; then
		say "  VERDICT $sc: PASS (trace_bytes $b0 -> $b1)"
	else
		say "  VERDICT $sc: FAIL (trace_bytes $b0 -> ${b1:-?}, no progress)"
		rc=1
	fi
	return $rc
}

want="$*"
[ -z "$want" ] && want="$SCEN_ALL"

say "board_demo_walkthrough $STAMP  board=$BOARD jump=$JUMP port=$PORT"
say "scenarios: $want"

overall=0
summary=""
for sc in $want; do
	if demo_one "$sc"; then summary="$summary
  PASS  $sc"; else summary="$summary
  FAIL  $sc"; overall=1; fi
done

say ""
say "================ walkthrough summary ================"
say "$summary"
[ $overall -eq 0 ] && say "RESULT: all demos PASS" || say "RESULT: at least one demo without PASS"
say "log: $LOG"
exit $overall
