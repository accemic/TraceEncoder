#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Post-simulation synchronization-message count check.
#
# Locates the test's xsim CWD under bld/, runs NexRv on the ATB binary,
# and counts the synchronization messages in the decode (ProgTraceSync
# and the *Sync TCODE variants). Asserts the count is at least <min>.
#
# Used by the ACT-CAP CF_SYNC gate (tests/hsi/02_csr_sync_xfail). With
# periodic sync OFF and a flush-only drain there is exactly ONE
# synchronization message in the trace (the startup ProgTraceSync). A
# working ACT_CAP_ST_CF_SYNC command must add a second one, so the gate
# requires >= 2. Until CF_SYNC is implemented this check FAILS by
# design (it is a pending-feature / xfail gate, run from its own
# non-gating Makefile target).
#
# Usage:  decode_and_check_sync.sh <test_name> [min_sync_msgs]
#         (min_sync_msgs defaults to 2)

set -euo pipefail

test_name="${1:?usage: $0 <test_name> [min_sync_msgs]}"
min_sync="${2:-2}"

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
nexrv="$repo_root/bin/NexRv"

atb_bin="$(find "$repo_root/bld" -name "${test_name}.atb.bin" -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "$atb_bin" ]; then
    echo "[decode-sync] ERROR: no ${test_name}.atb.bin found under bld/"
    exit 2
fi
sim_dir="$(dirname "$atb_bin")"

atb_bin="$sim_dir/${test_name}.atb.bin"
pcinfo="$sim_dir/${test_name}.nexrv.info"
log="$sim_dir/${test_name}.nexrv-sync.log"

for f in "$atb_bin" "$pcinfo"; do
    if [ ! -s "$f" ]; then
        echo "[decode-sync] ERROR: missing or empty: $f"
        exit 2
    fi
done

echo "[decode-sync] $test_name: running NexRv -deco -full"
"$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" \
    -pcout "$sim_dir/${test_name}.decoded.pcout" -full \
    > "$log" 2>&1 || true   # a non-zero NexRv exit is fine; we only count syncs

# Count synchronization messages. NexRv prints one header line per
# message, e.g. "TCODE[6]=9 (MSG #0) - ProgTraceSync". All synchronizing
# message variants carry a "...Sync" label (ProgTraceSync,
# DirectBranchSync, IndirectBranchSync, IndirectBranchHistSync,
# RepeatInstructionSync); plain messages (IndirectBranchHist, DataRead,
# DataAcquisition, ...) do not.
sync_count=$(grep -cE 'TCODE\[6\]=[0-9]+.*Sync' "$log" || true)
echo "[decode-sync] $test_name: $sync_count synchronization message(s) decoded (need >= $min_sync)"

if [ "$sync_count" -lt "$min_sync" ]; then
    echo "[decode-sync] $test_name: FAIL — only $sync_count sync message(s);"
    echo "              ACT_CAP_ST_CF_SYNC did not emit an instruction-sync"
    echo "              message (feature not implemented — expected XFAIL)."
    grep -nE 'TCODE\[6\]=[0-9]+' "$log" | head -20 || true
    exit 1
fi

echo "[decode-sync] $test_name: PASS — $sync_count sync messages (>= $min_sync)"
