#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Format all SystemVerilog under rtl/ and tests/ with verible-verilog-format.
#
# Stub: real implementation lands alongside the lint script.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "[format] not implemented yet — skeleton release."
echo "[format] expected behaviour:"
echo "         find rtl tests -name '*.sv' -o -name '*.svh' \\"
echo "           | xargs verible-verilog-format --inplace"
exit 0
