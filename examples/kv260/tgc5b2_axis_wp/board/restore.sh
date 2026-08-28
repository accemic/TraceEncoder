#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# restore.sh -- put the board back the way wp_board_gate.sh found it, runs
# as root ON THE BOARD: unload our app, reload whatever was active before
# (if anything, and if it wasn't us), restart the dashboard (single-master
# discipline hands the FIFO windows back to it), and report board health.
#
# Ported unchanged in substance from the predecessor repository's g1_restore.sh; the app
# name is now $2 instead of a literal, so this can't silently drift from
# whatever --app wp_board_gate.sh was invoked with.
#
#   sudo sh restore.sh <prev-app-or-none> <our-app-name>
PREV="$1"
APP="${2:-tgc5b2_axis_wp_c0b}"
xmutil unloadapp >/dev/null 2>&1 || true
if [ -n "$PREV" ] && [ "$PREV" != "none" ] && [ "$PREV" != "$APP" ]; then
  xmutil loadapp "$PREV" || { echo RESTORE_LOAD_FAILED; exit 6; }
  sleep 2
fi
echo "FPGA_STATE_FINAL $(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)"
xmutil listapps 2>&1 || true
systemctl start ctrace-dashboard 2>/dev/null || true
sleep 3
echo "DASHBOARD_NOW $(systemctl is-active ctrace-dashboard 2>/dev/null || true)"
curl -s --max-time 5 http://localhost:8099/api/mode || echo "DASHBOARD_HTTP_UNREACHABLE"
echo ""
echo "RESTORE_OK"
