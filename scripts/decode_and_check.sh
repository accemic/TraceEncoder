#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Unified post-simulation NexRv decode check.
#
# Locates the test's xsim CWD under bld/, decodes the ATB binary trace ONCE
# with the NexRv reference decoder, then runs whichever checks are requested
# against that single decode:
#
#   --pc          decoded PC stream EXACTLY matches <test>.expected.pcs
#                 (strict full match by default; a divergent prefix or a short
#                 decode — stopped early — fails; use --soft to allow it)
#   --data        decoded DataRead/DataWrite sequence matches <test>.expected.data
#   --ctxp        NexRv's CTXP export (C-Trace eXPort: SYNC / BRANCH_* / CALL /
#                 RETURN / MEMREAD_n / MEMWRITE_n / DAQ_* records) matches
#                 <test>.expected.ctxp, normalized for the trailing "@ <cycle>"
#                 and hex leading zeros. This is the value-aware data/DAQ check
#                 (it compares the captured data values, not just addr+size).
#   --sync N      at least N synchronization messages present
#   --disabled    a trace-off Program Trace Correlation Message
#                 (TCODE 33, EVCODE=Program Trace Disabled) is present
#   --soft        PC / data / ctxp divergence is reported as WARN, not a failure
#                 (for tests that intentionally lose trace bytes, e.g. overflow)
#
# If no check flag is given, --pc is assumed. Exit status is non-zero iff a
# requested (non-soft) check fails.
#
# Usage:  decode_and_check.sh [--soft] [--pc] [--data] [--ctxp] [--sync N] [--disabled] <test_name>

set -euo pipefail

soft=0; do_pc=0; do_data=0; do_ctxp=0; do_disabled=0; sync_min=""
test_name=""
while [ $# -gt 0 ]; do
    case "$1" in
        --soft)     soft=1;        shift;;
        --pc)       do_pc=1;       shift;;
        --data)     do_data=1;     shift;;
        --ctxp)     do_ctxp=1;     shift;;
        --disabled) do_disabled=1; shift;;
        --sync)     sync_min="${2:?--sync needs a count}"; shift 2;;
        --*)        echo "[decode] ERROR: unknown option $1"; exit 2;;
        *)          test_name="$1"; shift;;
    esac
done
: "${test_name:?usage: $0 [--soft] [--pc] [--data] [--ctxp] [--sync N] [--disabled] <test_name>}"

# Default to the PC check when none was requested.
if [ "$do_pc" -eq 0 ] && [ "$do_data" -eq 0 ] && [ "$do_ctxp" -eq 0 ] && [ "$do_disabled" -eq 0 ] && [ -z "$sync_min" ]; then
    do_pc=1
fi

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
nexrv="$repo_root/bin/NexRv"

# Locate the simulator working directory by finding the ATB dump it produced.
# abc-flow's layout varies by version (bld/<t>.vsim/ in newer releases,
# bld/<t>.abc.vivado/.../xsim/ in older ones), so search rather than hardcode.
atb_bin="$(find "$repo_root/bld" -name "${test_name}.atb.bin" -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "$atb_bin" ]; then
    echo "[decode] ERROR: no ${test_name}.atb.bin found under bld/"
    exit 2
fi
sim_dir="$(dirname "$atb_bin")"

atb_bin="$sim_dir/${test_name}.atb.bin"
pcinfo="$sim_dir/${test_name}.nexrv.info"
pcout="$sim_dir/${test_name}.decoded.pcout"
log="$sim_dir/${test_name}.nexrv.log"

for f in "$atb_bin" "$pcinfo"; do
    if [ ! -s "$f" ]; then
        echo "[decode] ERROR: missing or empty: $f"
        exit 2
    fi
done

# ------------------------------------------------------------------
# Single NexRv decode shared by every check below.
# -full gives the per-message field detail the data/sync/disabled greps
# need; -pcout gives the reconstructed PC stream the --pc check diffs.
# A non-zero NexRv exit is tolerated (e.g. an undrained trace tail, or no
# instruction trace at all); the individual checks judge the output.
# ------------------------------------------------------------------
echo "[decode] $test_name: running NexRv -deco -full"
"$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" -pcout "$pcout" -full > "$log" 2>&1 || {
    rc=$?
    echo "[decode] WARN: NexRv exited rc=$rc (often an undrained trace tail / no inst trace)"
}

fail=0

# ------------------------------------------------------------------
# --pc : decoded PC stream vs expected.pcs
# ------------------------------------------------------------------
if [ "$do_pc" -eq 1 ]; then
    exp_pcs="$sim_dir/${test_name}.expected.pcs"
    got_pcs="$sim_dir/${test_name}.decoded.pcs"
    if [ ! -s "$exp_pcs" ]; then
        echo "[decode-pc] $test_name: ERROR — missing or empty: $exp_pcs"; fail=1
    elif [ ! -s "$pcout" ]; then
        echo "[decode-pc] $test_name: FAIL — NexRv produced no pcout (see $log)"; tail -5 "$log"; fail=1
    else
        cut -d, -f1 "$pcout" > "$got_pcs"
        n_exp=$(wc -l < "$exp_pcs")
        n_got=$(wc -l < "$got_pcs")
        n_cmp=$(( n_got < n_exp ? n_got : n_exp ))
        echo "[decode-pc] $test_name: expected $n_exp PCs, decoded $n_got PCs"
        # Strict by default: the decoded stream must EXACTLY equal the expected
        # one. A divergent prefix, or a short decode (the stream stopped early —
        # e.g. an undrained tail or a mid-stream decoder error), is a failure.
        # --soft downgrades any mismatch to a WARN (for tests that intentionally
        # lose trace bytes, e.g. overflow).
        pc_msg=""
        if [ "$n_cmp" -eq 0 ]; then
            pc_msg="nothing decoded"
        elif ! diff -q <(head -n "$n_cmp" "$exp_pcs") <(head -n "$n_cmp" "$got_pcs") > /dev/null; then
            pc_msg="first $n_cmp PCs diverge"
        elif [ "$n_got" -ne "$n_exp" ]; then
            pc_msg="prefix matches but stream is incomplete ($n_got of $n_exp PCs)"
        fi
        if [ -z "$pc_msg" ]; then
            echo "[decode-pc] $test_name: PASS — all $n_exp PCs match"
        else
            if [ "$soft" -eq 1 ]; then
                echo "[decode-pc] $test_name: WARN — $pc_msg (soft mode, not a failure)"
            else
                echo "[decode-pc] $test_name: FAIL — $pc_msg"
                fail=1
            fi
            if [ "$n_cmp" -gt 0 ]; then
                diff -u --label expected --label decoded \
                    <(head -n "$n_cmp" "$exp_pcs") <(head -n "$n_cmp" "$got_pcs") | head -20 || true
            fi
        fi
    fi
fi

# ------------------------------------------------------------------
# --data : decoded DataRead/DataWrite sequence vs expected.data
# ------------------------------------------------------------------
if [ "$do_data" -eq 1 ]; then
    exp_data="$sim_dir/${test_name}.expected.data"
    got_data="$sim_dir/${test_name}.decoded.data"
    if [ ! -s "$exp_data" ]; then
        echo "[decode-data] $test_name: ERROR — missing or empty: $exp_data"; fail=1
    else
        awk '
            /TCODE\[6\]=6 .*DataRead/  { kind = "LOAD";  next }
            /TCODE\[6\]=5 .*DataWrite/ { kind = "STORE"; next }
            /DSZ\[/ {
                if (match($0, /=0x[0-9a-fA-F]+/)) { size = strtonum(substr($0, RSTART+1, RLENGTH-1)) }
                next
            }
            /DADDR\[/ {
                if (kind != "" && match($0, /=0x[0-9a-fA-F]+/)) {
                    addr = strtonum(substr($0, RSTART+1, RLENGTH-1))
                    printf "%s,0x%08x,%d\n", kind, addr, size
                    kind = ""
                }
            }
        ' "$log" > "$got_data"
        n_exp=$(wc -l < "$exp_data")
        n_got=$(wc -l < "$got_data")
        echo "[decode-data] $test_name: expected $n_exp data events, decoded $n_got"
        if [ "$n_got" -eq 0 ]; then
            echo "[decode-data] $test_name: $([ "$soft" -eq 1 ] && echo WARN || echo FAIL) — NexRv produced no data messages"
            [ "$soft" -eq 1 ] || fail=1
        elif ! diff -q "$exp_data" "$got_data" > /dev/null; then
            if [ "$soft" -eq 1 ]; then
                echo "[decode-data] $test_name: WARN — data sequence diverges (soft mode)"
            else
                echo "[decode-data] $test_name: FAIL — data sequence does not match"; fail=1
            fi
            diff -u --label expected --label decoded "$exp_data" "$got_data" | head -30 || true
        else
            echo "[decode-data] $test_name: PASS — all $n_exp data events match"
        fi
    fi
fi

# ------------------------------------------------------------------
# --ctxp : NexRv CTXP export vs expected.ctxp (normalized)
# NexRv writes the CTXP text export when CTXP_TEXT_TRACEFILE is set (with
# -none). We normalize both files — drop the HDR/META header, strip the
# trailing "@ <cycle>", lowercase, and strip hex leading zeros — then diff.
# ------------------------------------------------------------------
if [ "$do_ctxp" -eq 1 ]; then
    exp_ctxp="$sim_dir/${test_name}.expected.ctxp"
    got_ctxp="$sim_dir/${test_name}.decoded.ctxp.txt"
    ctxp_log="$sim_dir/${test_name}.ctxp.log"
    if [ ! -s "$exp_ctxp" ]; then
        echo "[decode-ctxp] $test_name: ERROR — missing or empty: $exp_ctxp"; fail=1
    else
        CTXP_TEXT_TRACEFILE="$got_ctxp" "$nexrv" -deco "$atb_bin" -pcinfo "$pcinfo" \
            -pcout "$pcout" -none > "$ctxp_log" 2>&1 || true
        if [ ! -s "$got_ctxp" ]; then
            echo "[decode-ctxp] $test_name: FAIL — NexRv produced no CTXP export (see $ctxp_log)"
            tail -5 "$ctxp_log" || true; fail=1
        else
            # Canonicalize: drop header, strip "@ <cycle>", lowercase, strip 0x leading zeros.
            ctxp_norm() {
                grep -vE '^(HDR|META):' "$1" \
                    | sed -E 's/[[:space:]]*@[[:space:]]*[0-9]+[[:space:]]*$//' \
                    | tr 'A-F' 'a-f' \
                    | sed -E 's/0x0*([0-9a-f])/0x\1/g'
            }
            exp_n="$sim_dir/${test_name}.expected.ctxp.norm"
            got_n="$sim_dir/${test_name}.decoded.ctxp.norm"
            ctxp_norm "$exp_ctxp" > "$exp_n"
            ctxp_norm "$got_ctxp" > "$got_n"
            n_exp=$(wc -l < "$exp_n"); n_got=$(wc -l < "$got_n")
            echo "[decode-ctxp] $test_name: expected $n_exp CTXP records, decoded $n_got"
            if diff -q "$exp_n" "$got_n" > /dev/null; then
                echo "[decode-ctxp] $test_name: PASS — all $n_exp CTXP records match"
            else
                if [ "$soft" -eq 1 ]; then
                    echo "[decode-ctxp] $test_name: WARN — CTXP records diverge (soft mode)"
                else
                    echo "[decode-ctxp] $test_name: FAIL — CTXP records do not match"; fail=1
                fi
                diff -u --label expected --label decoded "$exp_n" "$got_n" | head -40 || true
            fi
        fi
    fi
fi

# ------------------------------------------------------------------
# --sync N : at least N synchronization messages
# Synchronizing messages carry a "...Sync" label (ProgTraceSync,
# DirectBranchSync, IndirectBranchSync, IndirectBranchHistSync,
# RepeatInstructionSync); plain messages do not.
# ------------------------------------------------------------------
if [ -n "$sync_min" ]; then
    n_sync=$(grep -cE 'TCODE\[6\]=[0-9]+.*Sync' "$log" || true)
    echo "[decode-sync] $test_name: $n_sync synchronization message(s) decoded (need >= $sync_min)"
    if [ "$n_sync" -lt "$sync_min" ]; then
        echo "[decode-sync] $test_name: FAIL — fewer than $sync_min sync messages"
        grep -nE 'TCODE\[6\]=[0-9]+' "$log" | head -20 || true
        fail=1
    else
        echo "[decode-sync] $test_name: PASS — $n_sync sync messages (>= $sync_min)"
    fi
fi

# ------------------------------------------------------------------
# --disabled : trace-off Program Trace Correlation (EVCODE=Program Trace Disabled)
# ------------------------------------------------------------------
if [ "$do_disabled" -eq 1 ]; then
    n_corr=$(grep -cE 'TCODE\[6\]=33 .*ProgTraceCorrelation' "$log" || true)
    n_off=$(grep -cE 'EVCODE\[4\]=0x4' "$log" || true)
    echo "[decode-off] $test_name: $n_corr ProgTraceCorrelation msg(s), $n_off with EVCODE=Program Trace Disabled"
    if [ "$n_corr" -lt 1 ] || [ "$n_off" -lt 1 ]; then
        echo "[decode-off] $test_name: FAIL — no Program Trace Disabled correlation message emitted on trace-off"
        grep -nE 'TCODE\[6\]=[0-9]+' "$log" | tail -10 || true
        fail=1
    else
        echo "[decode-off] $test_name: PASS — trace-off emits ProgTraceCorrelation(EVCODE=Program Trace Disabled)"
    fi
fi

exit "$fail"
