#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Regenerate the example SoC peripheral register block from examples/tgc5b_soc/rdl/ct_soc.rdl.
#
# Companion to scripts/gen_rdl.sh (which regenerates the encoder CSR block). It
# reuses the same pinned toolchain / virtualenv (.venv-rdl, rdl/requirements.txt)
# so output is reproducible, and emits an AXI4-Lite (flat) register block for the
# CLINT + INTC peripherals of the TGC5B example SoC.
#
# Outputs (SPDX header prepended to each):
#   examples/tgc5b_soc/pkg/ct_soc_regs.sv       PeakRDL-regblock — register block
#   examples/tgc5b_soc/pkg/ct_soc_regs_pkg.sv   PeakRDL-regblock — hwif struct package
#
# Never edit the generated files by hand — rerun this script (make rdl-soc).

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

RDL=examples/tgc5b_soc/rdl/ct_soc.rdl
REQ=rdl/requirements.txt
VENV=.venv-rdl
PYTHON="${PYTHON:-python3}"
OUTDIR=examples/tgc5b_soc/pkg

# --- 1. Reproducible toolchain in a local virtualenv (shared with gen_rdl.sh) --
if [ ! -x "$VENV/bin/python" ]; then
	echo "[gen_rdl_soc] creating virtualenv $VENV"
	"$PYTHON" -m venv "$VENV"
	"$VENV/bin/pip" install --quiet --upgrade pip
fi
echo "[gen_rdl_soc] installing pinned toolchain from $REQ"
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

add_spdx() {
	local f="$1" tmp
	tmp="$(mktemp)"
	{ printf '// %s\n// %s\n\n' "$SPDX_COPY" "$SPDX_LIC"; cat "$f"; } >"$tmp"
	mv "$tmp" "$f"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 2. PeakRDL-regblock: AXI4-Lite (flat) register block + hwif package -----
# Only the CLINT + INTC block (addrmap ct_soc_periph) becomes RTL; the other maps
# in ct_soc.rdl (ct_soc, ct_soc_top) are documentation. -I examples/tgc5b_soc/rdl resolves the
# `include-d component files under examples/tgc5b_soc/rdl/ct_soc/; -I rdl resolves
# the encoder addrmap (ct_cs_cpuif.rdl) instantiated by the documentation maps.
echo "[gen_rdl_soc] peakrdl regblock -> $OUTDIR/"
peakrdl regblock "$RDL" -o "$TMP" -I examples/tgc5b_soc/rdl -I rdl -t ct_soc_periph \
	--cpuif axi4-lite-flat --type-style hier \
	--module-name ct_soc_regs --package-name ct_soc_regs_pkg
mkdir -p "$OUTDIR"
for f in ct_soc_regs.sv ct_soc_regs_pkg.sv; do
	add_spdx "$TMP/$f"
	cp "$TMP/$f" "$OUTDIR/$f"
done

echo "[gen_rdl_soc] done. Commit examples/tgc5b_soc/rdl/ct_soc.rdl and the regenerated SV together."
