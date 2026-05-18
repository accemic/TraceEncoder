#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Lint all SystemVerilog under rtl/ and tests/ with verible-verilog-lint.
#
# Stub: real implementation lands when verible is wired into CI.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "[lint] not implemented yet — skeleton release."
echo "[lint] expected behaviour:"
echo "        find rtl tests -name '*.sv' -o -name '*.svh' \\"
echo "          | xargs verible-verilog-lint --rules_config_search"
exit 0
