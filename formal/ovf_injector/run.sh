#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Formal gate: ovf_injector (P-INJ-1..4).
#   usage: ./run.sh            # all tasks (prove + cover)
#          ./run.sh prove      # single task
# Optional: RTL_DIR=<path> overrides the RTL root (used by the red
# counter-proof runs against a pre-fix worktree).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

RTL="${RTL_DIR:-$SCRIPT_DIR/../../rtl}"
mkdir -p "$SCRIPT_DIR/build"

# sed 1: yosys' Verilog frontend does not know `uwire` (IEEE 1364-2005);
#        semantics-preserving downgrade to `wire` for the formal build only.
# sed 2: sv2v inlines the interface-ported DUT as a generate block and
#        prefixes parent-scope references with the wrapper module name
#        (`f_ovf_check.osnk.cnt`). yosys does NOT bind such upward
#        hierarchical references — it leaves the target undriven WITHOUT
#        an error (found via CEX: osnk.cnt free at step 0). Stripping the
#        prefix turns them into plain lexical upward references inside the
#        generate scope, which bind correctly.
sv2v -E Assert \
	"$RTL/external/stream/cvsink_if.sv" \
	"$RTL/external/stream/ovf_injector.sv" \
	"$SCRIPT_DIR/wrapper.sv" \
	| sed -e 's/\buwire\b/wire/g' -e 's/\bf_ovf_check\.//g' \
	> "$SCRIPT_DIR/build/ovf_injector_formal.v"

cd "$SCRIPT_DIR"
sby -f ovf_injector.sby "$@"
