#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P2 trace-quota sync gate (stage-2 gate "syncquota"): runs BOTH quota system
# tests and the hard byte-window check.
#
#   test 29 (sync_quota_bytes): InstSyncMode=4, Max=2 -> 64-B quota over
#     alternating compressibility. Gates:
#       decode_and_check --pc --sync 7         (losslessness + sync floor)
#       check_sync_window.py <atb.bin> 2 --log <log>
#                                              (max gap <= 2^(2+4) + Delta on
#                                               RAW ATB bytes -- the scale the
#                                               quota is defined on; the log is
#                                               only the classification
#                                               cross-check, see the script)
#   test 30 (sync_quota_msgs): InstSyncMode=1, Max=0 -> 16-message quota,
#     D8 collision design (CF_SYNC + mode-gated ATB request). The TB $fatals
#     itself unless SyncReqSource reads 3 at test end. Gate:
#       decode_and_check --pc --sync 4
#
# The N derivations live in the TB headers; the window bound derivation in
# scripts/check_sync_window.py.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
# The window check below is a Python program. The presence loop that used to
# stand at its call site tested `command -v` and fell back to bare `python` --
# on Windows the Microsoft Store stub, which exits 49 without running
# anything, and the caller read that as a failed WINDOW check. ct_need_python
# probes the function and dies with 78 (CT_E_TOOL) instead.
ct_need_python

fail=0

echo "===== [syncquota] test 29: sync_quota_bytes (byte quota, window check) ====="
if ! bash scripts/cli_sim.sh sync_quota_bytes --pc --sync 7; then
	echo "[syncquota] test 29 decode gate: FAIL"; fail=1
fi
log29="$(find "$here/bld" -name "sync_quota_bytes_tb.nexrv.log" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
bin29="${log29%.nexrv.log}.atb.bin"
if [ -z "$log29" ] || [ ! -s "$log29" ]; then
	echo "[syncquota] FAIL: no sync_quota_bytes_tb.nexrv.log under bld/"; fail=1
elif [ ! -s "$bin29" ]; then
	echo "[syncquota] FAIL: no sync_quota_bytes_tb.atb.bin next to the log"; fail=1
else
	if ! python3 scripts/check_sync_window.py "$bin29" 2 --log "$log29"; then
		echo "[syncquota] test 29 window gate: FAIL"; fail=1
	fi
fi

echo "===== [syncquota] test 30: sync_quota_msgs (message quota, D8 collision) ====="
if ! bash scripts/cli_sim.sh sync_quota_msgs --pc --sync 4; then
	echo "[syncquota] test 30 decode gate: FAIL"; fail=1
fi
# The TB's own SyncReqSource==3 $fatal must not have fired (xsim rc is
# swallowed by the runner; grep the sim log for the PASS marker instead).
xd30="$(find "$here/bld" -name "sync_quota_msgs_tb.atb.bin" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -n "$xd30" ] && grep -q "SyncReqSource=3 (SYNC_REQ_QUOTA) -- PASS" "$(dirname "$xd30")/xsim.log" 2>/dev/null; then
	echo "[syncquota] test 30 SyncReqSource==3 readback: PASS"
else
	echo "[syncquota] test 30 SyncReqSource==3 readback: FAIL (marker missing in xsim.log)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
	echo "===== [syncquota] OVERALL: PASS ====="
else
	echo "===== [syncquota] OVERALL: FAIL ====="
fi
exit $fail
