#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Formal gate: ct_L2_mseo_mdo_formatter (P-MDO-1..7).
#   usage: ./run.sh                # all tasks (bmc + cover + live)
#          ./run.sh bmc            # selected task
# RTL_DIR=<path> overrides the RTL root; MUTATE=<perl-expr> applies a
# build-local source mutation (red cross-checks, see run_red.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

RTL="${RTL_DIR:-$SCRIPT_DIR/../../rtl}"
mkdir -p "$SCRIPT_DIR/build"

# source_if modport function import: sv2v parser limit (see msg_gen gate).
perl -0pe 's/,\s*\n\s*import\s+have_available//g' \
	"$RTL/external/stream/source_if.sv" \
	> "$SCRIPT_DIR/build/source_if_patched.sv"

# sink_if has the same modport function import construct.
perl -0pe 's/,\s*\n\s*import\s+have_available//g' \
	"$RTL/external/stream/sink_if.sv" \
	> "$SCRIPT_DIR/build/sink_if_patched.sv"

# math_pkg carries a sim-only class (array_math) that sv2v cannot parse;
# the formatter chain only needs math::gray2bin — strip the class block
# build-locally.
perl -0pe 's/\bclass\s+array_math.*?endclass\s*;?//s' \
	"$RTL/external/common/math_pkg.sv" \
	> "$SCRIPT_DIR/build/math_pkg_patched.sv"

# Optional red-check mutation on a build-local copy of one source file:
#   MUTATE_FILE=<path relative to rtl> MUTATE='<perl expr>'
SRC_MSEO="$RTL/mseo_mdo/ct_L2_mseo_mdo_formatter_mseo_controller.sv"
SRC_PACK="$RTL/mseo_mdo/ct_L2_mseo_mdo_formatter_atb_chunk_packer.sv"
SRC_SLIC="$RTL/mseo_mdo/ct_L2_mseo_mdo_formatter_bit_slicer_impl.sv"
if [ -n "${MUTATE:-}" ] && [ -n "${MUTATE_FILE:-}" ]; then
	case "$MUTATE_FILE" in
		mseo)   perl -0pe "$MUTATE" "$SRC_MSEO" > "$SCRIPT_DIR/build/mut_mseo.sv";   SRC_MSEO="$SCRIPT_DIR/build/mut_mseo.sv" ;;
		packer) perl -0pe "$MUTATE" "$SRC_PACK" > "$SCRIPT_DIR/build/mut_packer.sv"; SRC_PACK="$SCRIPT_DIR/build/mut_packer.sv" ;;
		slicer) perl -0pe "$MUTATE" "$SRC_SLIC" > "$SCRIPT_DIR/build/mut_slicer.sv"; SRC_SLIC="$SCRIPT_DIR/build/mut_slicer.sv" ;;
		*) echo "unknown MUTATE_FILE $MUTATE_FILE" >&2; exit 2 ;;
	esac
fi

# sed rationale: formal/README.md (uwire downgrade, sv2v prefix strip,
# assert-else action strip).
# Plan C (formal/README.md): the wrapper composes the four proc-side
# stages directly (glue copied 1:1 from the formatter top) — sv2v cannot
# pass the top's interface instances through two inlining levels. No
# interfaces and no hierarchical probes are needed on this route.
sv2v -E Assert -E SeverityTask \
	"$RTL/pkg/nexus_vendor_riscv_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_types_pkg.sv" \
	"$RTL/pkg/ct_pkg.sv" \
	"$RTL/pkg/tip_pkg.sv" \
	"$RTL/external/amba/atb_pkg.sv" \
	"$RTL/mseo_mdo/ct_L2_mseo_mdo_formatter_msg_buffer.sv" \
	"$SRC_SLIC" \
	"$RTL/mseo_mdo/ct_L2_mseo_mdo_formatter_bit_slicer.sv" \
	"$SRC_MSEO" \
	"$SRC_PACK" \
	"$SCRIPT_DIR/wrapper.sv" \
	| sed -e 's/\buwire\b/wire/g' -e 's/\bf_mdo_check\.//g' -e 's/\bf_mdo_live\.//g' \
	| perl -0pe 's/\s*else\s+\$error\s*\([^;]*\);/;/g; s/\w+\s*:\s*assert\s+property\s*\(.*?\)\s*else\s+begin.*?\bend\b//gs' \
	> "$SCRIPT_DIR/build/mseo_mdo_formal.v"

cd "$SCRIPT_DIR"
sby -f mseo_mdo.sby "$@"
