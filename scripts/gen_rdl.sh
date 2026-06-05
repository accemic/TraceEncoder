#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Regenerate the PeakRDL-derived SystemVerilog from rdl/ct_cs_cpuif.rdl.
#
# Reproducible by construction: the Python toolchain is pinned in
# rdl/requirements.txt and installed into a local virtualenv (.venv-rdl/),
# so every developer regenerates byte-identical output (the PeakRDL-regblock
# module aside, which tracks the pinned tool version).
#
# Outputs (SPDX header prepended to each):
#   rtl/pkg/ct_cs_cpuif.sv             PeakRDL-regblock — register block module
#   rtl/pkg/ct_cs_cpuif_pkg.sv         PeakRDL-regblock — hwif struct package
#   rtl/pkg/ct_cs_cpuif_wb_pkg.sv      generate_wb_pkg.py — address/bitfield constants
#   rtl/pkg/ct_cs_cpuif_types_pkg.sv   generate_wb_pkg.py — ispresent=false type anchors
#   tests/lib/ct_cs_cpuif_wb_helper.sv generate_wb_pkg.py — Wishbone BFM for testbenches
#
# NOT generated (hand-written): rtl/pkg/ct_cs_cpuif_wb.sv (the Wishbone<->CPUIF
# adapter). Never edit the generated files by hand — rerun `make rdl`.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

RDL=rdl/ct_cs_cpuif.rdl
REQ=rdl/requirements.txt
VENV=.venv-rdl
PYTHON="${PYTHON:-python3}"

# --- 1. Reproducible toolchain in a local virtualenv ------------------------
if [ ! -x "$VENV/bin/python" ]; then
	echo "[gen_rdl] creating virtualenv $VENV"
	"$PYTHON" -m venv "$VENV"
	"$VENV/bin/pip" install --quiet --upgrade pip
fi
echo "[gen_rdl] installing pinned toolchain from $REQ"
"$VENV/bin/pip" install --quiet -r "$REQ"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

# --- helpers ----------------------------------------------------------------
# These literals are injected verbatim into the generated RTL (which stays
# dual-licensed). They are not this script's own license — REUSE must not
# parse them as such.
# REUSE-IgnoreStart
SPDX_COPY='SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH'
SPDX_LIC='SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial'
# REUSE-IgnoreEnd

# Prepend the SPDX header (C++-style // comments) to a generated file.
add_spdx() {
	local f="$1" tmp
	tmp="$(mktemp)"
	{ printf '// %s\n// %s\n\n' "$SPDX_COPY" "$SPDX_LIC"; cat "$f"; } >"$tmp"
	mv "$tmp" "$f"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 2. PeakRDL-regblock: register block module + hwif package --------------
echo "[gen_rdl] peakrdl regblock -> rtl/pkg/"
peakrdl regblock "$RDL" -o "$TMP/regblock" --cpuif passthrough --type-style hier
for f in ct_cs_cpuif.sv ct_cs_cpuif_pkg.sv; do
	add_spdx "$TMP/regblock/$f"
	cp "$TMP/regblock/$f" "rtl/pkg/$f"
done

# --- 3. generate_wb_pkg.py: wb constants pkg, type anchors, TB helper -------
echo "[gen_rdl] generate_wb_pkg.py -> rtl/pkg/ + tests/lib/"
mkdir -p "$TMP/wb"
python scripts/generate_wb_pkg.py "$RDL" "$TMP/wb" >/dev/null
add_spdx "$TMP/wb/ct_cs_cpuif_wb_pkg.sv"
add_spdx "$TMP/wb/ct_cs_cpuif_types_pkg.sv"
add_spdx "$TMP/wb/ct_cs_cpuif_wb_helper.sv"
cp "$TMP/wb/ct_cs_cpuif_wb_pkg.sv"    rtl/pkg/
cp "$TMP/wb/ct_cs_cpuif_types_pkg.sv" rtl/pkg/
cp "$TMP/wb/ct_cs_cpuif_wb_helper.sv" tests/lib/

echo "[gen_rdl] done. Commit the RDL change and the regenerated SV together."
