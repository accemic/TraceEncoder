#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Collect the MEASURED eTIP slot demand from the simulation logs.
#
# The composer prints one watermark line per simulation run
#
#   *** INFO (<scope>): eTIP max slots per beat = <n> of ETIP_PAR_MSG=<p>
#
# (MaxSlotsSim, ct_L23_preproc_composer_etip.sv). This script turns the
# xsim logs left behind in bld/ into the histogram that
# doc/integration.adoc#p4-cost quotes, so the number in the documentation
# has a command behind it instead of a memory (P4 re-audit finding B-5).
#
#   usage: scripts/collect_slot_watermarks.sh [<log root>]
#          <log root> defaults to bld/
#
# NOTE what this does and does not say: the histogram is a MEASUREMENT over
# whatever runs happen to be in the tree -- it is a lower bound on the
# demand, never a proof of the ETIP_PAR_MSG bound. The bound itself is
# proven by formal/composer_slots (P-SLOT-1) and checked at run time by the
# immediate assertion a_p4_slot_bound.
set -euo pipefail

ROOT="${1:-bld}"

if [ ! -d "$ROOT" ]; then
	echo "ERROR: log root '$ROOT' does not exist" >&2
	exit 2
fi

mapfile -t LOGS < <(find "$ROOT" -name 'xsim*.log' -type f | sort)
if [ "${#LOGS[@]}" -eq 0 ]; then
	echo "no xsim*.log under '$ROOT' -- run the simulation gates first" >&2
	exit 1
fi

HITS=$(grep -h "eTIP max slots per beat" "${LOGS[@]}" 2>/dev/null || true)
NRUNS=$(printf '%s\n' "$HITS" | grep -c "eTIP max slots per beat" || true)
NLOGS=$(printf '%s\n' "$HITS" | wc -l)

echo "log root      : $ROOT"
echo "xsim logs     : ${#LOGS[@]}"
echo "watermark runs: $NRUNS"
echo
echo "demand histogram (measured maximum per simulation run):"
printf '%s\n' "$HITS" \
	| grep -o "= [0-9]* of ETIP_PAR_MSG=[0-9]*" \
	| sort | uniq -c
echo
MAX=$(printf '%s\n' "$HITS" | grep -o "beat = [0-9]*" | grep -o "[0-9]*" | sort -n | tail -1)
echo "measured maximum over all runs: ${MAX:-n/a}"
