#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Formal gate: ct_L2_nexus_formatter (P-FMT-1..5, P3 DF address compression).
#   usage: ./run.sh                 # all tasks (bmc + cover + prove)
#          ./run.sh bmc             # selected task
# RTL_DIR=<path> overrides the RTL root; MUTATE='<perl expr>' applies a
# build-local mutation to the DUT source ct_L2_nexus_formatter.sv (red
# mutation cross-checks, see run_red.sh; pattern from formal/preproc_sync).
# SV2V_DEFS='-DRED_MASK_...' adds sv2v defines. RED-RUN USE ONLY: the masks
# switch OFF a property that strictly generalizes (and would therefore hide)
# the property a given mutation targets. A green run passes NO defines --
# neither run.sh's own invocation nor ci/run_stage2b_formal.sh ever sets it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

RTL="${RTL_DIR:-$SCRIPT_DIR/../../rtl}"
mkdir -p "$SCRIPT_DIR/build"

# Optional red-check mutation on a build-local copy of the DUT source
# (never touches the tree).
SRC_DUT="$RTL/ct_L2_nexus_formatter.sv"
if [ -n "${MUTATE:-}" ]; then
	perl -0pe "$MUTATE" "$SRC_DUT" > "$SCRIPT_DIR/build/mut_nexus_formatter.sv"
	if cmp -s "$SRC_DUT" "$SCRIPT_DIR/build/mut_nexus_formatter.sv"; then
		echo "ERROR: MUTATE expression did not change the source" >&2
		exit 2
	fi
	SRC_DUT="$SCRIPT_DIR/build/mut_nexus_formatter.sv"
fi

# sed rationale: formal/README.md (uwire downgrade + sv2v upward-reference
# prefix strip). Extra perl pass: the formatter's SimulationOutput task is
# a sim-only $display (translate_off, but sv2v ignores synthesis comment
# pragmas) whose tcode.name() enum method has no formal meaning -- strip
# the $display statements, keep the (then empty) task.
read -r -a SV2V_EXTRA <<< "${SV2V_DEFS:-}"
sv2v -E Assert -E SeverityTask ${SV2V_EXTRA[@]+"${SV2V_EXTRA[@]}"} \
	"$RTL/pkg/nexus_vendor_riscv_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_types_pkg.sv" \
	"$RTL/pkg/ct_pkg.sv" \
	"$RTL/pkg/tip_pkg.sv" \
	"$RTL/pkg/ct_cs_if.sv" \
	"$SRC_DUT" \
	"$SCRIPT_DIR/wrapper.sv" \
	| sed -e 's/\buwire\b/wire/g' -e 's/\bf_fmt_check\.//g' \
	| perl -0pe 's/\$display\s*\(.*?\);/;/gs' \
	> "$SCRIPT_DIR/build/nexus_formatter_formal.v"

cd "$SCRIPT_DIR"
sby -f nexus_formatter.sby "$@"
