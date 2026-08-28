#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Red cross-checks for the MDO/MSEO gate. This stage has no historical
# defect commit, so falsifiability is demonstrated by MUTATION: three
# build-local single-line defects, each of which must turn its designated
# property red (the unmutated build is green — see run.sh tasks).
#   M1 wrong EOM code      : dual-pin EOM emits 01 instead of 11
#                            -> A_mseo_eom (P-MDO-2) must fail
#   M2 missing full gate   : packer accepts slices while the seam is full
#                            -> A_sink_occ/A_sink_gate (P-MDO-4) must fail
#   M3 suppressed EOM      : slicer never raises end_of_message
#                            -> A_live_eom (bounded completion) must fail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_mut () { # $1 name, $2 MUTATE_FILE, $3 perl expr, $4 sby task
	local name="$1" file="$2" expr="$3" task="$4"
	echo "== red mutation $name (expect FAIL on task $task)"
	if MUTATE_FILE="$file" MUTATE="$expr" bash "$SCRIPT_DIR/run.sh" "$task" \
		> "$SCRIPT_DIR/build/red_$name.log" 2>&1; then
		echo "ERROR: mutation $name PASSED — property does not see the defect."
		exit 1
	fi
	if ! grep -q "DONE (FAIL" "$SCRIPT_DIR/build/red_$name.log"; then
		echo "ERROR: mutation $name ended without a proper FAIL (tool error?):"
		tail -5 "$SCRIPT_DIR/build/red_$name.log"
		exit 1
	fi
	grep -E "failed assertion|Assert failed" "$SCRIPT_DIR/build/red_$name.log" | head -1
}

run_mut M1_eom_code mseo \
	's/(end_of_message\) begin\s*mseo_bits = )2.b11/${1}2\x27b01/s' \
	bmc

run_mut M2_full_gate packer \
	's/assign slice_ready = !atb_full && /assign slice_ready = /' \
	bmc

run_mut M3_eom_suppressed slicer \
	's/PipeEndOfMessage\s*<= no_more_fields && acc_end_f;/PipeEndOfMessage      <= 1\x27b0;/' \
	live

echo "RED MUTATION CROSS-CHECKS OK (3/3 red where they must be)."
