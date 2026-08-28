#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Regenerate the unified KV260 example-SoC CTRL register block from
# examples/kv260/common/rdl/ct_kv260_ctrl.rdl (see README.md there).
#
# Companion to scripts/gen_rdl.sh (encoder CSR block) and
# scripts/gen_rdl_soc.sh (common/tgc5b CLINT+INTC block). Reuses the SAME pinned
# toolchain / virtualenv (rdl/requirements.txt) so output is reproducible.
#
# Outputs (SPDX header prepended to each):
#   examples/kv260/common/ct_kv260_ctrl_regs.sv       PeakRDL-regblock — register block
#   examples/kv260/common/ct_kv260_ctrl_regs_pkg.sv   PeakRDL-regblock — hwif struct package
#
# Never edit the generated files by hand — rerun this script (make rdl-kv260).
#
# Venv resolution note: this deliberately does NOT copy scripts/gen_rdl_soc.sh's
# `$VENV/bin/python`-only lookup — on a Windows checkout `python -m venv` lays
# down Scripts/python.exe, not bin/python, and that lookup silently falls
# through to "creating virtualenv" every run instead of reusing the pinned
# one (or fails outright if $PYTHON also resolves to the Store shim). The
# find_venv_python() below is scripts/gen_rdl.sh's already-fixed lookup
# (2026-08, P8 audit C-1: also handles a linked `git worktree`, whose venv
# belongs to the MAIN tree), copied rather than forked so this script and
# gen_rdl.sh do not drift on what "the pinned venv" means. gen_rdl_soc.sh
# still carries the old lookup; see README.md in this directory.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

RDL=examples/kv260/common/rdl/ct_kv260_ctrl.rdl
REQ=rdl/requirements.txt
PYTHON="${PYTHON:-python3}"
OUTDIR=examples/kv260/common

# --- 1. Reproducible toolchain in a local virtualenv (shared with gen_rdl.sh
#        and gen_rdl_soc.sh) --------------------------------------------------
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
	echo "[gen_rdl_kv260] creating virtualenv $MAIN_ROOT/.venv-rdl"
	"$PYTHON" -m venv "$MAIN_ROOT/.venv-rdl"
	PY="$(find_venv_python)" || { echo "[gen_rdl_kv260] FAIL: venv creation produced no interpreter"; exit 3; }
	"$PY" -m pip install --quiet --upgrade pip
	echo "[gen_rdl_kv260] installing pinned toolchain from $REQ"
	"$PY" -m pip install --quiet -r "$REQ"
elif [ -n "${GEN_RDL_FORCE_INSTALL:-}" ]; then
	echo "[gen_rdl_kv260] installing pinned toolchain from $REQ (forced)"
	"$PY" -m pip install --quiet -r "$REQ"
fi
echo "[gen_rdl_kv260] toolchain: $PY"

# Verify the pins instead of reinstalling on every run (gen_rdl.sh's
# reasoning applies verbatim: the point of the pin is the VERSION).
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
	print(f"[gen_rdl_kv260] pin {pkg}=={want}: {have}")
	if have != want:
		bad.append(f"{pkg}: want {want}, have {have}")
if bad:
	sys.exit("[gen_rdl_kv260] FAIL: pinned toolchain mismatch (" + "; ".join(bad)
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
# (.editorconfig): tabs at width 4, no trailing whitespace -- same as
# scripts/gen_rdl.sh's canonicalize_ws (PeakRDL emits four-space indentation).
canonicalize_ws() {
	local f="$1" tmp
	tmp="$(mktemp)"
	sed -e ':a' -e 's/^\(\t*\)    /\1\t/;ta' -e 's/[[:space:]]*$//' "$f" >"$tmp"
	mv "$tmp" "$f"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 2. PeakRDL-regblock: AXI4-Lite (flat) register block + hwif package -----
# Only the unified CTRL block (addrmap ct_kv260_ctrl_periph) becomes RTL; the
# documentation-only addrmap (ct_kv260_ctrl_window) in ct_kv260_ctrl.rdl is
# not. -I examples/kv260/common/rdl resolves the `include`-d component files
# under ct_kv260_ctrl/.
echo "[gen_rdl_kv260] peakrdl regblock -> $OUTDIR/"
"$PY" -m peakrdl regblock "$RDL" -o "$TMP" -I examples/kv260/common/rdl -t ct_kv260_ctrl_periph \
	--cpuif axi4-lite-flat --type-style hier \
	--module-name ct_kv260_ctrl_regs --package-name ct_kv260_ctrl_regs_pkg
mkdir -p "$OUTDIR"
for f in ct_kv260_ctrl_regs.sv ct_kv260_ctrl_regs_pkg.sv; do
	add_spdx "$TMP/$f"
	canonicalize_ws "$TMP/$f"
	cp "$TMP/$f" "$OUTDIR/$f"
done

echo "[gen_rdl_kv260] done. Commit examples/kv260/common/rdl/ct_kv260_ctrl.rdl and the regenerated SV together."
