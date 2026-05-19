#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Post-simulation data-trace verification.
#
# Locates the test's xsim CWD under bld/, runs `NexRv -deco -msg` on
# the ATB binary, parses the per-message log for DataRead / DataWrite
# entries, and diffs the resulting sequence against the cpu_model-
# emitted `.expected.data` file.
#
# Usage:  decode_and_check_data.sh [--soft] <test_name>

set -euo pipefail

mode="strict"
if [ "${1:-}" = "--soft" ]; then
    mode="soft"
    shift
fi

test_name="${1:?usage: $0 [--soft] <test_name>}"

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
nexrv="$repo_root/bin/NexRv"

sim_dir="$repo_root/bld/${test_name}.abc.vivado/${test_name}.abc.sim/sim_1/behav/xsim"
if [ ! -d "$sim_dir" ]; then
    echo "[decode-data] ERROR: simulation dir not found: $sim_dir"
    exit 2
fi

atb_bin="$sim_dir/${test_name}.atb.bin"
pcinfo="$sim_dir/${test_name}.nexrv.info"
expected="$sim_dir/${test_name}.expected.data"
decoded="$sim_dir/${test_name}.decoded.data"
log="$sim_dir/${test_name}.nexrv-data.log"

for f in "$atb_bin" "$pcinfo" "$expected"; do
    if [ ! -s "$f" ]; then
        echo "[decode-data] ERROR: missing or empty: $f"
        exit 2
    fi
done

echo "[decode-data] $test_name: running NexRv -deco -full"
# -full gives the per-byte decode including DSZ / DADDR / DATA fields
# that the awk parser below needs. A dummy pcout path keeps NexRv
# happy even with no instruction trace; we only care about the
# per-message log on stderr/stdout.
"$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" \
    -pcout "$sim_dir/${test_name}.decoded.pcout" -full \
    > "$log" 2>&1 || true   # exit non-zero is OK when there's no inst trace

# Parse NexRv per-message log into LOAD/STORE,0x<addr>,<size_bytes>
awk '
    /TCODE\[6\]=6 .*DataRead/  { kind = "LOAD";  next }
    /TCODE\[6\]=5 .*DataWrite/ { kind = "STORE"; next }
    /DSZ\[/ {
        if (match($0, /=0x[0-9a-fA-F]+/)) {
            size = strtonum(substr($0, RSTART+1, RLENGTH-1))
        }
        next
    }
    /DADDR\[/ {
        if (kind != "" && match($0, /=0x[0-9a-fA-F]+/)) {
            addr = strtonum(substr($0, RSTART+1, RLENGTH-1))
            # zero-pad address to 8 hex digits for consistent diff
            printf "%s,0x%08x,%d\n", kind, addr, size
            kind = ""
        }
    }
' "$log" > "$decoded"

n_exp=$(wc -l < "$expected")
n_got=$(wc -l < "$decoded")
echo "[decode-data] $test_name: expected $n_exp data events, decoded $n_got"

if [ "$n_got" -eq 0 ]; then
    echo "[decode-data] $test_name: FAIL — NexRv produced no data messages"
    tail -5 "$log"
    [ "$mode" = "soft" ] || exit 1
    exit 0
fi

if ! diff -q "$expected" "$decoded" > /dev/null; then
    if [ "$mode" = "soft" ]; then
        echo "[decode-data] $test_name: WARN — data sequence diverges (soft mode)"
    else
        echo "[decode-data] $test_name: FAIL — data sequence does not match"
    fi
    diff -u --label expected --label decoded "$expected" "$decoded" | head -30 || true
    [ "$mode" = "soft" ] || exit 1
    exit 0
fi

echo "[decode-data] $test_name: PASS — all $n_exp data events match"
