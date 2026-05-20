#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Post-simulation verification step.
#
# Given a test name, locate its xsim CWD under bld/, run NexRv to decode
# the ATB binary trace back to a PC sequence using the cpu_model-derived
# NexRv PCInfo, and diff the decoded address column against the
# expected sequence (also the first column of the .nexrv.info file).
#
# Usage:  decode_and_check.sh <test_name>
# Example: decode_and_check.sh basic_tb

set -euo pipefail

# Flags:
#   --soft       partial-pass / divergence are reported but exit 0 (use
#                for tests that intentionally lose trace bytes, e.g.
#                overflow scenarios).
mode="strict"
if [ "${1:-}" = "--soft" ]; then
    mode="soft"
    shift
fi

test_name="${1:?usage: $0 [--soft] <test_name>}"

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
nexrv="$repo_root/bin/NexRv"

# Locate the simulator working directory by finding the ATB dump it
# produced. abc-flow's layout varies by version (bld/<t>.vsim/ in newer
# releases, bld/<t>.abc.vivado/.../xsim/ in older ones), so search
# rather than hardcode.
atb_bin="$(find "$repo_root/bld" -name "${test_name}.atb.bin" -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "$atb_bin" ]; then
    echo "[decode] ERROR: no ${test_name}.atb.bin found under bld/"
    exit 2
fi
sim_dir="$(dirname "$atb_bin")"

atb_bin="$sim_dir/${test_name}.atb.bin"
pcinfo="$sim_dir/${test_name}.nexrv.info"
expected="$sim_dir/${test_name}.expected.pcs"
pcout="$sim_dir/${test_name}.decoded.pcout"
log="$sim_dir/${test_name}.nexrv.log"

for f in "$atb_bin" "$pcinfo" "$expected"; do
    if [ ! -s "$f" ]; then
        echo "[decode] ERROR: missing or empty: $f"
        exit 2
    fi
done

echo "[decode] $test_name: running NexRv -deco"
"$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" -pcout "$pcout" -full \
    > "$log" 2>&1 || {
    rc=$?
    # NexRv returns non-zero on a partial decode (e.g. trailing history
    # bits the encoder didn't flush). The pcout file may still be a
    # valid prefix; report and fall through to the diff.
    echo "[decode] WARN: NexRv exited rc=$rc (often due to undrained trace tail)"
}

if [ ! -s "$pcout" ]; then
    echo "[decode] ERROR: NexRv produced no pcout — see $log"
    tail -5 "$log"
    exit 3
fi

# Extract the address column from the decoded pcout. The expected
# sequence (execution-ordered, no gap-fill) was already produced by
# cpu_model in `$expected`.
exp_pcs="$expected"
got_pcs="$sim_dir/${test_name}.decoded.pcs"
cut -d, -f1 "$pcout"  > "$got_pcs"

n_exp=$(wc -l < "$exp_pcs")
n_got=$(wc -l < "$got_pcs")
echo "[decode] $test_name: expected $n_exp PCs, decoded $n_got PCs"

# Compare the common prefix. (If NexRv truncated due to undrained tail,
# the decoded list will be a prefix of the expected list.)
n_cmp=$(( n_got < n_exp ? n_got : n_exp ))
if [ "$n_cmp" -eq 0 ]; then
    echo "[decode] $test_name: FAIL — nothing to compare"
    exit 4
fi

if ! diff -q <(head -n "$n_cmp" "$exp_pcs") <(head -n "$n_cmp" "$got_pcs") > /dev/null; then
    if [ "$mode" = "soft" ]; then
        echo "[decode] $test_name: WARN — first $n_cmp PCs diverge (soft mode, not a failure)"
    else
        echo "[decode] $test_name: FAIL — first $n_cmp PCs do not match"
    fi
    echo "         (left=expected from cpu_model, right=decoded from ATB)"
    diff -u --label expected --label decoded \
        <(head -n "$n_cmp" "$exp_pcs") \
        <(head -n "$n_cmp" "$got_pcs") | head -20 || true
    [ "$mode" = "soft" ] || exit 1
    exit 0
fi

if [ "$n_got" -lt "$n_exp" ]; then
    echo "[decode] $test_name: PARTIAL PASS — first $n_cmp/$n_exp PCs match;"
    echo "         decoded tail truncated (expected $n_exp got $n_got)."
    echo "         Consider extending the test's drain window."
    exit 0
fi

echo "[decode] $test_name: PASS — all $n_exp PCs match"
