#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# prep_load.sh -- OS-level pre-load step, runs as root ON THE BOARD. Called
# by wp_board_gate.sh's do_load() right before it hands off to
# examples/kv260/common/board/deploy_kv260_app.sh (which does the
# dtc/install/loadapp/hash-verify half): stop the dashboard (single-master
# discipline -- only the F1 reader, read_wp_stream.py, may touch the FIFO
# windows while a run is in progress; the dashboard is the other master),
# capture which app was active before we touch anything (wp_board_gate.sh
# parses PREV_LISTAPPS_BEGIN/END for the `restore` phase), unload whatever
# currently sits in the PL slot, and set pl_clk0 to $1 MHz.
#
# Ported from the OS-level half of the predecessor repository's g1_prep_install.sh /
# g1_prep_reload.sh (both were the same script with an INSTALL flag; the
# dtc/install/copy/loadapp half that flag gated is now deploy_kv260_app.sh,
# called separately, so the flag itself is gone here).
#
#   sudo sh prep_load.sh <MHZ>
set -e
MHZ="${1:?usage: prep_load.sh <MHZ>}"
echo "DASHBOARD_WAS $(systemctl is-active ctrace-dashboard 2>/dev/null || true)"
systemctl stop ctrace-dashboard 2>/dev/null || true
echo "PREV_LISTAPPS_BEGIN"
xmutil listapps 2>&1 || true
echo "PREV_LISTAPPS_END"
echo "FPGA_STATE_BEFORE $(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)"
xmutil unloadapp >/dev/null 2>&1 || true
MHZ=$MHZ sh /tmp/wp_board_run/kv260_plclk.sh || { echo PLCLK_FAILED; exit 9; }
echo "PREP_LOAD_OK"
