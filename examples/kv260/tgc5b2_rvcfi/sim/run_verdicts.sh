#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# run_verdicts.sh -- judge every simulated mode with the REAL analyser and
# print the verdict table the tutorial's section 9 quotes.
#
# This exists so that "the five verdicts" is one command instead of five
# hand-typed ones, and so the expected-monitor check is mechanical: each mode
# has a claim about WHICH monitor must fire (or that none may), and a demo
# whose claims are checked by a human reading scrollback will drift.
#
#   bash sim/run_verdicts.sh            # after the e2e legs have run
#
# Exit code: 0 only if every mode matches its claim.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ex="$(cd "$here/.." && pwd)"
repo="$(cd "$ex/../../.." && pwd)"
R="$ex/board/rvmon/rvmon"
M="$ex/sw"
B="$repo/bld"

if [ ! -x "$R" ]; then
	echo "run_verdicts: build rvmon first (cd board/rvmon && make)" >&2
	exit 2
fi

overall=0

judge() {  # leg  claim  description
	local leg="$1" claim="$2" desc="$3"
	local d="$B/tb_rvcfi_e2e_${leg}.vsim"
	local out verdict
	if [ ! -f "$d/rvcfi_e2e_${leg}_core0.hex" ]; then
		printf '%-6s MISSING (leg not run)\n' "$leg"
		overall=1
		return
	fi
	out=$("$R" analyze \
		--in0 "$d/rvcfi_e2e_${leg}_core0.hex" --in1 "$d/rvcfi_e2e_${leg}_core1.hex" \
		--map0 "$M/sites_core0.csv" --map1 "$M/sites_core1.csv" \
		--seed 0x1234 2>&1)
	verdict=$(printf '%s\n' "$out" | grep -E '^VERDICT' | head -1)
	local mons
	mons=$(printf '%s\n' "$out" | grep -oE '^\[mon_[a-z]+\]' | sort -u | tr -d '[]' | paste -sd+ -)
	local ok="FAIL"
	case "$claim" in
		clean)      [ "${verdict#VERDICT: CLEAN}" != "$verdict" ] && ok="ok" ;;
		*)          # claim = monitor that MUST appear
			if printf '%s' "$mons" | grep -q "$claim" \
			   && [ "${verdict#VERDICT: INCONCLUSIVE}" = "$verdict" ]; then
				ok="ok"
			fi ;;
	esac
	[ "$ok" = ok ] || overall=1
	printf '%-6s %-4s %-45s %s [%s]\n' "$leg" "$ok" "$verdict" "$desc" "${mons:-none}"
}

echo "mode   ok   verdict                                       claim [monitors that fired]"
judge m0  clean       "correct locking: the detector must stay silent"
judge m1  mon_lockset "open race: lockset (and friends) must fire"
judge m2  mon_lockset "wrong lock: lockset must fire on runtime tags"
judge m3  mon_order   "lock order: the order graph must be cyclic"
judge m4  mon_cfg     "corrupted dispatch: forward-edge CFI"
judge cap clean       "software instrumentation on, still clean"
judge ddr clean       "m0 through the DDR ring: transport-invisible"

if [ "$overall" = 0 ]; then
	echo "VERDICTS_OK"
else
	echo "VERDICTS_FAILED"
fi
exit $overall
