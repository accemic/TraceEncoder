#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Red counter-proof for the Klasse-8 property (P-MSG-1, Gate 15,
# Fix 8f8e85aa). Two-sided falsification:
#   1) P-MSG-1-only build against the CURRENT RTL       -> must PASS
#   2) the same build against the PRE-FIX RTL (335393b6) -> must FAIL
#      (trailing `if (FlushRequest)` clobbers the same-cycle message)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFIX_COMMIT=335393b6   # parent of 8f8e85aa (flush-clobber fix)
WT_DIR="$REPO_ROOT/../ctte_worktrees/klasse8_$PREFIX_COMMIT"

if [ ! -d "$WT_DIR" ]; then
	git -C "$REPO_ROOT" worktree add --detach "$WT_DIR" "$PREFIX_COMMIT"
fi

build_red () { # $1 = RTL root
	local rtl="$1"
	perl -0pe 's/,\s*\n\s*import\s+have_available//' \
		"$rtl/external/stream/source_if.sv" \
		> "$SCRIPT_DIR/build/source_if_patched_red.sv"
	sv2v -E Assert -E SeverityTask -DRED_CLASS8 \
		"$rtl/pkg/nexus_vendor_riscv_pkg.sv" \
		"$rtl/pkg/ct_cs_cpuif_pkg.sv" \
		"$rtl/pkg/ct_cs_cpuif_types_pkg.sv" \
		"$rtl/pkg/ct_pkg.sv" \
		"$rtl/pkg/tip_pkg.sv" \
		"$rtl/pkg/ct_etip_pkg.sv" \
		"$rtl/pkg/ct_cs_if.sv" \
		"$SCRIPT_DIR/build/source_if_patched_red.sv" \
		"$rtl/ct_L2_msg_gen.sv" \
		"$SCRIPT_DIR/wrapper.sv" \
		| sed -e 's/\buwire\b/wire/g' -e 's/\bf_msg_check\.//g' \
		| perl -0pe 's/\s*else\s+\$error\s*\([^;]*\);/;/g; s/\w+\s*:\s*assert\s+property\s*\(.*?\)\s*else\s+begin.*?\bend\b//gs' \
		> "$SCRIPT_DIR/build/msg_gen_red.v"
}

mkdir -p "$SCRIPT_DIR/build"
cd "$SCRIPT_DIR"

echo "== red cross-check 1/2: P-MSG-1-only vs CURRENT rtl (expect PASS)"
build_red "$REPO_ROOT/rtl"
if ! sby -f msg_gen_red.sby > build/red_green_side.log 2>&1; then
	echo "ERROR: P-MSG-1 FAILED on the CURRENT (fixed) RTL — property or probe defect."
	tail -5 build/red_green_side.log
	exit 1
fi
echo "   PASS on fixed RTL — property holds where it must."

echo "== red cross-check 2/2: P-MSG-1-only vs pre-fix worktree $PREFIX_COMMIT (expect FAIL)"
build_red "$WT_DIR/rtl"
if sby -f msg_gen_red.sby > build/red_red_side.log 2>&1; then
	echo "ERROR: P-MSG-1 PASSED on the pre-fix RTL — the property does NOT catch Klasse 8."
	exit 1
fi
if ! grep -q "DONE (FAIL" build/red_red_side.log; then
	echo "ERROR: pre-fix run ended without a proper FAIL (tool error?):"
	tail -5 build/red_red_side.log
	exit 1
fi
echo "   FAIL on pre-fix RTL — Klasse-8 flush clobber caught. CEX:"
grep -E "failed assertion|Assert failed" build/red_red_side.log | head -2

echo "RED COUNTER-PROOF OK (green on fix, red on $PREFIX_COMMIT)."
