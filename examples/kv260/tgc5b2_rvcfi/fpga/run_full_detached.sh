#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Self-redirecting full rebuild: project (with the console in the file list)
# + bitstream + memory-kind gate. Judged by markers, never by exit codes.
LOG=/d/shared/engineering/C-Trace/examples/kv260/tgc5b2_rvcfi/fpga/logs/bitstream.out
exec > "$LOG" 2>&1
export PATH="/c/Xilinx/2026.1/Vivado/bin:$PATH"
cd /d/shared/engineering/C-Trace || exit 9
echo "START $(date '+%Y-%m-%d %H:%M:%S')"
rm -rf examples/kv260/tgc5b2_rvcfi/fpga/proj
vivado -mode batch -notrace \
  -source examples/kv260/tgc5b2_rvcfi/fpga/create_project.tcl \
  -journal examples/kv260/tgc5b2_rvcfi/fpga/logs/create.jou \
  -log     examples/kv260/tgc5b2_rvcfi/fpga/logs/create.log
echo "CREATE_RC=$?"
vivado -mode batch -notrace \
  -source examples/kv260/tgc5b2_rvcfi/fpga/run_bitstream.tcl \
  -journal examples/kv260/tgc5b2_rvcfi/fpga/logs/bits.jou \
  -log     examples/kv260/tgc5b2_rvcfi/fpga/logs/bits.log
echo "BITSTREAM_RC=$?"
PY=py; command -v py >/dev/null 2>&1 || PY=python3
"$PY" examples/kv260/tgc5b2_rvcfi/fpga/check_memory_kind.py \
  examples/kv260/tgc5b2_rvcfi/fpga/reports/tgc5b2_rvcfi_utilization.rpt
echo "MEMKIND_RC=$?"
echo "END $(date '+%Y-%m-%d %H:%M:%S')"
