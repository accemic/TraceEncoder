#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Self-redirecting bitstream driver. Detaching with an OUTSIDE redirect has
# been measured on this host to produce neither a log nor a reliable child
# process, so the wrapper redirects itself.
LOG=/d/shared/engineering/C-Trace/examples/kv260/tgc5b2_rvcfi/fpga/logs/bitstream.out
exec > "$LOG" 2>&1
export PATH="/c/Xilinx/2026.1/Vivado/bin:$PATH"
cd /d/shared/engineering/C-Trace || exit 9
echo "START $(date '+%Y-%m-%d %H:%M:%S')"
vivado -mode batch -notrace \
  -source examples/kv260/tgc5b2_rvcfi/fpga/run_bitstream.tcl \
  -journal examples/kv260/tgc5b2_rvcfi/fpga/logs/bits.jou \
  -log     examples/kv260/tgc5b2_rvcfi/fpga/logs/bits.log
echo "BITSTREAM_RC=$?"
echo "END $(date '+%Y-%m-%d %H:%M:%S')"
