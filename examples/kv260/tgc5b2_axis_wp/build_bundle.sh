#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# build_bundle.sh -- build of the tgc5b2_axis_wp KV260 app
# (2x MINRES TGC5B + 2x CEDARtools.TraceEncoder with the ACT-CAP/ACT-ST AXIS
# export path), packaged as a SHIPPABLE bundle: everything a customer needs to
# load the design onto a KV260 and trace THEIR OWN program on it.
#
#   bash examples/kv260/tgc5b2_axis_wp/build_bundle.sh [build-dir]
#
# Replaces the older ct_soc_kv260 (single-TGC5B) CI recipe. The differences
# are not cosmetic -- see "WHAT CHANGED vs. THE ct_soc_kv260 RECIPE" below.
#
# Outputs, all under <build-dir> (default bld/kv260-tgc5b2):
#   ct-tgc5b2-axis-wp-kv260.zip   the customer bundle (see layout below)
#   bundle/                        the same, unzipped
#   ct_cs_cpuif.rdl                flat (preprocessed) encoder CSR RDL
#   ct_cs_cpuif.rdl.html/          browsable encoder CSR reference
#
# Environment:
#   VIVADO_SETTINGS  settings64.sh to source   (default: Vivado 2022.1)
#   NC_PASS          Nextcloud password        (REQUIRED for --upload; never
#                                               hardcode it -- see note below)
#   SKIP_UPLOAD=1    build + package only, no accput / no Nextcloud
#   SKIP_BUILD=1     reuse the bitstream already in $EX/fpga/proj instead of
#                    re-synthesizing (for iterating on packaging/upload; never
#                    in a real CI run -- it ships whatever happens to be there)
#
# CREDENTIALS: this script takes NC_PASS from the environment and never
# echoes it. Do not put the password in the script or in a CI step's inline
# shell -- CI captures stdout, and a committed script leaks it permanently.
# Use the CI system's secret store and inject it as an env var.
set -euo pipefail

# Repo root, resolved for BOTH invocation styles:
#   a) `bash examples/kv260/tgc5b2_axis_wp/build_bundle.sh` -- the script sits
#      in the repo, so derive from its own location and it works from any cwd;
#   b) pasted into a Jenkins "Execute shell" step -- Jenkins copies the body to
#      /tmp/jenkins*.sh and runs it there, so $0 is NOT in the repo. The
#      workspace is the cwd, so derive from cwd instead.
# Deriving from $0 alone is what failed in job ct_soc_kv260:
#   fatal: not a git repository (or any of the parent directories): .git
if REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)"; then
    :
elif REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    :
elif [ -n "${WORKSPACE:-}" ] && [ -d "$WORKSPACE/.git" ]; then
    REPO_ROOT="$WORKSPACE"
else
    echo "ERROR: cannot locate the repository root." >&2
    echo "  \$0=$0  cwd=$PWD  WORKSPACE=${WORKSPACE:-<unset>}" >&2
    echo "  Run this from inside a checkout, or set WORKSPACE to one." >&2
    exit 1
fi
cd "$REPO_ROOT"

BUILD_DIR="${1:-$REPO_ROOT/bld/kv260-tgc5b2}"
EX=examples/kv260/tgc5b2_axis_wp
APP=tgc5b2_axis_wp_c0b
BUNDLE_NAME=ct-tgc5b2-axis-wp-kv260
ACCPUT_TAG=tgc5b2-axis-wp-kv260-zip

# Vivado 2022.1 is what .abc.config pins and what this design's bitstream is
# verified against (WNS +1.991 ns, board-run 851/851 records per core,
# 2026-08-21). 2024.1 is NOT verified for this flow -- override deliberately,
# and re-check the WNS gate in run_bitstream.tcl if you do.
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.1/settings64.sh}"

BUNDLE="$BUILD_DIR/bundle/$BUNDLE_NAME"
say() { echo; echo "=== $* ==="; }

# =============================================================================
say "0/6  Environment"
# -----------------------------------------------------------------------------
# The `py` shim. $EX/fpga/create_project.tcl calls `exec py <script>` -- the
# Windows Python launcher, which does not exist on a Linux CI node.
#
# It must resolve to the SYSTEM interpreter, not to whatever `python3` means
# after sourcing settings64.sh: Vivado prepends its own bundled Python and
# exports PYTHONHOME/PYTHONPATH pointing into its tps/ tree, so a bare
# `python3` there runs Vivado's interpreter against Vivado's stdlib. Hence:
# capture python3 BEFORE sourcing, scrub the Python env vars, and put the shim
# ahead of Vivado's bin on PATH.
#
# Python floor: 3.8, the system python3 on Ubuntu 20.04 CI nodes. Verified
# 2026-08-21 against a real 3.8.20 -- abc_filelist.py, wp_gen.py and
# package_kv260_app.py all run there and produce byte-identical output to
# 3.12. (abc_filelist.py needed `from __future__ import annotations` to get
# there; it annotated with PEP 585 generics that Python 3.8 evaluates at
# runtime, which is what failed job ct_soc_kv260 with
# "TypeError: 'type' object is not subscriptable".)
#
# The clean fix is a py/python3 fallback inside create_project.tcl; until that
# lands this shim keeps the CI node self-sufficient.
# -----------------------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/shim" "$BUNDLE"
SYS_PY="$(command -v python3)"
cat > "$BUILD_DIR/shim/py" <<EOF
#!/bin/sh
unset PYTHONHOME PYTHONPATH PYTHONSTARTUP
exec $SYS_PY "\$@"
EOF
chmod +x "$BUILD_DIR/shim/py"

# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"
export PATH="$BUILD_DIR/shim:$PATH"

# Does this checkout actually CONTAIN the example? A CI job pointed at a ref
# that predates the kv260 examples otherwise dies later with a bare
# "No such file or directory" from Vivado, which reads like a tool problem
# rather than a wrong-branch problem. Measured: stage/main @ 8fe6c5c carries
# only examples/kv260/common/tgc5b -- no examples/kv260/, no tools/, no ci/.
missing=""
for p in "$EX/fpga/create_project.tcl" "$EX/fpga/run_bitstream.tcl" \
         "$EX/board/wp_board_gate.sh" "$EX/sw/axis_wp_demo.hex" \
         tools/axis_wp_host/read_wp_stream.py rdl/ct_cs_cpuif.rdl; do
    [ -e "$p" ] || missing="$missing\n    $p"
done
if [ -n "$missing" ]; then
    echo "ERROR: this checkout does not contain the tgc5b2_axis_wp example." >&2
    echo "  ref     : $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)" >&2
    echo "  missing :$(printf "$missing")" >&2
    echo "  The example lives on the branch that introduced it; point the CI job" >&2
    echo "  at that ref, or merge it to the branch this job builds." >&2
    exit 1
fi

command -v vivado  >/dev/null || { echo "ERROR: vivado not on PATH after sourcing $VIVADO_SETTINGS" >&2; exit 1; }
command -v bootgen >/dev/null || { echo "ERROR: bootgen not on PATH" >&2; exit 1; }

# Everything the PUBLISH step needs is checked HERE, before an hour of
# synthesis and before anything is published. Measured in job ct_soc_kv260:
# with the credential missing, accput published the zip and the run then died
# on NC_PASS -- artifact half-published, build red. A publish precondition
# belongs in the preflight, not between two publish actions.
#
# NC_PASS must be BOUND into the environment, not merely stored: in Jenkins,
# add "Use secret text(s) or file(s)" (Credentials Binding plugin) with
# Variable = NC_PASS. A credential sitting in the store is not exported.
if [ "${SKIP_UPLOAD:-0}" != "1" ]; then
    command -v accput           >/dev/null || { echo "ERROR: accput not on PATH" >&2; exit 1; }
    command -v upload-nextcloud >/dev/null || { echo "ERROR: upload-nextcloud not on PATH" >&2; exit 1; }
    : "${NC_PASS:?not set -- bind the CI secret to the variable NC_PASS (Jenkins: Build Environment -> Use secret text(s) or file(s)); never hardcode it. SKIP_UPLOAD=1 builds without publishing}"
    echo "publish: accput + nextcloud, NC_PASS bound (${#NC_PASS} chars)"
fi
VIVADO_BIN="$(dirname "$(command -v vivado)")"
GIT_SHA="$(git rev-parse --short HEAD)"
GIT_DIRTY="$(git diff --quiet && git diff --cached --quiet && echo clean || echo DIRTY)"
echo "vivado : $(vivado -version 2>/dev/null | head -1)"
echo "commit : $GIT_SHA ($GIT_DIRTY)"

# =============================================================================
say "1/6  Register reference (SystemRDL -> flat RDL + browsable HTML)"
# -----------------------------------------------------------------------------
# TWO register references are produced, and the difference matters:
#
#   tgc5b2_kv260.rdl   THE WHOLE DEVICE at the absolute addresses devmem takes
#                      on the board -- both cores' encoder CSRs (ENC0 at
#                      0xA001_0000, ENC1 at 0xA002_0000), the CTRL block that
#                      starts/stops the cores and arms the sinks, the funnel's
#                      trace-ring window, WPCTRL, both RX FIFOs, and the two
#                      core RAMs. This is what a user of the app needs, and it
#                      is the one to open first.
#                      Source: examples/kv260/tgc5b2_axis_wp/rdl/
#
#   ct_cs_cpuif.rdl    the bare CTTE encoder CSR map, aperture-relative. Useful
#                      when integrating the encoder somewhere else, where this
#                      design's base addresses do not apply.
#
# NOTE vs. the old recipe: examples/kv260/common/tgc5b/rdl/ct_soc.rdl describes
# the ct_soc_kv260 app's map (ONE core, different bases). It does NOT describe
# this design and is deliberately not shipped -- shipping it would hand the
# customer addresses that are wrong for the app in the same zip.
#
# Toolchain pinned in rdl/requirements.txt, in a venv this script owns. The
# repo's .venv-rdl is NOT reused: it stores an absolute interpreter path in
# every console-script shebang, so a checkout at a different path (a CI
# workspace, a renamed clone) inherits a venv that silently cannot execute.
# -----------------------------------------------------------------------------
VENV="$BUILD_DIR/venv-rdl"
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r rdl/requirements.txt

# -t: the merged file declares three addrmaps; the device view is the top one.
"$VENV/bin/peakrdl" preprocess "$EX/rdl/ct_tgc5b2_kv260.rdl" -I rdl -I "$EX/rdl" \
    -o "$BUILD_DIR/tgc5b2_kv260.rdl"
"$VENV/bin/peakrdl" html "$BUILD_DIR/tgc5b2_kv260.rdl" -t tgc5b2_kv260_top \
    -o "$BUILD_DIR/tgc5b2_kv260.rdl.html"

"$VENV/bin/peakrdl" preprocess rdl/ct_cs_cpuif.rdl -I rdl \
    -o "$BUILD_DIR/ct_cs_cpuif.rdl"
"$VENV/bin/peakrdl" html "$BUILD_DIR/ct_cs_cpuif.rdl" \
    -o "$BUILD_DIR/ct_cs_cpuif.rdl.html"

# The addresses in the merged RDL are the ones the board tooling pokes. If the
# two ever disagree, the map is a lie -- so check it here rather than shipping
# it and finding out on a board.
"$VENV/bin/python" "$EX/rdl/check_addr_map.py" || {
    echo "ERROR: the merged RDL disagrees with the board tooling" >&2; exit 1; }

echo "device RDL : $(wc -l < "$BUILD_DIR/tgc5b2_kv260.rdl") lines -> tgc5b2_kv260.rdl.html/index.html"
echo "encoder RDL: $(wc -l < "$BUILD_DIR/ct_cs_cpuif.rdl") lines -> ct_cs_cpuif.rdl.html/index.html"

# =============================================================================
say "2/6  Bitstream (Vivado project -> synth -> impl -> write_bitstream)"
# -----------------------------------------------------------------------------
# Two steps, not one: create_project.tcl builds the project and ends on an RTL
# elaboration gate; run_bitstream.tcl does synth/impl/bitstream and FAILS on
# WNS < 0. Both must run from a scratch dir -- they drop vivado.log/.jou where
# they are started.
#
# Neither script exits non-zero on a Vivado crash (Vivado itself exits 0), so
# they check the run's PROGRESS property instead and print the markers below;
# this script gates on those markers, not on $?.
# -----------------------------------------------------------------------------
BIT="$REPO_ROOT/$EX/fpga/proj/tgc5b2_axis_wp.runs/impl_1/tgc5b2_kv260_top.bit"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
    echo "SKIP_BUILD=1 -- reusing the existing bitstream, NOT re-synthesizing"
    # header line, dashes line, values line -> -A2 + tail -1 is the values row
    WNS="$(grep -m1 -A2 'WNS(ns)' "$EX/fpga/reports/tgc5b2_axis_wp_timing_summary.rpt" \
           | tail -1 | awk '{print $1}') ns (from the existing report)"
else
    mkdir -p "$BUILD_DIR/vivado"
    (
      cd "$BUILD_DIR/vivado"
      vivado -mode batch -notrace -source "$REPO_ROOT/$EX/fpga/create_project.tcl"
    ) 2>&1 | tee "$BUILD_DIR/create_project.log"
    grep -q '### ELAB_OK' "$BUILD_DIR/create_project.log" \
        || { echo "ERROR: RTL elaboration gate failed" >&2; exit 1; }

    (
      cd "$BUILD_DIR/vivado"
      vivado -mode batch -notrace -source "$REPO_ROOT/$EX/fpga/run_bitstream.tcl"
    ) 2>&1 | tee "$BUILD_DIR/run_bitstream.log"
    grep -q '### BITSTREAM_DONE' "$BUILD_DIR/run_bitstream.log" \
        || { echo "ERROR: bitstream build did not complete (SYNTH_FAIL/IMPL_FAIL/TIMING_FAIL)" >&2; exit 1; }
    WNS="$(grep -m1 '### TIMING WNS:' "$BUILD_DIR/run_bitstream.log" | sed 's/.*WNS: //')"
fi

[ -f "$BIT" ] || { echo "ERROR: no bitstream at $BIT" >&2; exit 1; }
echo "bitstream: $BIT"
echo "WNS      : $WNS"

# =============================================================================
say "3/6  Package the loadable Kria app + the reference demo data"
# -----------------------------------------------------------------------------
# `--phase gen` does both halves of what the customer needs:
#   - package_kv260_app.py: .bit -> bootgen .bit.bin + .dtso + shell.json +
#     MANIFEST.sha256, the directory xmutil loadapp wants;
#   - wp_gen.py: the reference watchpoint set and its expected-hit oracle
#     (1023 slots = 364 real + 659 filler, 851 expected hits per core) plus
#     prog.hex -- the worked example the customer runs FIRST to prove the
#     chain before substituting their own program.
# --vivado-bin is required on Linux: the packager's default is a Windows path.
# -----------------------------------------------------------------------------
PY=python3 bash "$EX/board/wp_board_gate.sh" --phase gen \
    --bit "$BIT" --vivado-bin "$VIVADO_BIN" 2>&1 | tee "$BUILD_DIR/gen.log"
grep -q '### GEN_OK' "$BUILD_DIR/gen.log" \
    || { echo "ERROR: packaging failed" >&2; exit 1; }
BITBIN_MD5="$(grep -o 'bit.bin md5=[0-9a-f]*' "$BUILD_DIR/gen.log" | cut -d= -f2)"

# =============================================================================
say "4/6  Assemble the customer bundle"
# -----------------------------------------------------------------------------
# Layout (what each part is FOR):
#   app/     the loadable design                     -> /lib/firmware/xilinx/
#   doc/     register reference + address maps + the encoder feature docs
#   host/    the AXIS reader and the watchpoint-table loader (run on the board
#            or on any host with /dev/mem access to the FIFO windows)
#   board/   deploy + run scripts, incl. the step-by-step demo driver
#   demo/    the reference program, its watchpoint set and its oracle, plus
#            the sources and generators so the customer can build their OWN
#            program against the same memory layout
#   reports/ timing + utilization evidence for the shipped bitstream
# -----------------------------------------------------------------------------
mkdir -p "$BUNDLE"/{app,doc,host,board,demo,reports}

# --- app ---------------------------------------------------------------------
cp -r "$EX/board/run/app_pkg/$APP" "$BUNDLE/app/"

# --- doc ---------------------------------------------------------------------
# The device map first -- it is the one a user of the app opens. The bare
# encoder map ships beside it for integrating the encoder elsewhere.
cp -r "$BUILD_DIR/tgc5b2_kv260.rdl.html" "$BUNDLE/doc/"
cp    "$BUILD_DIR/tgc5b2_kv260.rdl"      "$BUNDLE/doc/"
cp -r "$BUILD_DIR/ct_cs_cpuif.rdl.html"  "$BUNDLE/doc/"
cp    "$BUILD_DIR/ct_cs_cpuif.rdl"       "$BUNDLE/doc/"

# The plain-language entry point, at the ROOT of the bundle so it is the first
# thing seen after unzipping. Everything else under doc/ is reference material.
cp    "$EX/DEMO_README.md"               "$BUNDLE/README.md"
cp    "$EX/README.md"                   "$BUNDLE/doc/EXAMPLE_README.md"
cp    "$EX/board/README.md"             "$BUNDLE/doc/BOARD_README.md"
cp    "$EX/sw/README.md"                "$BUNDLE/doc/DEMO_PROGRAM_README.md"
cp    tools/axis_wp_host/README.md      "$BUNDLE/doc/HOST_TOOLS_README.md"
cp    doc/integration.adoc doc/enhanced-features.adoc doc/trace-format.adoc \
      doc/architecture.adoc doc/release-notes.adoc "$BUNDLE/doc/"
cp    examples/kv260/SPEC_board_memory_map.md "$BUNDLE/doc/"
cp    LICENSE.md TRADEMARKS.md "$BUNDLE/"
cp -r LICENSES "$BUNDLE/"

# The address map of THIS design has no RDL -- it lives in the @details header
# of the two RTL tops. Extract it verbatim rather than paraphrasing it, so the
# bundle cannot drift from the RTL it ships.
{
    echo "# tgc5b2_axis_wp -- KV260 address map"
    echo
    echo "Extracted verbatim from the RTL headers of the shipped design"
    echo "(commit $GIT_SHA)."
    echo
    echo "For the SAME map as a browsable register reference -- every register"
    echo "at its absolute address, both encoders included -- open"
    echo "\`tgc5b2_kv260.rdl.html/index.html\`. This file is the RTL-header"
    echo "form, kept because it carries the prose the RDL descriptions condense."
    echo
    echo '## Top level (AXI4-Lite router, tgc5b2_kv260_top)'
    echo
    echo '```'
    # The PS chain + router block: from the M_AXI line to the FIFO1 window.
    # awk, not `sed -n '/a/,/b/p'` -- a sed range RESTARTS on every later match
    # of the start pattern, and both anchors occur again further down the file,
    # which drags port declarations into the doc. This stops at the first block.
    awk '/PS M_AXI_HPM0_FPD/{f=1} f{print} f&&/FIFO1   axi_fifo_mm_s/{exit}' \
        "$EX/fpga/tgc5b2_kv260_top.sv" | sed 's|^ \* \?||'
    echo '```'
    echo
    echo '## SoC region (tgc5b2_axis_soc_top, decodes the low 22 bits)'
    echo
    echo '```'
    # exit BEFORE the closing `*/` so it does not land in the doc as a stray "/"
    awk '/Address map \(22-bit aperture/{f=1} f&&/^ \*\//{exit} f{print}' \
        "$EX/rtl/tgc5b2_axis_soc_top.sv" | sed 's|^ \* \?||'
    echo '```'
} > "$BUNDLE/doc/MEMORY_MAP.md"

# --- host tooling ------------------------------------------------------------
cp tools/axis_wp_host/*.py "$BUNDLE/host/"
rm -rf "$BUNDLE/host/__pycache__"

# --- board tooling -----------------------------------------------------------
cp "$EX/board/wp_board.py" "$EX/board/prep_load.sh" "$EX/board/prep_verify.sh" \
   "$EX/board/run_a.sh" "$EX/board/run_b.sh" "$EX/board/restore.sh" \
   "$EX/board/wp_check.py" "$EX/board/wp_gen.py" "$BUNDLE/board/"
cp examples/kv260/common/board/kv260_plclk.sh \
   examples/kv260/common/board/deploy_kv260_app.sh \
   examples/kv260/common/board/package_kv260_app.py \
   examples/kv260/common/board/mem_load.py "$BUNDLE/board/"
# `|| true`: under `set -e` a false `[ ] && cp` as the last command of the list
# aborts the whole script -- the copy is optional, its absence is not an error.
[ -f "$EX/board/wp_demo_run.sh" ] && cp "$EX/board/wp_demo_run.sh" "$BUNDLE/board/" || true
chmod +x "$BUNDLE"/board/*.sh

# --- demo: the worked reference + the sources to build one's own -------------
cp "$EX/board/run/wp_table.txt" "$EX/board/run/wp_real.txt" \
   "$EX/board/run/expected_full.txt" "$EX/board/run/prog.hex" "$BUNDLE/demo/"
cp "$EX/sw/axis_wp_demo.hex" "$EX/sw/axis_wp_demo.dis" "$EX/sw/wp_set.txt" \
   "$EX/sw/expected_hits.txt" "$EX/sw/build.sh" "$EX/sw/gen_program.py" \
   "$EX/sw/gen_wp_set.py" "$EX/sw/check_consistency.py" "$BUNDLE/demo/"
cp -r "$EX/sw/src" "$BUNDLE/demo/src"

# --- reports -----------------------------------------------------------------
cp "$EX/fpga/reports/"*.rpt "$BUNDLE/reports/" 2>/dev/null || true

# --- provenance --------------------------------------------------------------
cat > "$BUNDLE/BUILD_INFO.txt" <<EOF
CEDARtools.TraceEncoder -- tgc5b2_axis_wp KV260 app
====================================================
app name        : $APP
source commit   : $GIT_SHA ($GIT_DIRTY)
built           : $(date -u +"%Y-%m-%dT%H:%M:%SZ") UTC
vivado          : $(vivado -version 2>/dev/null | head -1)
target part     : xck26-sfvc784-2LV-c (KV260 / Kria K26 SOM)
WNS             : $WNS
bit.bin md5     : $BITBIN_MD5

Design: two independent MINRES TGC5B RV32 cores, each with its own
CEDARtools.TraceEncoder instance. Each encoder's ACT-CAP/ACT-ST AXIS
instrumentation stream is packed into 32-bit records by ct_axis_wp_shim and
buffered in an axi_fifo_mm_s a Linux host drains over /dev/mem. Both encoders'
N-Trace ATB output is merged by ct_L1_funnel into a URAM ring + DDR4 sink + PIB.

REQUIRED BOARD SETTING: pl_clk0 must be driven to 75 MHz before use. The Kria
boot firmware provides 100 MHz; board/kv260_plclk.sh sets it, and it may only
be changed while the PL is unloaded. See doc/BOARD_README.md.

Start here: doc/EXAMPLE_README.md, then board/wp_demo_run.sh for a worked run.
EOF

( cd "$BUNDLE" && find . -type f -exec sha256sum {} + | sort -k2 > MANIFEST.sha256 )

# =============================================================================
say "5/6  Zip"
( cd "$BUILD_DIR/bundle" && zip -qr "$BUILD_DIR/$BUNDLE_NAME.zip" "$BUNDLE_NAME" )
ZIP="$BUILD_DIR/$BUNDLE_NAME.zip"
NFILES="$(find "$BUNDLE" -type f | wc -l)"   # not `unzip -l`: unzip is not on every CI node
echo "bundle: $ZIP ($(du -h "$ZIP" | cut -f1), $NFILES files)"

# =============================================================================
say "6/6  Publish"
if [ "${SKIP_UPLOAD:-0}" = "1" ]; then
    echo "SKIP_UPLOAD=1 -- not published"
    exit 0
fi

# NC_PASS and both publish tools were verified in the preflight, so this
# section cannot fail half-way through for a missing credential.
accput -t "$ACCPUT_TAG" "$ZIP"

# The device map goes up first -- it is the one someone asks for by name.
# Both .rdl files are the flat (preprocessed) form, so they open standalone.
NC_PASS="$NC_PASS" upload-nextcloud \
    "$ZIP" \
    "$BUILD_DIR/tgc5b2_kv260.rdl" \
    "$BUILD_DIR/tgc5b2_kv260.rdl.html/index.html" \
    "$BUILD_DIR/ct_cs_cpuif.rdl" \
    "$BUILD_DIR/ct_cs_cpuif.rdl.html/index.html"

echo
echo "### CI_OK  $BUNDLE_NAME  commit $GIT_SHA  WNS $WNS  md5 $BITBIN_MD5"
