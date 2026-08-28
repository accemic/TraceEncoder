#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# run_board_verdicts.sh -- the silicon twin of sim/run_verdicts.sh.
#
# Runs ON THE BOARD, from the staging directory deploy.sh created:
#
#   cd /tmp/rvcfi && sudo bash run_board_verdicts.sh
#
# For every mode it loads the programs and the full watchpoint tables, runs
# the paced workload, keeps the record files (board_<leg>_coreN.bin), runs
# the analyser on them, and judges the SAME claim table the simulation is
# judged by. The point is symmetry: "the five verdicts" is one command in
# simulation and one command on silicon, and the two tables must agree --
# a claim checked by a human reading scrollback would drift.
#
# Additional silicon-only gate: the paced run must lose nothing. `rvmon run`
# prints the shim drop counters (N2's loss accounting); any nonzero value
# fails the leg even if the verdict text matches.
#
# Exit code: 0 only if every mode matches its claim AND no records were lost.

set -uo pipefail
cd "$(dirname "$0")"

R=./rvmon
[ -x "$R" ] || { echo "run_board_verdicts: no ./rvmon here -- run deploy.sh first" >&2; exit 2; }

overall=0

leg() {  # name  mode  extra-run-args  claim  description
	local name="$1" mode="$2" extra="$3" claim="$4" desc="$5"
	local runlog out verdict mons drops ok="FAIL"

	$R load --hex0 rvcfi_core0.hex --hex1 rvcfi_core1.hex \
	        --wp0 wp_table_core0_full.txt --wp1 wp_table_core1_full.txt \
	        --mode "$mode" >/dev/null || { printf '%-6s LOAD_FAILED\n' "$name"; overall=1; return; }

	# shellcheck disable=SC2086 -- $extra is a deliberate word list
	runlog=$($R run --mode "$mode" $extra \
	         --out0 "board_${name}_core0.bin" --out1 "board_${name}_core1.bin" 2>&1) \
		|| { printf '%-6s RUN_FAILED: %s\n' "$name" "$(tail -1 <<<"$runlog")"; overall=1; return; }

	drops=$(grep -oE 'shim drops: core0=[0-9]+ core1=[0-9]+' <<<"$runlog" | tail -1)

	out=$($R analyze \
		--in0 "board_${name}_core0.bin" --in1 "board_${name}_core1.bin" \
		--map0 sites_core0.csv --map1 sites_core1.csv --seed 0x1234 2>&1)
	verdict=$(grep -E '^VERDICT' <<<"$out" | head -1)
	mons=$(grep -oE '^\[mon_[a-z]+\]' <<<"$out" | sort -u | tr -d '[]' | paste -sd+ -)

	case "$claim" in
		clean) [ "${verdict#VERDICT: CLEAN}" != "$verdict" ] && ok="ok" ;;
		*)     if grep -q "$claim" <<<"${mons:-}" \
		          && [ "${verdict#VERDICT: INCONCLUSIVE}" = "$verdict" ]; then
			       ok="ok"
		       fi ;;
	esac
	# The throttled run must be loss-free -- N2's counters are the evidence.
	if ! grep -q 'core0=0 core1=0' <<<"${drops:-}"; then
		ok="FAIL(drops)"
	fi
	[ "$ok" = ok ] || overall=1
	printf '%-6s %-4s %-45s %s [%s] {%s}\n' \
		"$name" "$ok" "$verdict" "$desc" "${mons:-none}" "${drops:-no drop line}"
}

# --iters 60 --pace 0 mirrors the simulation legs (tb_rvcfi_e2e ITERS/PACE)
# exactly: same workload, same expected record counts, and a total that fits
# the loss-free burst window. The 2000-iteration default is a THROUGHPUT
# experiment, not a verdict leg -- at full tilt the cores outrun the
# /dev/mem drain by design, and the tutorial's chapter 10 uses precisely
# that run to show the loss counters doing their job.
SIM="--iters 60 --pace 0"
echo "mode   ok   verdict                                       claim [monitors] {loss}"
leg m0  0 "$SIM"               clean       "correct locking: the detector must stay silent"
leg m1  1 "$SIM"               mon_lockset "open race: lockset (and friends) must fire"
leg m2  2 "$SIM"               mon_lockset "wrong lock: lockset must fire on runtime tags"
leg m3  3 "$SIM"               mon_order   "lock order: the order graph must be cyclic"
leg m4  4 "$SIM"               mon_cfg     "corrupted dispatch: forward-edge CFI"
leg cap 0 "$SIM --cap-every 4" clean       "software instrumentation on, still clean"

# The same six claims through the DDR fast lane (section 10c): the record
# transport must be invisible to every verdict. `--route ddr` also proves
# the N3 order contract and the ring counters on silicon; rvmon itself
# fails a leg on any ring drop delta, axi_err or cfg_rej.
echo "--- same claims, DDR ring transport ---"
leg m0d  0 "$SIM --route ddr"               clean       "m0 through the ring: still silent"
leg m1d  1 "$SIM --route ddr"               mon_lockset "m1 through the ring: lockset still fires"
leg m2d  2 "$SIM --route ddr"               mon_lockset "m2 through the ring: runtime tags intact"
leg m3d  3 "$SIM --route ddr"               mon_order   "m3 through the ring: order cycle found"
leg m4d  4 "$SIM --route ddr"               mon_cfg     "m4 through the ring: CFI hits found"
leg capd 0 "$SIM --route ddr --cap-every 4" clean       "cap through the ring: still clean"

if [ "$overall" = 0 ]; then
	echo "BOARD_VERDICTS_OK"
else
	echo "BOARD_VERDICTS_FAILED"
fi
exit $overall
