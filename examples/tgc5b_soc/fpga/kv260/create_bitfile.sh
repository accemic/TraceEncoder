#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Build the TGC5B + CEDARtools.TraceEncoder KV260 app: run the pure-abc bitstream flow
# (ct_soc_kv260.abc — Zynq PS + AXI plumbing as standalone XCIs via
# gen_ip.tcl, no block design), convert the bitstream to the .bit.bin the
# Kria fpga-manager wants, compile the device-tree overlay, and assemble the
# loadable app dir:
#
#   <build>/app/ct_soc_kv260/
#     ct_soc_kv260.bit.bin   ct_soc_kv260.dtbo   shell.json
#
# Copy that directory to /lib/firmware/xilinx/ct_soc_kv260 on the board and load
# it with `sudo xmutil loadapp ct_soc_kv260` (see README).
#
# Requires Vivado 2022.1 (override VIVADO_SETTINGS) with bootgen on PATH, the
# abc build driver, and `dtc` for the overlay.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$here" rev-parse --show-toplevel)"
app=ct_soc_kv260
build_dir="${1:-$repo_root/bld/kv260}"

VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.1/settings64.sh}"
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"

echo "[bitfile] abc -bitgen: synth + impl + bitstream (fresh project)"
mkdir -p "$repo_root/bld"
(cd "$repo_root/bld" && abc -new -bitgen "$here/ct_soc_kv260.abc")

bit="$(find "$repo_root/bld/$app.abc.vivado" -name 'ct_soc_kv260_top.bit' | head -1)"
[ -n "$bit" ] || { echo "[bitfile] ERROR: no bitstream produced" >&2; exit 1; }
echo "[bitfile] bitstream: $bit"

mkdir -p "$build_dir"

echo "[bitfile] bootgen -> $app.bit.bin"
cat > "$build_dir/$app.bif" <<EOF
all:
{
	$bit
}
EOF
bootgen -arch zynqmp -image "$build_dir/$app.bif" -o "$build_dir/$app.bit.bin" -w

echo "[bitfile] dtc -> $app.dtbo"
dtc -@ -I dts -O dtb -o "$build_dir/$app.dtbo" "$here/dt/$app.dtso"

appdir="$build_dir/app/$app"
mkdir -p "$appdir"
cp "$build_dir/$app.bit.bin" "$appdir/"
cp "$build_dir/$app.dtbo"    "$appdir/"
cp "$here/shell.json"        "$appdir/"

echo "[bitfile] app ready: $appdir"
ls -l "$appdir"
