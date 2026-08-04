#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Rebuild the committed hello_trace program artifacts for the TGC5B example SoC.
#
# Outputs (written to ../). hello_trace.{dis,hex,pcinfo} are committed so the
# simulation needs no RISC-V toolchain at run time; the ELF and the raw objdump
# are regeneratable by-products and stay untracked (see ../.gitignore):
#   hello_trace.elf          linked ELF (provenance)
#   hello_trace.dis          disassembly (human reference)
#   hello_trace.hex          $readmemh image (one 32-bit word per line)
#   hello_trace.pcinfo       NexRv PCInfo (reference-decoder instruction map)
#
# Requires a bare-metal RV32I toolchain (riscv32-unknown-elf-*) and the NexRv
# reference decoder (repo bin/NexRv). Override the tools via CROSS / NEXRV.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$(cd "$here/.." && pwd)"
repo_root="$(git -C "$here" rev-parse --show-toplevel)"

CROSS="${CROSS:-riscv32-unknown-elf-}"
GCC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"
OBJDUMP="${CROSS}objdump"
NEXRV="${NEXRV:-$repo_root/bin/NexRv}"

elf="$out/hello_trace.elf"
dis="$out/hello_trace.dis"
hex="$out/hello_trace.hex"
objd="$out/hello_trace.objdump.txt"
pcinfo="$out/hello_trace.pcinfo"

echo "[build] compiling + linking (rv32i_zicsr / ilp32)"
"$GCC" -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
	-O1 -Wl,--no-warn-rwx-segments -T "$here/prog.ld" -o "$elf" \
	"$here/crt0.S" "$here/main.c"

echo "[build] disassembly -> $dis"
# objdump echoes back the path it was handed, so disassemble through the bare
# file name: the committed .dis must not embed a local working-copy path.
( cd "$out" && "$OBJDUMP" -d "$(basename "$elf")" ) > "$dis"
cp "$dis" "$objd"

echo "[build] flat binary -> word-per-line hex -> $hex"
bin="$(mktemp)"; trap 'rm -f "$bin"' EXIT
"$OBJCOPY" -O binary "$elf" "$bin"
python3 - "$bin" "$hex" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
data += b"\x00" * ((-len(data)) % 4)               # pad to a whole word
with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 4):
        f.write("%08x\n" % int.from_bytes(data[i:i+4], "little"))
PY

echo "[build] NexRv pcinfo -> $pcinfo"
"$NEXRV" -conv -objd "$objd" -pcinfo "$pcinfo"

echo "[build] done:"
ls -l "$elf" "$dis" "$hex" "$pcinfo"
