#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Regenerate rdl/gen/*.sv from rdl/*.rdl using PeakRDL.
#
# Stub: real implementation lands alongside the RDL port.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "[gen_rdl] not implemented yet — skeleton release."
echo "[gen_rdl] expected behaviour:"
echo "          peakrdl regblock -o rdl/gen/ rdl/<file>.rdl"
echo "          peakrdl html     -o doc/registers/ rdl/<file>.rdl"
exit 0
