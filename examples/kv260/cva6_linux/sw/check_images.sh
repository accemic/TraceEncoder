#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Gate check of the Linux artifacts for the CVA6.
#
# The core cv32a6_ima_sv32_fpga has NO C extension. What matters is not
# what the kernel configuration says, but what lands in the BINARY IMAGE --
# hence this script checks the artifact, not the configuration.
#
# Beware of the PE/COFF header: with the EFI stub, the image starts with a
# data block that every disassembler reads as (compressed) instructions --
# 4 false positives in the 2026-07-26 image. The boundary therefore comes
# from the symbol table, not from an address assumption.
#
#   ./check_images.sh [<buildroot-dir>]
set -u
BR="${1:-$HOME/cva6_linux/buildroot}"
BIN="$BR/output/host/bin"
OD="$BIN/riscv32-buildroot-linux-gnu-objdump"
NM="$BIN/riscv32-buildroot-linux-gnu-nm"
VMLINUX="$(ls -d "$BR"/output/build/linux-*/vmlinux 2>/dev/null | head -1)"
rc=0

[ -x "$OD" ]      || { echo "MISSING: $OD"; exit 2; }
[ -n "$VMLINUX" ] || { echo "MISSING: vmlinux"; exit 2; }

echo "== Artifacts =="
ls -la "$BR"/output/images/Image "$BR"/output/images/fw_jump.bin \
       "$BR"/output/images/rootfs.cpio 2>/dev/null

echo
echo "== Compressed instructions in the kernel CODE =="
hdr_end=$("$NM" -n "$VMLINUX" 2>/dev/null \
          | awk '$3=="efi_header_end" || $3=="_start_kernel" {print $1; exit}')
if [ -z "$hdr_end" ]; then
    hdr_end=0
    echo "(no PE/COFF header -- the EFI stub is off)"
else
    echo "(header boundary from the symbol table: 0x$hdr_end)"
fi
# -M no-aliases is MANDATORY (audit finding C-L1-4, 2026-08-08): binutils
# 2.43.1 prints compressed instructions by default WITHOUT the "c."
# prefix (aa01 -> "j" instead of "c.j"). The counter below matches /^c\./
# and was therefore COMPLETELY blind -- cross-checked against an object
# freshly compiled with -march=rv32imac: 0 hits without the flag, 14 with
# the flag. The gate could not turn its own defect class red.
"$OD" -d -M no-aliases "$VMLINUX" 2>/dev/null > /tmp/vmlinux.dis || { echo "objdump failed"; exit 2; }
n=$(awk -v lim="$hdr_end" '
      $3 ~ /^c\./ {
        addr = $1; sub(/:$/, "", addr);
        if (strtonum("0x" addr) >= strtonum("0x" lim)) c++
      } END { print c+0 }' /tmp/vmlinux.dis)
echo "found: $n"
if [ "$n" -gt 0 ]; then
    echo "ERROR: the core cannot execute compressed instructions!"
    awk -v lim="$hdr_end" '
      $3 ~ /^c\./ { addr = $1; sub(/:$/, "", addr);
        if (strtonum("0x" addr) >= strtonum("0x" lim)) print }' /tmp/vmlinux.dis | head -5
    rc=1
fi

echo
echo "== Toolchain ISA (must be rv32ima without c/f/d) =="
"$BIN"/riscv32-buildroot-linux-gnu-gcc -Q --help=target 2>/dev/null \
    | grep -E "^[[:space:]]+-march=|^[[:space:]]+-mabi=" | head -2
if ! "$BIN"/riscv32-buildroot-linux-gnu-gcc -Q --help=target 2>/dev/null \
     | grep -qE "^[[:space:]]+-march=[[:space:]]+rv32ima"; then
    echo "ERROR: toolchain is not rv32ima"
    rc=1
fi

echo
if [ $rc -eq 0 ]; then echo "IMAGES OK (no compressed instructions in code, ISA matches)"
else                   echo "IMAGES FAIL"; fi
exit $rc
