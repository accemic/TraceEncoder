#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Render the browsable HTML register reference from the SystemRDL sources.
#
# Companion to scripts/gen_rdl.sh / gen_rdl_soc.sh / gen_rdl_kv260.sh (same
# pinned toolchain / virtualenv, rdl/requirements.txt). Three references are
# rendered into bld/ (build artifacts, not committed):
#
#   bld/rdl-html/ct_soc_kv260_top/  the KV260 example-SoC app map — every
#                                   register (encoder CSRs included) at the
#                                   absolute physical address `devmem` takes
#                                   on the board
#   bld/rdl-html/ct_cs_cpuif/       the bare CEDARtools.TraceEncoder CSR map
#                                   (aperture-relative offsets)
#   bld/rdl-html/ct_kv260_ctrl/     the unified KV260 example-SoC CTRL window
#                                   (examples/kv260/common/rdl/, README.md
#                                   there) — the shared sink subsystem's own
#                                   registers, which neither map above covers:
#                                   ct_soc.rdl is the TGC5B SoC peripheral
#                                   map, not the CTRL window
#
# Venv resolution: this uses scripts/gen_rdl.sh's fixed find_venv_python()
# rather than the `$VENV/bin/python`-only probe this script used to carry.
# That probe never matches on a Windows checkout (`python -m venv` lays down
# Scripts/python.exe, not bin/python), so every run tried to build a fresh
# venv with $PYTHON and died on the Store shim — this renderer was simply
# unreachable there. Same reasoning and same code as
# examples/kv260/common/rdl/gen_rdl_kv260.sh; scripts/gen_rdl_soc.sh still
# carries the old lookup.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

REQ=rdl/requirements.txt
PYTHON="${PYTHON:-python3}"
OUTDIR=bld/rdl-html

# --- 1. Reproducible toolchain in a local virtualenv (shared with gen_rdl.sh,
#        gen_rdl_soc.sh and gen_rdl_kv260.sh) ---------------------------------
GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*|?:[\\/]*) ;; *) GIT_COMMON="$REPO_ROOT/$GIT_COMMON" ;; esac
MAIN_ROOT="$(cd "$(dirname "$GIT_COMMON")" && pwd)"

find_venv_python () {   # first existing pinned interpreter, worktree then main
	local root p
	for root in "$REPO_ROOT" "$MAIN_ROOT"; do
		for p in "$root/.venv-rdl-win/Scripts/python.exe" \
		         "$root/.venv-rdl/Scripts/python.exe" \
		         "$root/.venv-rdl/bin/python"; do
			if [ -x "$p" ]; then echo "$p"; return 0; fi
		done
	done
	return 1
}

if ! PY="$(find_venv_python)"; then
	echo "[gen_rdl_html] creating virtualenv $MAIN_ROOT/.venv-rdl"
	"$PYTHON" -m venv "$MAIN_ROOT/.venv-rdl"
	PY="$(find_venv_python)" || { echo "[gen_rdl_html] FAIL: venv creation produced no interpreter"; exit 3; }
	"$PY" -m pip install --quiet --upgrade pip
	echo "[gen_rdl_html] installing pinned toolchain from $REQ"
	"$PY" -m pip install --quiet -r "$REQ"
elif [ -n "${GEN_RDL_FORCE_INSTALL:-}" ]; then
	echo "[gen_rdl_html] installing pinned toolchain from $REQ (forced)"
	"$PY" -m pip install --quiet -r "$REQ"
fi
echo "[gen_rdl_html] toolchain: $PY"

# Verify the pins instead of reinstalling them on every run (gen_rdl.sh's
# reasoning applies verbatim: the point of the pin is the VERSION, not the
# install step, and an install into a venv a parallel gate is reading is
# shared mutable state).
"$PY" - "$REQ" <<'PYEOF'
import re, sys
from importlib.metadata import version, PackageNotFoundError
bad = []
for line in open(sys.argv[1], encoding="utf-8"):
	m = re.match(r"^\s*([A-Za-z0-9_.-]+)==([0-9A-Za-z.]+)\s*$", line)
	if not m:
		continue
	pkg, want = m.group(1), m.group(2)
	try:
		have = version(pkg)
	except PackageNotFoundError:
		have = "MISSING"
	print(f"[gen_rdl_html] pin {pkg}=={want}: {have}")
	if have != want:
		bad.append(f"{pkg}: want {want}, have {have}")
if bad:
	sys.exit("[gen_rdl_html] FAIL: pinned toolchain mismatch (" + "; ".join(bad)
	         + ") -- rerun with GEN_RDL_FORCE_INSTALL=1")
PYEOF

# --- 2. PeakRDL-html ---------------------------------------------------------
echo "[gen_rdl_html] peakrdl html -> $OUTDIR/ct_soc_kv260_top/"
"$PY" -m peakrdl html examples/kv260/common/tgc5b/rdl/ct_soc.rdl \
	-I examples/kv260/common/tgc5b/rdl -I rdl \
	-t ct_soc_kv260_top -o "$OUTDIR/ct_soc_kv260_top"

echo "[gen_rdl_html] peakrdl html -> $OUTDIR/ct_cs_cpuif/"
"$PY" -m peakrdl html rdl/ct_cs_cpuif.rdl -o "$OUTDIR/ct_cs_cpuif"

# The unified KV260 CTRL window. -t selects the RTL addrmap; the
# documentation-only ct_kv260_ctrl_window in the same file is not rendered,
# for the same reason gen_rdl_kv260.sh generates no RTL from it.
echo "[gen_rdl_html] peakrdl html -> $OUTDIR/ct_kv260_ctrl/"
"$PY" -m peakrdl html examples/kv260/common/rdl/ct_kv260_ctrl.rdl \
	-I examples/kv260/common/rdl \
	-t ct_kv260_ctrl_periph -o "$OUTDIR/ct_kv260_ctrl"

echo "[gen_rdl_html] done: open $OUTDIR/<map>/index.html"
