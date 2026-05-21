#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Post-simulation trace-off check.
#
# Locates the test's xsim CWD under bld/, runs NexRv on the ATB binary,
# and asserts the encoder emitted a Program Trace Correlation Message
# (TCODE 33) with EVCODE = Program Trace Disabled (0x4) when instruction
# tracing was turned off (trTeControl.Enable 1->0), per IEEE-ISTO 5001
# §4.3.16. This is the message that flushes the residual instruction
# count + branch history so a decoder can resolve the final instructions
# up to the trace-off point.
#
# Usage:  decode_and_check_disabled.sh <test_name>

set -euo pipefail

test_name="${1:?usage: $0 <test_name>}"

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
nexrv="$repo_root/bin/NexRv"

atb_bin="$(find "$repo_root/bld" -name "${test_name}.atb.bin" -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "$atb_bin" ]; then
    echo "[decode-off] ERROR: no ${test_name}.atb.bin found under bld/"
    exit 2
fi
sim_dir="$(dirname "$atb_bin")"

atb_bin="$sim_dir/${test_name}.atb.bin"
pcinfo="$sim_dir/${test_name}.nexrv.info"
log="$sim_dir/${test_name}.nexrv-off.log"

for f in "$atb_bin" "$pcinfo"; do
    if [ ! -s "$f" ]; then
        echo "[decode-off] ERROR: missing or empty: $f"
        exit 2
    fi
done

echo "[decode-off] $test_name: running NexRv -deco -full"
"$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" \
    -pcout "$sim_dir/${test_name}.decoded.pcout" -full \
    > "$log" 2>&1 || true   # a non-zero NexRv exit is fine; we only inspect the log

# A trace-disabled correlation message decodes as:
#   TCODE[6]=33 ... - ProgTraceCorrelation
#   EVCODE[4]=0x4 CDF[2]=0x...
n_corr=$(grep -cE 'TCODE\[6\]=33 .*ProgTraceCorrelation' "$log" || true)
n_disabled=$(grep -cE 'EVCODE\[4\]=0x4' "$log" || true)
echo "[decode-off] $test_name: $n_corr ProgTraceCorrelation msg(s), $n_disabled with EVCODE=Program Trace Disabled"

if [ "$n_corr" -lt 1 ] || [ "$n_disabled" -lt 1 ]; then
    echo "[decode-off] $test_name: FAIL — no Program Trace Disabled correlation"
    echo "             message emitted on trace-off (Enable=0)."
    grep -nE 'TCODE\[6\]=[0-9]+' "$log" | tail -10 || true
    exit 1
fi

echo "[decode-off] $test_name: PASS — trace-off emits ProgTraceCorrelation(EVCODE=Program Trace Disabled)"
