#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Regenerate the PeakRDL-derived SystemVerilog from rdl/ct_cs_cpuif.rdl.
#
# Reproducible by construction: the Python toolchain is pinned in
# rdl/requirements.txt and installed into a virtualenv next to the MAIN
# working tree (.venv-rdl/ on Linux, .venv-rdl-win/ on Windows; a linked
# `git worktree` uses that same one, see below), so every developer
# regenerates byte-identical output (the PeakRDL-regblock module aside, which
# tracks the pinned tool version).
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
PYTHON="${PYTHON:-python3}"

# --- 1. Reproducible toolchain in a local virtualenv ------------------------
# The virtualenv belongs to the MAIN working tree, not to a linked worktree:
# `git rev-parse --git-common-dir` names the shared .git, and its parent is
# that main tree. Looking only next to $REPO_ROOT is the trap the P8 audit
# recorded as C-1 -- inside a `git worktree` this script used to build a
# SECOND venv (which then dies on the Windows Store python stub), and the
# sibling gen_rdl_profile.py silently fell back to whatever `peakrdl` was on
# PATH, whose output carries no addrmap localparams and kills the whole test
# battery in xvlog. Both now resolve the same way.
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
	echo "[gen_rdl] creating virtualenv $MAIN_ROOT/.venv-rdl"
	"$PYTHON" -m venv "$MAIN_ROOT/.venv-rdl"
	PY="$(find_venv_python)" || { echo "[gen_rdl] FAIL: venv creation produced no interpreter"; exit 3; }
	"$PY" -m pip install --quiet --upgrade pip
	echo "[gen_rdl] installing pinned toolchain from $REQ"
	"$PY" -m pip install --quiet -r "$REQ"
elif [ -n "${GEN_RDL_FORCE_INSTALL:-}" ]; then
	echo "[gen_rdl] installing pinned toolchain from $REQ (forced)"
	"$PY" -m pip install --quiet -r "$REQ"
fi
echo "[gen_rdl] toolchain: $PY"

# Verify the pins instead of reinstalling them on every run: an install into a
# venv that a parallel gate is reading is shared mutable state, and the point
# of the pin is the VERSION, not the install step. A mismatch is a hard error
# -- generating with a different PeakRDL is exactly how a "byte-identical
# regeneration" claim stops being true.
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
	print(f"[gen_rdl] pin {pkg}=={want}: {have}")
	if have != want:
		bad.append(f"{pkg}: want {want}, have {have}")
if bad:
	sys.exit("[gen_rdl] FAIL: pinned toolchain mismatch (" + "; ".join(bad)
	         + ") -- rerun with GEN_RDL_FORCE_INSTALL=1")
PYEOF

# --- helpers ----------------------------------------------------------------
# These literals are injected verbatim into the generated RTL (which stays
# dual-licensed). They are not this script's own license — REUSE must not
# parse them as such.
# REUSE-IgnoreStart
SPDX_COPY='SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH'
SPDX_LIC='SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial'
# REUSE-IgnoreEnd

# Prepend the standard file header (SPDX pair + editor modelines, C++-style
# // comments) to a generated file, so generator output opens with the same
# banner as every hand-written source.
add_spdx() {
	local f="$1" tmp
	tmp="$(mktemp)"
	{
		printf '// %s\n// %s\n\n' "$SPDX_COPY" "$SPDX_LIC"
		printf '// vim: set ts=4 noet:\n'
		printf '// -*- indent-tabs-mode: t; tab-width: 4 -*-\n\n'
		cat "$f"
	} >"$tmp"
	mv "$tmp" "$f"
}

# Bring generator output onto the repository's whitespace convention
# (.editorconfig): indentation depth in tabs at width 4, no trailing
# whitespace. PeakRDL and generate_wb_pkg.py both emit four-space indentation,
# so without this the five generated files would be the only space-indented
# SystemVerilog in the tree. Purely mechanical and idempotent, so regeneration
# stays byte-identical.
canonicalize_ws() {
	local f="$1" tmp
	tmp="$(mktemp)"
	sed -e ':a' -e 's/^\(\t*\)    /\1\t/;ta' -e 's/[[:space:]]*$//' "$f" >"$tmp"
	mv "$tmp" "$f"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 2. PeakRDL-regblock: register block module + hwif package --------------
echo "[gen_rdl] peakrdl regblock -> rtl/pkg/"
# `python -m peakrdl`, not the console-script shim: the .exe shim exits 1
# once the venv's embedded interpreter path goes stale (observed 2026-07-24,
# same reason gen_rdl_profile.py launches it this way).
"$PY" -m peakrdl regblock "$RDL" -o "$TMP/regblock" --cpuif passthrough --type-style hier
for f in ct_cs_cpuif.sv ct_cs_cpuif_pkg.sv; do
	add_spdx "$TMP/regblock/$f"
	canonicalize_ws "$TMP/regblock/$f"
	cp "$TMP/regblock/$f" "rtl/pkg/$f"
done

# --- 3. generate_wb_pkg.py: wb constants pkg, type anchors, TB helper -------
echo "[gen_rdl] generate_wb_pkg.py -> rtl/pkg/ + tests/lib/"
mkdir -p "$TMP/wb"
"$PY" scripts/generate_wb_pkg.py "$RDL" "$TMP/wb" >/dev/null
add_spdx "$TMP/wb/ct_cs_cpuif_wb_pkg.sv"
canonicalize_ws "$TMP/wb/ct_cs_cpuif_wb_pkg.sv"
add_spdx "$TMP/wb/ct_cs_cpuif_types_pkg.sv"
canonicalize_ws "$TMP/wb/ct_cs_cpuif_types_pkg.sv"
add_spdx "$TMP/wb/ct_cs_cpuif_wb_helper.sv"
canonicalize_ws "$TMP/wb/ct_cs_cpuif_wb_helper.sv"
cp "$TMP/wb/ct_cs_cpuif_wb_pkg.sv"    rtl/pkg/
cp "$TMP/wb/ct_cs_cpuif_types_pkg.sv" rtl/pkg/
cp "$TMP/wb/ct_cs_cpuif_wb_helper.sv" tests/lib/

echo "[gen_rdl] done. Commit the RDL change and the regenerated SV together."
