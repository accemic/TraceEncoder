#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Render the browsable HTML register reference from the SystemRDL sources.
#
# Companion to scripts/gen_rdl.sh / gen_rdl_soc.sh (same pinned toolchain /
# virtualenv, .venv-rdl + rdl/requirements.txt). Two references are rendered
# into bld/ (build artifacts, not committed):
#
#   bld/rdl-html/ct_soc_kv260_top/  the KV260 example-SoC app map — every
#                                   register (encoder CSRs included) at the
#                                   absolute physical address `devmem` takes
#                                   on the board
#   bld/rdl-html/ct_cs_cpuif/       the bare CEDARtools.TraceEncoder CSR map
#                                   (aperture-relative offsets)

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

REQ=rdl/requirements.txt
VENV=.venv-rdl
PYTHON="${PYTHON:-python3}"
OUTDIR=bld/rdl-html

# --- 1. Reproducible toolchain in a local virtualenv (shared with gen_rdl.sh) --
if [ ! -x "$VENV/bin/python" ]; then
	echo "[gen_rdl_html] creating virtualenv $VENV"
	"$PYTHON" -m venv "$VENV"
	"$VENV/bin/pip" install --quiet --upgrade pip
fi
echo "[gen_rdl_html] installing pinned toolchain from $REQ"
"$VENV/bin/pip" install --quiet -r "$REQ"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

# --- 2. PeakRDL-html ---------------------------------------------------------
echo "[gen_rdl_html] peakrdl html -> $OUTDIR/ct_soc_kv260_top/"
peakrdl html examples/tgc5b_soc/rdl/ct_soc.rdl \
	-I examples/tgc5b_soc/rdl -I rdl \
	-t ct_soc_kv260_top -o "$OUTDIR/ct_soc_kv260_top"

echo "[gen_rdl_html] peakrdl html -> $OUTDIR/ct_cs_cpuif/"
peakrdl html rdl/ct_cs_cpuif.rdl -o "$OUTDIR/ct_cs_cpuif"

echo "[gen_rdl_html] done: open $OUTDIR/<map>/index.html"
