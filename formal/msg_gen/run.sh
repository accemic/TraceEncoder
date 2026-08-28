#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Formal gate: ct_L2_msg_gen (P-MSG-1..4).
#   usage: ./run.sh              # all tasks (bmc + cover + prove)
#          ./run.sh bmc          # selected task
# RTL_DIR=<path> overrides the RTL root (red counter-proof worktrees).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

RTL="${RTL_DIR:-$SCRIPT_DIR/../../rtl}"
mkdir -p "$SCRIPT_DIR/build"

# source_if.sv carries a modport function import (`import have_available`)
# that sv2v cannot parse; msg_gen never calls it. Strip the modport entry
# mechanically (build-local copy, RTL untouched).
perl -0pe 's/,\s*\n\s*import\s+have_available//' \
	"$RTL/external/stream/source_if.sv" \
	> "$SCRIPT_DIR/build/source_if_patched.sv"

# sed rationale: see formal/README.md (uwire downgrade + sv2v upward-
# reference prefix strip).
sv2v -E Assert -E SeverityTask \
	"$RTL/pkg/nexus_vendor_riscv_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_types_pkg.sv" \
	"$RTL/pkg/ct_pkg.sv" \
	"$RTL/pkg/tip_pkg.sv" \
	"$RTL/pkg/ct_etip_pkg.sv" \
	"$RTL/pkg/ct_cs_if.sv" \
	"$SCRIPT_DIR/build/source_if_patched.sv" \
	"$RTL/ct_L2_msg_gen.sv" \
	"$SCRIPT_DIR/wrapper.sv" \
	| sed -e 's/\buwire\b/wire/g' -e 's/\bf_msg_check\.//g' \
	| perl -0pe 's/\s*else\s+\$error\s*\([^;]*\);/;/g; s/\w+\s*:\s*assert\s+property\s*\(.*?\)\s*else\s+begin.*?\bend\b//gs' \
	> "$SCRIPT_DIR/build/msg_gen_formal.v"
	# perl pass 1: yosys parses immediate `assert (...)` but not its
	#   `else $error(...)` action block — drop the action, keep the check.
	# perl pass 2: strip the two concurrent SVA blocks (I6/I7) — yosys'
	#   free frontend has no SVA; both are re-stated 1:1 as immediate
	#   assertions in wrapper.sv (A_i6/A_i7), so the checks still run.

cd "$SCRIPT_DIR"
sby -f msg_gen.sby "$@"
