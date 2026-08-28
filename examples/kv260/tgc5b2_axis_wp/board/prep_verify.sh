#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# prep_verify.sh -- OS-level post-load verification, runs as root ON THE
# BOARD. Called by wp_board_gate.sh's do_load() right after
# examples/kv260/common/board/deploy_kv260_app.sh has loaded the app:
# confirm fpga_manager reports "operating", re-read pl_clk0 WITHOUT MHZ=
# (a read-only probe -- passing MHZ= here would be a SET attempt that
# kv260_plclk.sh's app-in-slot guard correctly refuses with `set -e`
# aborting before this reaches PREP_OK, see the predecessor's
# g1_board_run.ps1's g1_prep_install.sh heredoc), and read the WPCTRL
# magic register as the final proof the design is alive on the AXI bus.
#
# Ported from the tail of the predecessor repository's g1_prep_install.sh/g1_prep_reload.sh.
#
#   sudo sh prep_verify.sh
set -e
sleep 2
ST=$(cat /sys/class/fpga_manager/fpga0/state)
echo "FPGA_STATE_AFTER $ST"
[ "$ST" = "operating" ] || { echo FPGA_NOT_OPERATING; exit 7; }
xmutil listapps 2>&1 || true
sh /tmp/wp_board_run/kv260_plclk.sh
echo "MAGIC $(busybox devmem 0xA0400000)"
echo "PREP_OK"
